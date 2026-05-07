#if os(macOS)
import AppKit
#endif
import AuthenticationServices
import CryptoKit
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import os

private let oauthLogger = HexLog.action

struct GoogleTokens: Codable, Sendable {
  let accessToken: String
  let refreshToken: String
  let expiresAt: Date
}

@DependencyClient
struct GoogleOAuthClient {
  var authorize: @Sendable (_ scopes: [String]) async throws -> GoogleTokens
  var refreshIfNeeded: @Sendable () async throws -> String
  var isAuthorized: @Sendable () async -> Bool = { false }
  var disconnect: @Sendable () async -> Void
  /// Fetches the user's primary email via the userinfo endpoint and caches
  /// it in UserDefaults under `googleAccountEmailDefaultsKey`. Returns `nil`
  /// on failure (network, scope missing, etc.) so the UI can fall back to a
  /// generic "Connected" label.
  var fetchUserEmail: @Sendable () async -> String? = { nil }
}

extension GoogleOAuthClient: DependencyKey {
  // Replace with your Google Cloud Console OAuth credential of type **iOS**
  // (NOT "Desktop app"). Google enforces server-side that only iOS-type
  // clients may use custom URI scheme redirects — Desktop clients are
  // restricted to loopback (http://127.0.0.1) since 2022. iOS clients have
  // no client_secret; PKCE replaces it.
  //
  // The credential's bundle ID can be either Quill bundle ID
  // (com.joevasquez.Quill or com.joevasquez.Quill.iOS); Google uses that
  // field for App Store verification, not runtime OAuth checks, so a single
  // credential serves both targets.
  static let clientId = "897102622833-ugs83fdspt94d9g373nh1v19gm4elive.apps.googleusercontent.com"

  /// Reverse-DNS of the client ID — Google's mandated redirect-URI scheme
  /// for iOS-type clients. Derived to avoid drift if the client ID isx
  /// rotated.
  static var reversedClientId: String {
    let suffix = ".apps.googleusercontent.com"
    let prefix = clientId.hasSuffix(suffix) ? String(clientId.dropLast(suffix.count)) : clientId
    return "com.googleusercontent.apps.\(prefix)"
  }

  /// Full redirect URI sent in the authorization request. Path doesn't
  /// matter to Google — only the scheme is enforced — but we use a stable
  /// path to make logs/network traces self-documenting.
  static var redirectURI: String { "\(reversedClientId):/oauth2redirect" }

  /// Scopes requested for every Google sign-in. `userinfo.email` lets us
  /// display "Connected as <address>" in Settings; the others power Gmail
  /// drafts and Calendar event creation in Action mode. `datastore` enables
  /// Firestore cloud sync when the user opts in.
  static let defaultScopes: [String] = [
    "https://www.googleapis.com/auth/gmail.compose",
    "https://www.googleapis.com/auth/calendar.events",
    "https://www.googleapis.com/auth/userinfo.email",
    CloudSyncConstants.firestoreScope,
    CloudSyncConstants.photoStorageScope,
  ]

  /// UserDefaults key for the cached account email — shared across Settings
  /// section views and onboarding so they stay in sync without polling.
  static let googleAccountEmailDefaultsKey = "quill.googleAccountEmail"

  private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
  private static let userInfoEndpoint = URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!

  static var liveValue: Self {
    .init(
      authorize: { scopes in
        @Dependency(\.keychain) var keychain

        // PKCE: hash a random verifier into a challenge, send the challenge
        // with the auth request, prove possession of the verifier on the
        // token exchange. Replaces the client_secret that Desktop OAuth
        // clients used to embed.
        let codeVerifier = generateCodeVerifier()
        let codeChallenge = codeChallenge(for: codeVerifier)

        let scopeString = scopes.joined(separator: " ")
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
          URLQueryItem(name: "client_id", value: clientId),
          URLQueryItem(name: "redirect_uri", value: redirectURI),
          URLQueryItem(name: "response_type", value: "code"),
          URLQueryItem(name: "scope", value: scopeString),
          URLQueryItem(name: "code_challenge", value: codeChallenge),
          URLQueryItem(name: "code_challenge_method", value: "S256"),
          URLQueryItem(name: "access_type", value: "offline"),
          URLQueryItem(name: "prompt", value: "consent"),
        ]

        guard let authURL = components.url else {
          throw GoogleOAuthError.invalidURL
        }

        oauthLogger.info("Starting Google OAuth via ASWebAuthenticationSession")

        // Hops to the main actor; runs the system Safari sheet in-process,
        // captures the redirect callback without going through any
        // app-level URL routing.
        let code = try await runWebAuth(authURL: authURL, callbackScheme: reversedClientId)

        let tokens = try await exchangeCode(code, codeVerifier: codeVerifier)

        try? await keychain.save(KeychainKey.googleAccessToken, tokens.accessToken)
        try? await keychain.save(KeychainKey.googleRefreshToken, tokens.refreshToken)
        let expiryString = ISO8601DateFormatter().string(from: tokens.expiresAt)
        try? await keychain.save(KeychainKey.googleTokenExpiry, expiryString)

        oauthLogger.info("Google OAuth tokens stored in Keychain")
        return tokens
      },
      refreshIfNeeded: {
        @Dependency(\.keychain) var keychain

        guard let accessToken = await keychain.read(KeychainKey.googleAccessToken),
              let refreshToken = await keychain.read(KeychainKey.googleRefreshToken),
              let expiryString = await keychain.read(KeychainKey.googleTokenExpiry),
              let expiresAt = ISO8601DateFormatter().date(from: expiryString)
        else {
          throw GoogleOAuthError.notAuthorized
        }

        if expiresAt.timeIntervalSinceNow > 300 {
          return accessToken
        }

        oauthLogger.info("Google access token expired or expiring soon; refreshing")

        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        // No client_secret for iOS-type clients. Google accepts public-client
        // refresh requests with just client_id + refresh_token.
        let body = [
          "client_id=\(clientId)",
          "refresh_token=\(refreshToken)",
          "grant_type=refresh_token",
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
          let code = (response as? HTTPURLResponse)?.statusCode ?? 0
          oauthLogger.error("Google token refresh failed: HTTP \(code, privacy: .public)")
          // Refresh failures are usually "token revoked" (401) or upstream
          // outages (5xx). Either way they're real errors worth surfacing.
          captureError(
            GoogleOAuthError.refreshFailed(code),
            context: ErrorContext.feature("google_oauth")
              .tag("op", "refresh")
              .tag("status", String(code))
          )
          throw GoogleOAuthError.refreshFailed(code)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccessToken = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Int
        else {
          throw GoogleOAuthError.invalidTokenResponse
        }

        let newExpiry = Date().addingTimeInterval(TimeInterval(expiresIn))
        try? await keychain.save(KeychainKey.googleAccessToken, newAccessToken)
        let newExpiryString = ISO8601DateFormatter().string(from: newExpiry)
        try? await keychain.save(KeychainKey.googleTokenExpiry, newExpiryString)

        oauthLogger.info("Google access token refreshed, expires in \(expiresIn, privacy: .public)s")
        return newAccessToken
      },
      isAuthorized: {
        @Dependency(\.keychain) var keychain
        guard let token = await keychain.read(KeychainKey.googleRefreshToken),
              !token.isEmpty
        else { return false }
        return true
      },
      disconnect: {
        @Dependency(\.keychain) var keychain
        await keychain.delete(KeychainKey.googleAccessToken)
        await keychain.delete(KeychainKey.googleRefreshToken)
        await keychain.delete(KeychainKey.googleTokenExpiry)
        UserDefaults.standard.removeObject(forKey: googleAccountEmailDefaultsKey)
        oauthLogger.info("Google OAuth tokens cleared from Keychain")
      },
      fetchUserEmail: {
        @Dependency(\.keychain) var keychain
        // Read the access token directly rather than calling refreshIfNeeded
        // (which lives on a sibling closure) — if it's expired the userinfo
        // call will surface a 401 and the caller can re-auth.
        guard let accessToken = await keychain.read(KeychainKey.googleAccessToken),
              !accessToken.isEmpty
        else { return nil }

        var request = URLRequest(url: userInfoEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
          let (data, response) = try await URLSession.shared.data(for: request)
          guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            oauthLogger.error("Google userinfo failed: HTTP \(code, privacy: .public)")
            return nil
          }
          guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let email = json["email"] as? String,
                !email.isEmpty
          else { return nil }
          UserDefaults.standard.set(email, forKey: googleAccountEmailDefaultsKey)
          return email
        } catch {
          oauthLogger.error("Google userinfo request threw: \(error.localizedDescription, privacy: .public)")
          return nil
        }
      }
    )
  }

  // MARK: - Token exchange

  private static func exchangeCode(_ code: String, codeVerifier: String) async throws -> GoogleTokens {
    var request = URLRequest(url: tokenEndpoint)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 15

    // PKCE token exchange: send code_verifier instead of client_secret.
    let body = [
      "code=\(code)",
      "client_id=\(clientId)",
      "code_verifier=\(codeVerifier)",
      "redirect_uri=\(redirectURI)",
      "grant_type=authorization_code",
    ].joined(separator: "&")
    request.httpBody = body.data(using: .utf8)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
      oauthLogger.error("Google token exchange failed: HTTP \(statusCode, privacy: .public)")
      throw GoogleOAuthError.tokenExchangeFailed(statusCode)
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let accessToken = json["access_token"] as? String,
          let refreshToken = json["refresh_token"] as? String,
          let expiresIn = json["expires_in"] as? Int
    else {
      throw GoogleOAuthError.invalidTokenResponse
    }

    let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
    return GoogleTokens(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt)
  }

  // MARK: - PKCE

  private static func generateCodeVerifier() -> String {
    // RFC 7636 §4.1 — verifier is 43-128 chars from [A-Z][a-z][0-9]-._~.
    // 32 random bytes → ~43 base64url chars after padding strip.
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return Data(bytes).pkceBase64URLEncoded()
  }

  private static func codeChallenge(for verifier: String) -> String {
    let hash = SHA256.hash(data: Data(verifier.utf8))
    return Data(hash).pkceBase64URLEncoded()
  }

  // MARK: - ASWebAuthenticationSession

  /// Runs the system-managed OAuth sheet on the main actor and resolves to
  /// the authorization code. Provider + session are kept alive via closure
  /// capture so they live for the duration of the awaited continuation.
  @MainActor
  private static func runWebAuth(authURL: URL, callbackScheme: String) async throws -> String {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
      let provider = WebAuthPresentationContext()
      var sessionHolder: ASWebAuthenticationSession?

      let session = ASWebAuthenticationSession(
        url: authURL,
        callbackURLScheme: callbackScheme
      ) { callbackURL, error in
        // Hold strong refs to provider + session until the callback fires —
        // ASWebAuthenticationSession.presentationContextProvider is weak.
        _ = provider
        _ = sessionHolder

        if let error {
          let nsError = error as NSError
          if nsError.domain == ASWebAuthenticationSessionError.errorDomain,
             nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
            continuation.resume(throwing: GoogleOAuthError.userCancelled)
          } else {
            continuation.resume(throwing: error)
          }
          return
        }
        guard let callbackURL,
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else {
          continuation.resume(throwing: GoogleOAuthError.invalidCallback)
          return
        }
        continuation.resume(returning: code)
      }

      session.presentationContextProvider = provider
      // false = reuse Safari's cookies, so a user already signed into Google
      // sees an account picker instead of a fresh login form.
      session.prefersEphemeralWebBrowserSession = false
      sessionHolder = session

      if !session.start() {
        continuation.resume(throwing: GoogleOAuthError.sessionFailedToStart)
      }
    }
  }
}

extension DependencyValues {
  var googleOAuth: GoogleOAuthClient {
    get { self[GoogleOAuthClient.self] }
    set { self[GoogleOAuthClient.self] = newValue }
  }
}

// MARK: - Presentation context

@MainActor
private final class WebAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    #if os(macOS)
    return NSApplication.shared.keyWindow
      ?? NSApplication.shared.windows.first
      ?? NSWindow()
    #else
    // Compiled into macOS target only — defensive default for cross-target
    // builds that pull this file in.
    return ASPresentationAnchor()
    #endif
  }
}

// MARK: - Base64URL helper

private extension Data {
  /// RFC 7636 §3 base64url encoding — strip padding, swap +/ for -_.
  func pkceBase64URLEncoded() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

// MARK: - Errors

enum GoogleOAuthError: LocalizedError {
  case invalidURL
  case notAuthorized
  case invalidCallback
  case userCancelled
  case sessionFailedToStart
  case tokenExchangeFailed(Int)
  case refreshFailed(Int)
  case invalidTokenResponse

  var errorDescription: String? {
    switch self {
    case .invalidURL:
      "Could not construct Google OAuth URL"
    case .notAuthorized:
      "Not signed in to Google — connect in Settings → Integrations."
    case .invalidCallback:
      "Invalid OAuth callback from Google"
    case .userCancelled:
      "Sign-in was cancelled."
    case .sessionFailedToStart:
      "Could not open the Google sign-in sheet."
    case .tokenExchangeFailed(let code):
      "Google token exchange failed (HTTP \(code))"
    case .refreshFailed(let code):
      "Google token refresh failed (HTTP \(code)) — try reconnecting in Settings."
    case .invalidTokenResponse:
      "Unexpected response from Google OAuth"
    }
  }
}
