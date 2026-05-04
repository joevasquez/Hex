import Dependencies
import DependenciesMacros
import EventKit
import Foundation
import HexCore
import os

private let actionLogger = HexLog.action

@DependencyClient
struct CalendarAdapter {
  var requestAccess: @Sendable () async -> Bool = { false }
  var createEvent: @Sendable (ActionIntent) async throws -> String
  var fetchCalendars: @Sendable () async -> [String] = { [] }
}

extension CalendarAdapter: DependencyKey {
  static var liveValue: Self {
    let store = EKEventStore()

    return .init(
      requestAccess: {
        do {
          return try await store.requestFullAccessToEvents()
        } catch {
          actionLogger.error("Calendar access request failed: \(error.localizedDescription)")
          return false
        }
      },
      createEvent: { intent in
        let granted: Bool
        do {
          granted = try await store.requestFullAccessToEvents()
        } catch {
          actionLogger.error("Calendar access threw: \(error.localizedDescription)")
          throw CalendarError.accessDenied
        }
        guard granted else { throw CalendarError.accessDenied }

        let event = EKEvent(eventStore: store)
        event.title = intent.title

        if let s = intent.startDate, let e = intent.endDate {
          event.startDate = s
          event.endDate = e
          actionLogger.info("Event start=\(s, privacy: .public) end=\(e, privacy: .public) (from picker)")
        } else if let dueDateString = intent.dueDate, !dueDateString.isEmpty,
                  let startDate = parseDateAndTime(dueDateString) {
          event.startDate = startDate
          let minutes = intent.duration ?? 60
          event.endDate = startDate.addingTimeInterval(Double(minutes) * 60)
          actionLogger.info("Event start=\(startDate, privacy: .public) duration=\(minutes, privacy: .public)min")
        } else {
          let fallback = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
          event.startDate = fallback
          event.endDate = fallback.addingTimeInterval(3600)
          actionLogger.info("No date parsed; defaulting to today at 9am")
        }

        if let listName = intent.listName, !listName.isEmpty {
          let calendars = store.calendars(for: .event)
          if let match = calendars.first(where: { $0.title.localizedCaseInsensitiveCompare(listName) == .orderedSame }) {
            event.calendar = match
            actionLogger.info("Using calendar: \(listName, privacy: .public)")
          } else {
            event.calendar = store.defaultCalendarForNewEvents
            actionLogger.info("Calendar '\(listName, privacy: .public)' not found; using default")
          }
        } else {
          event.calendar = store.defaultCalendarForNewEvents
        }

        guard event.calendar != nil else {
          actionLogger.error("No calendar available for new events")
          throw CalendarError.accessDenied
        }

        var notesText = intent.notes ?? ""
        if let attendees = intent.attendees, !attendees.isEmpty {
          let attendeeLine = "Attendees: " + attendees.joined(separator: ", ")
          notesText = notesText.isEmpty ? attendeeLine : attendeeLine + "\n\n" + notesText
        }
        if !notesText.isEmpty {
          event.notes = notesText
        }

        do {
          try store.save(event, span: .thisEvent, commit: true)
        } catch {
          actionLogger.error("EKEventStore.save event failed: \(error.localizedDescription)")
          throw error
        }
        actionLogger.info("Created event id=\(event.calendarItemIdentifier, privacy: .public)")
        return event.calendarItemIdentifier
      },
      fetchCalendars: {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        guard granted else { return [] }
        return store.calendars(for: .event).map(\.title)
      }
    )
  }
}

extension DependencyValues {
  var calendarAdapter: CalendarAdapter {
    get { self[CalendarAdapter.self] }
    set { self[CalendarAdapter.self] = newValue }
  }
}

// MARK: - Errors

enum CalendarError: LocalizedError {
  case accessDenied

  var errorDescription: String? {
    switch self {
    case .accessDenied:
      "Calendar access was denied — grant permission in System Settings > Privacy & Security > Calendars."
    }
  }
}
