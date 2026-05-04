//
//  IOSGmailAdapter.swift
//  Quill (iOS)
//
//  iOS port of `Hex/Clients/GmailAdapter.swift`. Same Gmail v1 REST flow
//  (RFC 2822 message → base64url → POST drafts) but adapted to iOS:
//  - `IOSGoogleOAuthClient` for the access token (KeychainStore-backed,
//    no TCA dependency)
//  - `@MainActor enum` with static methods (no `@DependencyClient`)
//
//  Action mode confirmation calls this directly when the user picks Gmail
//  as the target integration. `IOSSystemActionQueueExecutor` calls it for
//  queued replays after connectivity returns.
//

import Foundation
import HexCore
import os

private let actionLogger = HexLog.action

@MainActor
enum IOSGmailAdapter {
  /// Creates a draft email in the signed-in user's Gmail. Returns the
  /// Gmail-assigned draft ID. Throws `IOSActionError.apiError` on
  /// non-2xx responses; `IOSActionError.invalidResponse` if the JSON
  /// is missing the expected `id` field.
  static func createDraft(_ intent: ActionIntent) async throws -> String {
    let accessToken = try await IOSGoogleOAuthClient.refreshIfNeeded()

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

    let payload: [String: Any] = ["message": ["raw": base64URL]]
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      let bodyText = String(data: data, encoding: .utf8) ?? ""
      actionLogger.error("Gmail draft creation failed (iOS) \(code, privacy: .public): \(bodyText, privacy: .private)")
      // Status + op only — never include the response body, which can
      // echo the user's draft text back into Sentry.
      captureError(
        IOSActionError.apiError("Gmail", code),
        context: ErrorContext.feature("gmail")
          .tag("platform", "ios")
          .tag("op", "create_draft")
          .tag("status", String(code))
      )
      throw IOSActionError.apiError("Gmail", code)
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let draftId = json["id"] as? String
    else {
      captureError(
        IOSActionError.invalidResponse("Gmail"),
        context: ErrorContext.feature("gmail")
          .tag("platform", "ios")
          .tag("op", "create_draft")
      )
      throw IOSActionError.invalidResponse("Gmail")
    }

    actionLogger.info("Created Gmail draft (iOS) id=\(draftId, privacy: .public)")
    return draftId
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
