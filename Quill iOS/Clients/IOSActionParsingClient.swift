import Foundation
import HexCore

@MainActor
enum IOSActionParsingClient {
  private static let timeout: TimeInterval = 15

  static func parse(
    transcript: String,
    provider: AIProvider
  ) async throws -> ActionIntent {
    let response = try await parseMulti(transcript: transcript, provider: provider)
    guard let intent = response.actions.first else {
      throw TextAIError.invalidResponse
    }
    return intent
  }

  static func parseMulti(
    transcript: String,
    provider: AIProvider
  ) async throws -> MultiActionResponse {
    let account: String
    switch provider {
    case .anthropic: account = KeychainKey.anthropicAPIKey
    case .openAI: account = KeychainKey.openAIAPIKey
    }
    let (key, _) = KeychainStore.read(account: account)
    guard let key, !key.isEmpty else {
      throw TextAIError.missingAPIKey(provider)
    }

    let raw: String
    switch provider {
    case .anthropic:
      raw = try await callAnthropic(transcript: transcript, apiKey: key)
    case .openAI:
      raw = try await callOpenAI(transcript: transcript, apiKey: key)
    }

    return try parseMultiJSON(raw)
  }

  // MARK: - Anthropic

  private static func callAnthropic(transcript: String, apiKey: String) async throws -> String {
    let url = URL(string: "https://api.anthropic.com/v1/messages")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.timeoutInterval = timeout

    let body: [String: Any] = [
      "model": AIProvider.anthropic.defaultModel,
      "system": ActionSystemPrompt.prompt,
      "messages": [["role": "user", "content": transcript]],
      "max_tokens": 1024,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    try ensureOK(response: response, data: data)

    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let content = json?["content"] as? [[String: Any]],
          let first = content.first,
          let out = first["text"] as? String
    else { throw TextAIError.invalidResponse }
    return out
  }

  // MARK: - OpenAI

  private static func callOpenAI(transcript: String, apiKey: String) async throws -> String {
    let url = URL(string: "https://api.openai.com/v1/chat/completions")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = timeout

    let body: [String: Any] = [
      "model": AIProvider.openAI.defaultModel,
      "messages": [
        ["role": "system", "content": ActionSystemPrompt.prompt],
        ["role": "user", "content": transcript],
      ],
      "temperature": 0.1,
      "max_tokens": 1024,
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
    return out
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

  // MARK: - JSON parsing

  private static func parseJSON(_ text: String) throws -> ActionIntent {
    let response = try parseMultiJSON(text)
    guard let intent = response.actions.first else {
      throw TextAIError.invalidResponse
    }
    return intent
  }

  private static func parseMultiJSON(_ text: String) throws -> MultiActionResponse {
    var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.hasPrefix("```json") {
      cleaned = String(cleaned.dropFirst(7))
    } else if cleaned.hasPrefix("```") {
      cleaned = String(cleaned.dropFirst(3))
    }
    if cleaned.hasSuffix("```") {
      cleaned = String(cleaned.dropLast(3))
    }
    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

    guard let data = cleaned.data(using: .utf8) else {
      throw TextAIError.invalidResponse
    }

    if let response = try? JSONDecoder().decode(MultiActionResponse.self, from: data) {
      return response
    }

    let intent = try JSONDecoder().decode(ActionIntent.self, from: data)
    return MultiActionResponse(actions: [intent])
  }
}
