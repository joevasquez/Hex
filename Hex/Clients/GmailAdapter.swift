import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import os

private let actionLogger = HexLog.action

@DependencyClient
struct GmailAdapter {
  var createDraft: @Sendable (ActionIntent) async throws -> String
}

extension GmailAdapter: DependencyKey {
  static var liveValue: Self {
    .init(
      createDraft: { intent in
        @Dependency(\.googleOAuth) var googleOAuth

        let accessToken = try await googleOAuth.refreshIfNeeded()

        let to = intent.recipient ?? ""
        let subject = intent.subject ?? intent.title
        let body = intent.notes ?? intent.title

        let rfc2822 = buildRFC2822Message(to: to, subject: subject, body: body)
        let base64URL = rfc2822
          .data(using: .utf8)!
          .base64EncodedString()
          .replacingOccurrences(of: "+", with: "-")
          .replacingOccurrences(of: "/", with: "_")
          .replacingOccurrences(of: "=", with: "")

        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/drafts")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let payload: [String: Any] = [
          "message": ["raw": base64URL],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
          let code = (response as? HTTPURLResponse)?.statusCode ?? 0
          let bodyText = String(data: data, encoding: .utf8) ?? ""
          actionLogger.error("Gmail draft creation failed \(code, privacy: .public): \(bodyText, privacy: .private)")
          // Don't include the response body in the captured context — it
          // can echo the user's draft text back. Status code + endpoint
          // is enough to triage.
          captureError(
            GmailError.apiError(code),
            context: ErrorContext.feature("gmail")
              .tag("op", "create_draft")
              .tag("status", String(code))
          )
          throw GmailError.apiError(code)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let draftId = json["id"] as? String
        else {
          captureError(GmailError.invalidResponse, context: ErrorContext.feature("gmail").tag("op", "create_draft"))
          throw GmailError.invalidResponse
        }

        actionLogger.info("Created Gmail draft id=\(draftId, privacy: .public)")
        return draftId
      }
    )
  }
}

extension DependencyValues {
  var gmailAdapter: GmailAdapter {
    get { self[GmailAdapter.self] }
    set { self[GmailAdapter.self] = newValue }
  }
}

private func buildRFC2822Message(to: String, subject: String, body: String) -> String {
  var lines: [String] = []
  if !to.isEmpty {
    lines.append("To: \(to)")
  }
  lines.append("Subject: \(subject)")
  lines.append("Content-Type: text/plain; charset=\"UTF-8\"")
  lines.append("")
  lines.append(body)
  return lines.joined(separator: "\r\n")
}

enum GmailError: LocalizedError {
  case apiError(Int)
  case invalidResponse

  var errorDescription: String? {
    switch self {
    case .apiError(let code):
      "Gmail API returned HTTP \(code)"
    case .invalidResponse:
      "Unexpected response from Gmail"
    }
  }
}
