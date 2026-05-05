//
//  KeyboardActionParser.swift
//  QuillKeyboard
//
//  Standalone Action-mode parser for the keyboard extension. v1
//  supports Apple Reminders only (works without OAuth + already a
//  shared system service). Other integrations (Todoist, Calendar,
//  Gmail, etc.) need network/OAuth state we don't want to bootstrap
//  inside an extension that's capped at ~48 MB.
//
//  Why not link HexCore's `ActionSystemPrompt`/`ActionIntent`? HexCore
//  pulls in TCA's `@Dependency` machinery + DependenciesMacros, which
//  the keyboard memory budget can't comfortably absorb. Duplicating
//  the small struct + a focused subset of the system prompt is the
//  cheaper trade-off.
//

import Foundation

/// Trimmed-down action shape for the keyboard. Mirrors a subset of
/// `HexCore.ActionIntent` but only the fields the keyboard uses for
/// Reminders creation. If we add more integrations to the keyboard
/// later, expand this carefully — every field added is a field we
/// have to keep in sync with HexCore.
struct KeyboardActionIntent: Codable, Equatable {
  var title: String
  var dueDate: String?
  var notes: String?
  var listName: String?
}

enum KeyboardActionError: Error {
  case noAPIKey
  case parseFailed(String)
  case http(Int)
  case malformed
}

/// Calls the user's configured AI provider with a Reminders-focused
/// system prompt and decodes the result into `KeyboardActionIntent`.
enum KeyboardActionParser {
  /// Reminders-only system prompt — the broader integration-routing
  /// prompt in HexCore is unnecessary here because the keyboard
  /// hard-codes Apple Reminders as the destination. Smaller prompt =
  /// fewer tokens = faster response inside the extension's network
  /// budget.
  private static let systemPrompt = """
  You parse a voice command into an Apple Reminders task. The user dictated a command wrapped in <transcript>...</transcript>. Respond with ONLY a JSON object — no prose, no markdown fences, no preamble.

  Schema:
  {
    "title": "Short clean task title",
    "dueDate": "Natural language date/time if mentioned (e.g. 'Friday', 'tomorrow at 9am'), or null",
    "notes": "Additional context beyond the core task, or null",
    "listName": "List name if explicitly mentioned (e.g. 'on my Personal list'), or null"
  }

  Rules:
  - Extract a clean concise title — drop "remind me to", "add", and similar prefixes.
  - Set dueDate ONLY if the user mentions a time/date.
  - Set listName ONLY if the user mentions a list/folder name.
  - Set notes ONLY for context that doesn't fit in the title (e.g. "for the quarterly review").

  Examples:
    Input: <transcript>remind me to call mom on Friday</transcript>
    Output: {"title":"Call mom","dueDate":"Friday","notes":null,"listName":null}

    Input: <transcript>add buy groceries to my personal list</transcript>
    Output: {"title":"Buy groceries","dueDate":null,"notes":null,"listName":"Personal"}

    Input: <transcript>review the launch deck before tomorrow morning, this is for the leadership offsite</transcript>
    Output: {"title":"Review the launch deck","dueDate":"tomorrow morning","notes":"For the leadership offsite","listName":null}
  """

  static func parse(transcript: String) async throws -> KeyboardActionIntent {
    let provider = KeyboardSharedPrefs.aiProvider
    guard let apiKey = KeyboardKeychain.readSharedKey(account: provider.keychainAccount),
          !apiKey.isEmpty
    else { throw KeyboardActionError.noAPIKey }

    let user = "<transcript>\(transcript)</transcript>"

    let raw: String
    switch provider {
    case .anthropic:
      raw = try await callAnthropic(systemPrompt: systemPrompt, userMessage: user, apiKey: apiKey)
    case .openAI:
      raw = try await callOpenAI(systemPrompt: systemPrompt, userMessage: user, apiKey: apiKey)
    }

    let cleaned = stripCodeFence(raw)
    guard let data = cleaned.data(using: .utf8) else {
      throw KeyboardActionError.malformed
    }
    do {
      return try JSONDecoder().decode(KeyboardActionIntent.self, from: data)
    } catch {
      throw KeyboardActionError.parseFailed(error.localizedDescription)
    }
  }

  // MARK: - Provider calls (focused subset of AIEnhanceClient)

  private static func callAnthropic(
    systemPrompt: String,
    userMessage: String,
    apiKey: String
  ) async throws -> String {
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    req.timeoutInterval = 12

    let body: [String: Any] = [
      "model": "claude-haiku-4-5-20251001",
      "max_tokens": 256,
      "system": systemPrompt,
      "messages": [["role": "user", "content": userMessage]],
    ]
    req.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse,
          (200..<300).contains(http.statusCode) else {
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      throw KeyboardActionError.http(code)
    }
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let blocks = json?["content"] as? [[String: Any]]
    guard let text = blocks?.compactMap({ $0["text"] as? String }).first, !text.isEmpty else {
      throw KeyboardActionError.malformed
    }
    return text
  }

  private static func callOpenAI(
    systemPrompt: String,
    userMessage: String,
    apiKey: String
  ) async throws -> String {
    var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    req.timeoutInterval = 12

    let body: [String: Any] = [
      "model": "gpt-4o-mini",
      "response_format": ["type": "json_object"],
      "messages": [
        ["role": "system", "content": systemPrompt],
        ["role": "user", "content": userMessage],
      ],
      "temperature": 0.1,
    ]
    req.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse,
          (200..<300).contains(http.statusCode) else {
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      throw KeyboardActionError.http(code)
    }
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let choices = json?["choices"] as? [[String: Any]]
    let message = choices?.first?["message"] as? [String: Any]
    guard let text = message?["content"] as? String, !text.isEmpty else {
      throw KeyboardActionError.malformed
    }
    return text
  }

  /// Strips ```json fences if the model returns them despite the
  /// "no markdown" instruction. Cheap defensive parse — saves a retry.
  private static func stripCodeFence(_ s: String) -> String {
    var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if out.hasPrefix("```") {
      // remove first line (```json or ```), then trailing fence
      if let firstNewline = out.firstIndex(of: "\n") {
        out = String(out[out.index(after: firstNewline)...])
      }
      if out.hasSuffix("```") {
        out = String(out.dropLast(3))
      }
      out = out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return out
  }
}
