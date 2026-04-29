//
//  PhotoAnalysisClient.swift
//  Quill (iOS)
//
//  Ships a photo to the user's configured vision-capable LLM and returns
//  a structured `PhotoAnalysis`. Anthropic and OpenAI both support the
//  request shape we need; the response is parsed as JSON and stored as
//  a sidecar next to the photo.
//
//  Note: this client intentionally lives on the iOS target (not in
//  HexCore) because the macOS app doesn't have a notes/photos concept.
//

import Foundation
import HexCore
import os.log
import UIKit

enum PhotoAnalysisError: LocalizedError {
  case missingAPIKey(AIProvider)
  case networkFailure(Int, String)
  case invalidResponse
  case parseFailure(String)

  var errorDescription: String? {
    switch self {
    case .missingAPIKey(let p):
      "No \(p.displayName) API key configured — add one in Settings to enable photo analysis."
    case .networkFailure(let code, _):
      "Vision API returned HTTP \(code)"
    case .invalidResponse:
      "Invalid response from vision API"
    case .parseFailure(let s):
      "Could not parse analysis JSON: \(s.prefix(120))"
    }
  }
}

@MainActor
enum PhotoAnalysisClient {
  private static let timeout: TimeInterval = 45

  /// Read the API key for `provider` from the Keychain and dispatch a
  /// vision request. Throws if no key is present.
  ///
  /// Reads the keychain directly (not via `KeychainClient.liveValue`) so
  /// we can log the precise OSStatus on miss, and to sidestep any macro-
  /// generated wrapper behavior that could be intercepting the call.
  static func analyze(
    imageData: Data,
    provider: AIProvider
  ) async throws -> PhotoAnalysis {
    let account: String
    switch provider {
    case .anthropic: account = KeychainKey.anthropicAPIKey
    case .openAI: account = KeychainKey.openAIAPIKey
    }

    let (key, status) = KeychainStore.read(account: account)
    if let key, !key.isEmpty {
      HexLog.aiProcessing.info("PhotoAnalysisClient: found \(provider.displayName, privacy: .public) key")
      let payload = imageData.count > 4_000_000
        ? compressForVision(imageData) ?? imageData
        : imageData
      HexLog.aiProcessing.info("PhotoAnalysisClient: uploading \(payload.count, privacy: .public) bytes (was \(imageData.count, privacy: .public))")
      switch provider {
      case .anthropic: return try await callAnthropic(imageData: payload, apiKey: key)
      case .openAI: return try await callOpenAI(imageData: payload, apiKey: key)
      }
    }

    HexLog.aiProcessing.warning("PhotoAnalysisClient: keychain read for account=\(account, privacy: .public) returned status=\(status, privacy: .public)")
    throw PhotoAnalysisError.missingAPIKey(provider)
  }

  /// Resize + re-encode `data` to stay under the vision-API size cap.
  /// Targets 1568px long edge (Anthropic's recommended max) and steps
  /// down JPEG quality until the payload is under ~4.5 MB.
  private static func compressForVision(_ data: Data) -> Data? {
    guard let image = UIImage(data: data) else { return nil }
    let maxEdge: CGFloat = 1568
    let longest = max(image.size.width, image.size.height)
    let scale = min(1.0, maxEdge / longest)
    let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
    let resized = renderer.image { _ in
      image.draw(in: CGRect(origin: .zero, size: newSize))
    }

    for q in stride(from: 0.75, through: 0.3, by: -0.1) {
      if let encoded = resized.jpegData(compressionQuality: q), encoded.count < 4_500_000 {
        return encoded
      }
    }
    return resized.jpegData(compressionQuality: 0.3)
  }

  private static let systemPrompt = """
  You help a user build a comprehensive note by analyzing a photo they attached to a voice-dictated note. Photos often come from conferences (slides, whiteboards, posters), books, art, restaurants, or scenes the user wants to remember.

  Respond with ONLY a JSON object — no prose, no markdown fences, no preamble — matching this shape exactly:
  {
    "summary": "One concise sentence describing what's in the image.",
    "keyDetails": ["3-6 short bullets capturing useful extracted details"],
    "transcribedText": "All readable text from the image, verbatim, preserving line breaks. Use null if there is no meaningful text."
  }
  """

  // MARK: - Anthropic

  private static func callAnthropic(
    imageData: Data,
    apiKey: String
  ) async throws -> PhotoAnalysis {
    let model = AIProvider.anthropic.defaultModel
    let base64 = imageData.base64EncodedString()

    let url = URL(string: "https://api.anthropic.com/v1/messages")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.timeoutInterval = timeout

    let body: [String: Any] = [
      "model": model,
      "max_tokens": 1024,
      "system": systemPrompt,
      "messages": [[
        "role": "user",
        "content": [
          [
            "type": "image",
            "source": [
              "type": "base64",
              "media_type": "image/jpeg",
              "data": base64,
            ],
          ],
          ["type": "text", "text": "Analyze this photo and return the JSON."],
        ],
      ]],
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    try ensureOK(response: response, data: data)

    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let content = json?["content"] as? [[String: Any]],
          let first = content.first,
          let text = first["text"] as? String
    else { throw PhotoAnalysisError.invalidResponse }

    return try parse(jsonText: text, model: model)
  }

  // MARK: - OpenAI

  private static func callOpenAI(
    imageData: Data,
    apiKey: String
  ) async throws -> PhotoAnalysis {
    let model = AIProvider.openAI.defaultModel
    let base64 = imageData.base64EncodedString()

    let url = URL(string: "https://api.openai.com/v1/chat/completions")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = timeout

    let body: [String: Any] = [
      "model": model,
      "response_format": ["type": "json_object"],
      "max_tokens": 1024,
      "messages": [
        ["role": "system", "content": systemPrompt],
        [
          "role": "user",
          "content": [
            ["type": "text", "text": "Analyze this photo and return the JSON."],
            [
              "type": "image_url",
              "image_url": ["url": "data:image/jpeg;base64,\(base64)"],
            ],
          ],
        ],
      ],
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    try ensureOK(response: response, data: data)

    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let choices = json?["choices"] as? [[String: Any]],
          let first = choices.first,
          let msg = first["message"] as? [String: Any],
          let text = msg["content"] as? String
    else { throw PhotoAnalysisError.invalidResponse }

    return try parse(jsonText: text, model: model)
  }

  // MARK: - Helpers

  private static func ensureOK(response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else {
      throw PhotoAnalysisError.invalidResponse
    }
    guard http.statusCode == 200 else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw PhotoAnalysisError.networkFailure(http.statusCode, body)
    }
  }

  /// Even with JSON-mode / strict prompts, Anthropic sometimes wraps its
  /// response in ```json fences. Strip those before parsing.
  private static func parse(jsonText: String, model: String) throws -> PhotoAnalysis {
    let cleaned = jsonText
      .replacingOccurrences(of: "```json", with: "")
      .replacingOccurrences(of: "```", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard let data = cleaned.data(using: .utf8),
          let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw PhotoAnalysisError.parseFailure(cleaned)
    }

    let summary = (obj["summary"] as? String) ?? ""
    let details = (obj["keyDetails"] as? [String]) ?? []
    let transcribed = obj["transcribedText"] as? String

    return PhotoAnalysis(
      summary: summary,
      keyDetails: details,
      transcribedText: (transcribed?.isEmpty == false) ? transcribed : nil,
      analyzedAt: Date(),
      model: model
    )
  }
}
