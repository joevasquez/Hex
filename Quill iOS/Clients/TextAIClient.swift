//
//  TextAIClient.swift
//  Quill (iOS)
//
//  Text post-processor for dictated transcripts. Mirrors the shared
//  `AIProcessingClient` but reads the API key via `KeychainStore`
//  directly — the shared client goes through `@Dependency(\.keychain)`
//  which is unreliable on the iOS target under `SWIFT_DEFAULT_ACTOR_ISOLATION =
//  MainActor` (same bug that blocked photo analysis). Keeping iOS
//  text-processing self-contained means switching AI modes ("Notes",
//  "Email", etc.) actually hits the LLM instead of silently falling
//  back to the raw transcript.
//

import Foundation
import HexCore

enum TextAIError: LocalizedError {
  case missingAPIKey(AIProvider)
  case networkFailure(Int, String)
  case invalidResponse

  var errorDescription: String? {
    switch self {
    case .missingAPIKey(let p):
      "No \(p.displayName) API key — add one in Settings."
    case .networkFailure(let code, _):
      "AI service returned HTTP \(code)"
    case .invalidResponse:
      "Unexpected response from AI service"
    }
  }
}

@MainActor
enum TextAIClient {
  private static let timeout: TimeInterval = 30

  static func process(
    text: String,
    mode: AIProcessingMode,
    provider: AIProvider
  ) async throws -> String {
    guard mode != .off else { return text }

    let account: String
    switch provider {
    case .anthropic: account = KeychainKey.anthropicAPIKey
    case .openAI: account = KeychainKey.openAIAPIKey
    }
    let (key, status) = KeychainStore.read(account: account)
    guard let key, !key.isEmpty else {
      print("TextAIClient: no \(provider.displayName) key (status=\(status))")
      throw TextAIError.missingAPIKey(provider)
    }
    print("TextAIClient: processing \(text.count) chars via \(provider.displayName) mode=\(mode.rawValue)")

    let result: String
    switch provider {
    case .anthropic:
      result = try await callAnthropic(text: text, systemPrompt: mode.systemPrompt, apiKey: key)
    case .openAI:
      result = try await callOpenAI(text: text, systemPrompt: mode.systemPrompt, apiKey: key)
    }
    print(
      "TextAIClient: response \(result.count) chars — first 400:\n\(String(result.prefix(400)))\n---"
    )

    // Safety net: if the model ignored the system prompt and treated
    // the transcript as a conversation (answering a question, refusing
    // to transform, narrating its own role), fall back to the raw
    // transcript so the user's dictation is never replaced by an
    // assistant-style reply.
    if TranscriptRefusalDetector.isRefusal(result) {
      print("TextAIClient: response looks like a refusal; falling back to raw transcript")
      return text
    }

    return result
  }

  // MARK: - Anthropic

  private static func callAnthropic(
    text: String,
    systemPrompt: String,
    apiKey: String
  ) async throws -> String {
    let url = URL(string: "https://api.anthropic.com/v1/messages")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.timeoutInterval = timeout

    let userMessage = TranscriptWrapper.wrap(text)

    let body: [String: Any] = [
      "model": AIProvider.anthropic.defaultModel,
      "system": systemPrompt,
      "messages": [["role": "user", "content": userMessage]],
      "max_tokens": 2048,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    try ensureOK(response: response, data: data)

    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let content = json?["content"] as? [[String: Any]],
          let first = content.first,
          let out = first["text"] as? String
    else { throw TextAIError.invalidResponse }
    return stripMetaCommentary(out)
  }

  // MARK: - OpenAI

  private static func callOpenAI(
    text: String,
    systemPrompt: String,
    apiKey: String
  ) async throws -> String {
    let url = URL(string: "https://api.openai.com/v1/chat/completions")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = timeout

    let userMessage = TranscriptWrapper.wrap(text)

    let body: [String: Any] = [
      "model": AIProvider.openAI.defaultModel,
      "messages": [
        ["role": "system", "content": systemPrompt],
        ["role": "user", "content": userMessage],
      ],
      "temperature": 0.3,
      "max_tokens": 2048,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    try ensureOK(response: response, data: data)

    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let choices = json?["choices"] as? [[String: Any]],
          let first = choices.first,
          let msg = first["message"] as? [String: Any],
          let out = msg["content"] as? String
    else { throw TextAIError.invalidResponse }
    return stripMetaCommentary(out)
  }

  private static func ensureOK(response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else {
      throw TextAIError.invalidResponse
    }
    guard http.statusCode == 200 else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw TextAIError.networkFailure(http.statusCode, body)
    }
  }

  /// Strip leading "Here is…" / trailing "Note:…" noise that slips past
  /// the system prompt occasionally. Matches the behavior of the shared
  /// macOS client.
  private static func stripMetaCommentary(_ text: String) -> String {
    var result = text
    let preamblePatterns = [
      #"^(?:Here(?:'s| is) (?:the |your )?(?:corrected|cleaned|formatted|revised|updated|fixed|improved)[\w ]*(?:text|version|speech|transcription|notes|email|message)?[:\-—]*\s*\n*)"#,
      #"^(?:The (?:corrected|cleaned|formatted) (?:text|version) is[:\-—]*\s*\n*)"#,
      #"^(?:Sure[!,.]?\s*(?:Here(?:'s| is)[\w ]*[:\-—]*)?\s*\n*)"#,
    ]
    for pattern in preamblePatterns {
      if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
        let range = NSRange(result.startIndex..., in: result)
        result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
      }
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
