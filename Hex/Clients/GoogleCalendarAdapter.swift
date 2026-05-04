import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import os

private let actionLogger = HexLog.action

struct GoogleCalendar: Equatable, Sendable, Identifiable {
  let id: String
  let name: String
}

@DependencyClient
struct GoogleCalendarAdapter {
  var createEvent: @Sendable (ActionIntent) async throws -> String
  var fetchCalendars: @Sendable () async -> [GoogleCalendar] = { [] }
}

extension GoogleCalendarAdapter: DependencyKey {
  static var liveValue: Self {
    .init(
      createEvent: { intent in
        @Dependency(\.googleOAuth) var googleOAuth

        let accessToken = try await googleOAuth.refreshIfNeeded()

        let calendarId: String
        if let listName = intent.listName, !listName.isEmpty {
          let calendars = await fetchCalendarList(accessToken: accessToken)
          calendarId = calendars.first(where: {
            $0.name.localizedCaseInsensitiveCompare(listName) == .orderedSame
          })?.id ?? "primary"
          if calendarId == "primary" {
            actionLogger.info("Google Calendar '\(listName, privacy: .public)' not found; using primary")
          }
        } else {
          calendarId = "primary"
        }

        let startDate: Date
        let endDate: Date

        if let s = intent.startDate, let e = intent.endDate {
          startDate = s
          endDate = e
        } else if let dueDateString = intent.dueDate, !dueDateString.isEmpty,
                  let parsed = parseDateAndTime(dueDateString) {
          startDate = parsed
          let minutes = intent.duration ?? 60
          endDate = parsed.addingTimeInterval(Double(minutes) * 60)
        } else {
          let fallback = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
          startDate = fallback
          endDate = fallback.addingTimeInterval(3600)
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var eventBody: [String: Any] = [
          "summary": intent.title,
          "start": ["dateTime": iso.string(from: startDate)],
          "end": ["dateTime": iso.string(from: endDate)],
        ]

        if let notes = intent.notes, !notes.isEmpty {
          eventBody["description"] = notes
        }

        if let attendees = intent.attendees, !attendees.isEmpty {
          eventBody["attendees"] = attendees.map { ["email": $0] }
        }

        let encodedCalendarId = calendarId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarId
        let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarId)/events")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: eventBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
          let code = (response as? HTTPURLResponse)?.statusCode ?? 0
          let bodyText = String(data: data, encoding: .utf8) ?? ""
          actionLogger.error("Google Calendar event creation failed \(code, privacy: .public): \(bodyText, privacy: .private)")
          throw GoogleCalendarError.apiError(code)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventId = json["id"] as? String
        else {
          throw GoogleCalendarError.invalidResponse
        }

        actionLogger.info("Created Google Calendar event id=\(eventId, privacy: .public)")
        return eventId
      },
      fetchCalendars: {
        @Dependency(\.googleOAuth) var googleOAuth
        guard let accessToken = try? await googleOAuth.refreshIfNeeded() else {
          return []
        }
        return await fetchCalendarList(accessToken: accessToken)
      }
    )
  }
}

extension DependencyValues {
  var googleCalendarAdapter: GoogleCalendarAdapter {
    get { self[GoogleCalendarAdapter.self] }
    set { self[GoogleCalendarAdapter.self] = newValue }
  }
}

private func fetchCalendarList(accessToken: String) async -> [GoogleCalendar] {
  let url = URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
  var request = URLRequest(url: url)
  request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
  request.timeoutInterval = 15

  guard let (data, response) = try? await URLSession.shared.data(for: request),
        let http = response as? HTTPURLResponse,
        http.statusCode == 200,
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let items = json["items"] as? [[String: Any]]
  else {
    return []
  }

  return items.compactMap { item in
    guard let id = item["id"] as? String,
          let name = item["summary"] as? String
    else { return nil }
    return GoogleCalendar(id: id, name: name)
  }
}

enum GoogleCalendarError: LocalizedError {
  case apiError(Int)
  case invalidResponse

  var errorDescription: String? {
    switch self {
    case .apiError(let code):
      "Google Calendar API returned HTTP \(code)"
    case .invalidResponse:
      "Unexpected response from Google Calendar"
    }
  }
}
