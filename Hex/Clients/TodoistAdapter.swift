import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import os

private let actionLogger = HexLog.action

/// Todoist v1 REST API adapter.
/// Reference: https://developer.todoist.com/api/v1/
@DependencyClient
struct TodoistAdapter {
  /// Validates a token by calling `GET /api/v1/projects` and returning whether the call succeeded.
  /// On success, also returns the fetched projects so the caller can avoid a second round trip.
  var validateToken: @Sendable (_ token: String) async -> (isValid: Bool, projects: [TodoistProject]) = { _ in (false, []) }
  /// Creates a task. Reads token from Keychain, throws on missing/invalid.
  var createTask: @Sendable (ActionIntent) async throws -> String
  /// Returns project names for the project picker. Empty if no token configured.
  var fetchProjects: @Sendable () async -> [TodoistProject] = { [] }
}

struct TodoistProject: Equatable, Sendable, Identifiable {
  let id: String
  let name: String
}

extension TodoistAdapter: DependencyKey {
  static var liveValue: Self {
    .init(
      validateToken: { token in
        do {
          let projects = try await fetchProjectsRequest(token: token)
          return (true, projects)
        } catch {
          return (false, [])
        }
      },
      createTask: { intent in
        @Dependency(\.keychain) var keychain
        guard let token = await keychain.read(KeychainKey.todoistAPIToken), !token.isEmpty else {
          throw TodoistError.missingToken
        }

        var projectId: String?
        if let listName = intent.listName, !listName.isEmpty {
          let projects = (try? await fetchProjectsRequest(token: token)) ?? []
          if let match = projects.first(where: { $0.name.localizedCaseInsensitiveCompare(listName) == .orderedSame }) {
            projectId = match.id
            actionLogger.info("Todoist: matched project \(listName, privacy: .public)")
          } else {
            actionLogger.info("Todoist: project '\(listName, privacy: .public)' not found; using inbox")
          }
        }

        let id = try await createTaskRequest(token: token, intent: intent, projectId: projectId)
        actionLogger.info("Todoist: created task id=\(id, privacy: .public)")
        return id
      },
      fetchProjects: {
        @Dependency(\.keychain) var keychain
        guard let token = await keychain.read(KeychainKey.todoistAPIToken), !token.isEmpty else {
          return []
        }
        return (try? await fetchProjectsRequest(token: token)) ?? []
      }
    )
  }
}

extension DependencyValues {
  var todoist: TodoistAdapter {
    get { self[TodoistAdapter.self] }
    set { self[TodoistAdapter.self] = newValue }
  }
}

// MARK: - HTTP

private let baseURL = URL(string: "https://api.todoist.com/api/v1/")!

private func authorizedRequest(_ path: String, token: String, method: String = "GET") -> URLRequest {
  var request = URLRequest(url: baseURL.appendingPathComponent(path))
  request.httpMethod = method
  request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  request.timeoutInterval = 15
  return request
}

private func fetchProjectsRequest(token: String) async throws -> [TodoistProject] {
  let request = authorizedRequest("projects", token: token)
  let (data, response) = try await URLSession.shared.data(for: request)
  guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    throw TodoistError.apiError(code)
  }

  // The v1 API returns either a bare array or `{ "results": [...] }` depending on endpoint.
  if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
    return array.compactMap(parseProject)
  }
  if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
     let results = dict["results"] as? [[String: Any]] {
    return results.compactMap(parseProject)
  }
  throw TodoistError.invalidResponse
}

private func parseProject(_ obj: [String: Any]) -> TodoistProject? {
  // v1 API: `id` is a string. Older v2 may have returned numeric — coerce defensively.
  let id: String
  if let s = obj["id"] as? String { id = s }
  else if let n = obj["id"] as? Int { id = String(n) }
  else { return nil }
  guard let name = obj["name"] as? String else { return nil }
  return TodoistProject(id: id, name: name)
}

private func createTaskRequest(token: String, intent: ActionIntent, projectId: String?) async throws -> String {
  var request = authorizedRequest("tasks", token: token, method: "POST")

  var body: [String: Any] = ["content": intent.title]
  if let notes = intent.notes, !notes.isEmpty {
    body["description"] = notes
  }
  if let dueDate = intent.dueDate, !dueDate.isEmpty {
    body["due_string"] = dueDate
  }
  if let priority = intent.priority, (1...4).contains(priority) {
    body["priority"] = priority
  }
  if let projectId {
    body["project_id"] = projectId
  }

  request.httpBody = try JSONSerialization.data(withJSONObject: body)

  let (data, response) = try await URLSession.shared.data(for: request)
  guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    let bodyText = String(data: data, encoding: .utf8) ?? ""
    actionLogger.error("Todoist task creation failed \(code, privacy: .public): \(bodyText, privacy: .private)")
    throw TodoistError.apiError(code)
  }

  guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    throw TodoistError.invalidResponse
  }
  if let id = json["id"] as? String { return id }
  if let n = json["id"] as? Int { return String(n) }
  throw TodoistError.invalidResponse
}

// MARK: - Errors

enum TodoistError: LocalizedError {
  case missingToken
  case apiError(Int)
  case invalidResponse

  var errorDescription: String? {
    switch self {
    case .missingToken:
      "No Todoist token — connect Todoist in Settings → Integrations."
    case .apiError(let code):
      "Todoist API returned HTTP \(code)"
    case .invalidResponse:
      "Unexpected response from Todoist"
    }
  }
}
