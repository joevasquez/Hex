import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import os

private let actionLogger = HexLog.action

@DependencyClient
struct ActionParsingClient {
  var parse: @Sendable (String, AIProvider) async throws -> ActionIntent
}

extension ActionParsingClient: DependencyKey {
  static var liveValue: Self {
    .init(
      parse: { transcript, provider in
        @Dependency(\.keychain) var keychain

        let apiKey: String
        switch provider {
        case .openAI:
          guard let key = await keychain.read(KeychainKey.openAIAPIKey), !key.isEmpty else {
            throw ActionParsingError.missingAPIKey(provider)
          }
          apiKey = key
        case .anthropic:
          guard let key = await keychain.read(KeychainKey.anthropicAPIKey), !key.isEmpty else {
            throw ActionParsingError.missingAPIKey(provider)
          }
          apiKey = key
        }

        actionLogger.info("Parsing action from \(transcript.count, privacy: .public) chars via \(provider.displayName, privacy: .public)")

        let jsonString: String
        switch provider {
        case .openAI:
          jsonString = try await callOpenAI(transcript: transcript, apiKey: apiKey)
        case .anthropic:
          jsonString = try await callAnthropic(transcript: transcript, apiKey: apiKey)
        }

        let cleaned = jsonString
          .replacingOccurrences(of: "```json", with: "")
          .replacingOccurrences(of: "```", with: "")
          .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else {
          throw ActionParsingError.parseFailure(cleaned)
        }

        let intent = try JSONDecoder().decode(ActionIntent.self, from: data)
        actionLogger.info("Parsed action: type=\(intent.actionType.rawValue, privacy: .public) title=\(intent.title, privacy: .private)")
        return intent
      }
    )
  }
}

extension DependencyValues {
  var actionParsing: ActionParsingClient {
    get { self[ActionParsingClient.self] }
    set { self[ActionParsingClient.self] = newValue }
  }
}

// MARK: - System Prompt

private let actionSystemPrompt = """
You parse voice commands into structured task-creation actions. The user dictated a command wrapped in `<transcript>...</transcript>` tags. Parse it into a JSON object.

Respond with ONLY a JSON object — no prose, no markdown fences, no preamble.

Schema:
{
  "actionType": "createReminder" | "createTask",
  "targetIntegration": "appleReminders" | "todoist",
  "title": "Short task title extracted from the command",
  "dueDate": "Natural language date if mentioned (e.g. 'Friday', 'tomorrow', 'next week', 'December 5th'), or null",
  "notes": "Any additional details from the command, or null",
  "listName": "List or project name if mentioned, or null",
  "priority": 1-4 (Todoist convention: 4=highest, 1=lowest), or null
}

Integration detection (most important rule):
- If the user says "to Todoist", "in Todoist", "add to my Todoist", "Todoist task" → targetIntegration: "todoist", actionType: "createTask"
- If the user says "remind me", "to Reminders", "Apple Reminders", "to my reminders list" → targetIntegration: "appleReminders", actionType: "createReminder"
- If unspecified, default to "appleReminders" / "createReminder"
- ALWAYS strip the integration phrase from the title — "Add to Todoist write email to Mike" → title: "Write email to Mike", NOT "Add to Todoist write email to Mike"

Other rules:
- title should be a clean, concise task description — not the full transcript.
- Extract dates from phrases like "on Friday", "by tomorrow", "next Tuesday", "in two weeks".
- If the command says "remind me to X", the title is X (without "remind me to").
- If no date is mentioned, set dueDate to null.
- notes captures context beyond the core task: "for the quarterly review" → notes.
- listName is the named list (Reminders) or project (Todoist).
- priority only set if user mentions urgency: "urgent", "high priority", "ASAP" → 4; "important" → 3; "low priority" → 1; default null.

Examples:
  Input: <transcript>add to Todoist write email to Mike</transcript>
  Output: {"actionType":"createTask","targetIntegration":"todoist","title":"Write email to Mike","dueDate":null,"notes":null,"listName":null,"priority":null}

  Input: <transcript>add to my Todoist inbox: review Q3 plan, urgent, due Friday</transcript>
  Output: {"actionType":"createTask","targetIntegration":"todoist","title":"Review Q3 plan","dueDate":"Friday","notes":null,"listName":"Inbox","priority":4}

  Input: <transcript>remind me to review the launch deck on Friday</transcript>
  Output: {"actionType":"createReminder","targetIntegration":"appleReminders","title":"Review the launch deck","dueDate":"Friday","notes":null,"listName":null,"priority":null}

  Input: <transcript>remind me to call Amanda about the partnership proposal tomorrow morning</transcript>
  Output: {"actionType":"createReminder","targetIntegration":"appleReminders","title":"Call Amanda about the partnership proposal","dueDate":"tomorrow morning","notes":null,"listName":null,"priority":null}

  Input: <transcript>add buy groceries to my personal list</transcript>
  Output: {"actionType":"createReminder","targetIntegration":"appleReminders","title":"Buy groceries","dueDate":null,"notes":null,"listName":"Personal","priority":null}
"""

// MARK: - OpenAI

private func callOpenAI(transcript: String, apiKey: String) async throws -> String {
  let url = URL(string: "https://api.openai.com/v1/chat/completions")!
  var request = URLRequest(url: url)
  request.httpMethod = "POST"
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
  request.timeoutInterval = 15

  let userMessage = TranscriptWrapper.wrap(transcript)

  let body: [String: Any] = [
    "model": AIProvider.openAI.defaultModel,
    "response_format": ["type": "json_object"],
    "messages": [
      ["role": "system", "content": actionSystemPrompt],
      ["role": "user", "content": userMessage],
    ],
    "temperature": 0.1,
    "max_tokens": 512,
  ]
  request.httpBody = try JSONSerialization.data(withJSONObject: body)

  let (data, response) = try await URLSession.shared.data(for: request)

  guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    let body = String(data: data, encoding: .utf8) ?? ""
    throw ActionParsingError.apiError(code, body)
  }

  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  guard let choices = json?["choices"] as? [[String: Any]],
        let first = choices.first,
        let msg = first["message"] as? [String: Any],
        let content = msg["content"] as? String
  else { throw ActionParsingError.invalidResponse }

  return content
}

// MARK: - Anthropic

private func callAnthropic(transcript: String, apiKey: String) async throws -> String {
  let url = URL(string: "https://api.anthropic.com/v1/messages")!
  var request = URLRequest(url: url)
  request.httpMethod = "POST"
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
  request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
  request.timeoutInterval = 15

  let userMessage = TranscriptWrapper.wrap(transcript)

  let body: [String: Any] = [
    "model": AIProvider.anthropic.defaultModel,
    "system": actionSystemPrompt,
    "messages": [["role": "user", "content": userMessage]],
    "max_tokens": 512,
  ]
  request.httpBody = try JSONSerialization.data(withJSONObject: body)

  let (data, response) = try await URLSession.shared.data(for: request)

  guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    let body = String(data: data, encoding: .utf8) ?? ""
    throw ActionParsingError.apiError(code, body)
  }

  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  guard let content = json?["content"] as? [[String: Any]],
        let first = content.first,
        let text = first["text"] as? String
  else { throw ActionParsingError.invalidResponse }

  return text
}

// MARK: - Errors

enum ActionParsingError: LocalizedError {
  case missingAPIKey(AIProvider)
  case apiError(Int, String)
  case invalidResponse
  case parseFailure(String)

  var errorDescription: String? {
    switch self {
    case .missingAPIKey(let p):
      "No \(p.displayName) API key — add one in Settings."
    case .apiError(let code, _):
      "Action parsing failed (HTTP \(code))"
    case .invalidResponse:
      "Invalid response from AI service"
    case .parseFailure:
      "Could not parse action from AI response"
    }
  }
}
