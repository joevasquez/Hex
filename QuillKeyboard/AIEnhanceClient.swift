//
//  AIEnhanceClient.swift
//  QuillKeyboard
//
//  Standalone AI client for the keyboard extension. Deliberately
//  decoupled from the iOS-app `TextAIClient` so the keyboard target
//  doesn't have to link the whole HexCore graph (which would push us
//  past the keyboard memory budget).
//
//  Reads configuration from the App Group UserDefaults and the API
//  key from a shared keychain access group. Both are wired up in
//  `SETUP.md` — without that wiring, the keyboard falls back to
//  inserting the raw transcript and Enhance is greyed out.
//

import Foundation
import Security

enum AIEnhanceProvider: String {
  case anthropic
  case openAI

  var displayName: String {
    switch self {
    case .anthropic: "Anthropic"
    case .openAI: "OpenAI"
    }
  }

  /// Keychain account names — must match the constants used by the
  /// iOS app (`KeychainKey.anthropicAPIKey` / `.openAIAPIKey` in
  /// `Hex/Clients/KeychainClient.swift`) so the keyboard reads keys
  /// that the user already saved in Settings.
  var keychainAccount: String {
    switch self {
    case .anthropic: "com.joevasquez.Quill.anthropicAPIKey"
    case .openAI: "com.joevasquez.Quill.openAIAPIKey"
    }
  }
}

/// One-shot description of an enhancement call. Built off the user's
/// current settings + the host app's text context, then handed to the
/// client. Constructor returns nil when there's nothing to enhance
/// (empty transcript, missing API key, etc.).
struct AIEnhanceRequest {
  let provider: AIEnhanceProvider
  let apiKey: String
  let systemPrompt: String
  let userMessage: String

  static func build(
    transcript: String,
    contextBefore: String,
    contextAfter: String
  ) -> AIEnhanceRequest? {
    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let provider = KeyboardSharedPrefs.aiProvider
    guard let key = KeyboardKeychain.readSharedKey(account: provider.keychainAccount),
          !key.isEmpty
    else { return nil }

    let system = """
    You polish dictated text for insertion into another iOS app. \
    The user is currently typing into a text field; the cursor sits between \
    the BEFORE and AFTER context blocks below. Use those to match the \
    surrounding tone, formality, and language. Output ONLY the polished \
    replacement for the dictated text — no preamble, no quotes, no \
    explanations. Preserve the user's intent verbatim. Keep punctuation \
    and capitalization consistent with the surrounding context.

    BEFORE: \(contextBefore.suffix(400))
    AFTER: \(contextAfter.prefix(200))
    """

    return AIEnhanceRequest(
      provider: provider,
      apiKey: key,
      systemPrompt: system,
      userMessage: trimmed
    )
  }
}

enum AIEnhanceError: Error {
  case http(Int)
  case decoding
  case empty
}

final class AIEnhanceClient {
  static let shared = AIEnhanceClient()
  private let session: URLSession

  private init() {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 12
    cfg.timeoutIntervalForResource = 20
    self.session = URLSession(configuration: cfg)
  }

  func send(_ req: AIEnhanceRequest) async throws -> String {
    switch req.provider {
    case .anthropic: return try await callAnthropic(req)
    case .openAI: return try await callOpenAI(req)
    }
  }

  // MARK: - Anthropic

  private func callAnthropic(_ req: AIEnhanceRequest) async throws -> String {
    var urlRequest = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue(req.apiKey, forHTTPHeaderField: "x-api-key")
    urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

    let body: [String: Any] = [
      "model": "claude-haiku-4-5-20251001",
      "max_tokens": 512,
      "system": req.systemPrompt,
      "messages": [
        ["role": "user", "content": req.userMessage],
      ],
    ]
    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await session.data(for: urlRequest)
    guard let http = response as? HTTPURLResponse else { throw AIEnhanceError.decoding }
    guard (200..<300).contains(http.statusCode) else { throw AIEnhanceError.http(http.statusCode) }

    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let blocks = json?["content"] as? [[String: Any]],
          let text = blocks.compactMap({ $0["text"] as? String }).first,
          !text.isEmpty
    else { throw AIEnhanceError.empty }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - OpenAI

  private func callOpenAI(_ req: AIEnhanceRequest) async throws -> String {
    var urlRequest = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("Bearer \(req.apiKey)", forHTTPHeaderField: "Authorization")

    let body: [String: Any] = [
      "model": "gpt-4o-mini",
      "messages": [
        ["role": "system", "content": req.systemPrompt],
        ["role": "user", "content": req.userMessage],
      ],
      "temperature": 0.3,
    ]
    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await session.data(for: urlRequest)
    guard let http = response as? HTTPURLResponse else { throw AIEnhanceError.decoding }
    guard (200..<300).contains(http.statusCode) else { throw AIEnhanceError.http(http.statusCode) }

    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let choices = json?["choices"] as? [[String: Any]]
    let message = choices?.first?["message"] as? [String: Any]
    guard let text = message?["content"] as? String, !text.isEmpty else {
      throw AIEnhanceError.empty
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

// MARK: - Shared prefs

/// App Group bridge for non-sensitive settings the user has already
/// configured in the main app. The keyboard reads — never writes — so
/// the main app's Settings remain the single source of truth.
enum KeyboardSharedPrefs {
  private static let suite = UserDefaults(suiteName: "group.com.joevasquez.Quill")

  static var aiProvider: AIEnhanceProvider {
    let raw = suite?.string(forKey: "quill.aiProvider") ?? "anthropic"
    return AIEnhanceProvider(rawValue: raw) ?? .anthropic
  }
}

// MARK: - Shared keychain

/// Reads API keys from the shared keychain access group so the same
/// key the user pasted into Settings is available to the keyboard.
/// Requires the access group to be added to BOTH targets — see
/// `SETUP.md`. Without that wiring, `readSharedKey` returns nil and
/// the Enhance toggle is disabled.
enum KeyboardKeychain {
  private static let service = "com.joevasquez.Quill"
  private static let accessGroup = "com.joevasquez.Quill.shared"

  static func readSharedKey(account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrAccessGroup as String: accessGroup,
      kSecReturnData as String: kCFBooleanTrue as Any,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess,
          let data = result as? Data,
          let str = String(data: data, encoding: .utf8)
    else { return nil }
    return str
  }
}
