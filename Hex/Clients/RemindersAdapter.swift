import Dependencies
import DependenciesMacros
import EventKit
import Foundation
import HexCore
import os

private let actionLogger = HexLog.action

@DependencyClient
struct RemindersAdapter {
  var requestAccess: @Sendable () async -> Bool = { false }
  var createReminder: @Sendable (ActionIntent) async throws -> String
  var fetchLists: @Sendable () async -> [String] = { [] }
}

extension RemindersAdapter: DependencyKey {
  static var liveValue: Self {
    let store = EKEventStore()

    return .init(
      requestAccess: {
        do {
          return try await store.requestFullAccessToReminders()
        } catch {
          actionLogger.error("Reminders access request failed: \(error.localizedDescription)")
          return false
        }
      },
      createReminder: { intent in
        actionLogger.info("Requesting Reminders access...")
        let granted: Bool
        do {
          granted = try await store.requestFullAccessToReminders()
        } catch {
          actionLogger.error("Reminders access threw: \(error.localizedDescription)")
          throw RemindersError.accessDenied
        }
        actionLogger.info("Reminders access granted=\(granted, privacy: .public)")
        guard granted else {
          throw RemindersError.accessDenied
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = intent.title

        if let listName = intent.listName, !listName.isEmpty {
          let calendars = store.calendars(for: .reminder)
          if let match = calendars.first(where: { $0.title.localizedCaseInsensitiveCompare(listName) == .orderedSame }) {
            reminder.calendar = match
            actionLogger.info("Using list: \(listName, privacy: .public)")
          } else {
            reminder.calendar = store.defaultCalendarForNewReminders()
            actionLogger.info("List '\(listName, privacy: .public)' not found; using default")
          }
        } else {
          reminder.calendar = store.defaultCalendarForNewReminders()
        }

        guard reminder.calendar != nil else {
          actionLogger.error("No calendar available for new reminders")
          throw RemindersError.accessDenied
        }

        if let dueDateString = intent.dueDate, !dueDateString.isEmpty {
          reminder.dueDateComponents = parseDueDate(dueDateString)
          actionLogger.info("Due date parsed: \(String(describing: reminder.dueDateComponents), privacy: .public)")
        }

        if let notes = intent.notes, !notes.isEmpty {
          reminder.notes = notes
        }

        do {
          try store.save(reminder, commit: true)
        } catch {
          actionLogger.error("EKEventStore.save failed: \(error.localizedDescription)")
          throw error
        }
        actionLogger.info("Created reminder id=\(reminder.calendarItemIdentifier, privacy: .public)")
        return reminder.calendarItemIdentifier
      },
      fetchLists: {
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        guard granted else { return [] }
        return store.calendars(for: .reminder).map(\.title)
      }
    )
  }
}

extension DependencyValues {
  var reminders: RemindersAdapter {
    get { self[RemindersAdapter.self] }
    set { self[RemindersAdapter.self] = newValue }
  }
}

private func parseDueDate(_ string: String) -> DateComponents? {
  let lower = string.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
  let calendar = Calendar.current
  let now = Date()

  if lower == "today" {
    return calendar.dateComponents([.year, .month, .day], from: now)
  }
  if lower == "tomorrow" || lower == "tomorrow morning" {
    guard let date = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
    return calendar.dateComponents([.year, .month, .day], from: date)
  }

  let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
  for (index, name) in weekdays.enumerated() {
    if lower.contains(name) {
      let targetWeekday = index + 1
      let currentWeekday = calendar.component(.weekday, from: now)
      var daysAhead = targetWeekday - currentWeekday
      if daysAhead <= 0 { daysAhead += 7 }
      if lower.contains("next") { daysAhead += 7 }
      guard let date = calendar.date(byAdding: .day, value: daysAhead, to: now) else { return nil }
      return calendar.dateComponents([.year, .month, .day], from: date)
    }
  }

  if lower.contains("next week") {
    guard let date = calendar.date(byAdding: .weekOfYear, value: 1, to: now) else { return nil }
    return calendar.dateComponents([.year, .month, .day], from: date)
  }
  if lower.contains("in two weeks") || lower.contains("in 2 weeks") {
    guard let date = calendar.date(byAdding: .weekOfYear, value: 2, to: now) else { return nil }
    return calendar.dateComponents([.year, .month, .day], from: date)
  }

  let formatter = DateFormatter()
  for format in ["MMMM d", "MMM d", "MMMM d, yyyy", "MMM d, yyyy", "MM/dd", "MM/dd/yyyy"] {
    formatter.dateFormat = format
    if let date = formatter.date(from: string) {
      var components = calendar.dateComponents([.month, .day], from: date)
      components.year = calendar.component(.year, from: now)
      if let resolved = calendar.date(from: components), resolved < now {
        components.year = calendar.component(.year, from: now) + 1
      }
      return components
    }
  }

  return nil
}

enum RemindersError: LocalizedError {
  case accessDenied

  var errorDescription: String? {
    switch self {
    case .accessDenied:
      "Reminders access was denied — grant permission in System Settings > Privacy & Security > Reminders."
    }
  }
}
