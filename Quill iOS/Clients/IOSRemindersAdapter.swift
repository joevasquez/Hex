import EventKit
import Foundation
import HexCore

@MainActor
enum IOSRemindersAdapter {
  private static let store = EKEventStore()

  static func requestAccess() async -> Bool {
    (try? await store.requestFullAccessToReminders()) ?? false
  }

  static func fetchLists() async -> [String] {
    guard await requestAccess() else { return [] }
    return store.calendars(for: .reminder).map(\.title)
  }

  static func createReminder(_ intent: ActionIntent) async throws -> String {
    guard await requestAccess() else {
      throw IOSActionError.accessDenied("Reminders")
    }

    let reminder = EKReminder(eventStore: store)
    reminder.title = intent.title

    if let listName = intent.listName, !listName.isEmpty {
      let calendars = store.calendars(for: .reminder)
      if let match = calendars.first(where: { $0.title.localizedCaseInsensitiveCompare(listName) == .orderedSame }) {
        reminder.calendar = match
      } else {
        reminder.calendar = store.defaultCalendarForNewReminders()
      }
    } else {
      reminder.calendar = store.defaultCalendarForNewReminders()
    }

    guard reminder.calendar != nil else {
      throw IOSActionError.accessDenied("Reminders")
    }

    if let dueDateString = intent.dueDate, !dueDateString.isEmpty {
      reminder.dueDateComponents = parseDueDate(dueDateString)
    }

    if let notes = intent.notes, !notes.isEmpty {
      reminder.notes = notes
    }

    try store.save(reminder, commit: true)
    return reminder.calendarItemIdentifier
  }

  private static func parseDueDate(_ string: String) -> DateComponents? {
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
}

enum IOSActionError: LocalizedError {
  case accessDenied(String)
  case missingToken(String)
  case apiError(String, Int)
  case invalidResponse(String)

  var errorDescription: String? {
    switch self {
    case .accessDenied(let service):
      "\(service) access was denied. Grant permission in Settings > Quill."
    case .missingToken(let service):
      "No \(service) token configured. Connect it in Settings > Integrations."
    case .apiError(let service, let code):
      "\(service) API returned HTTP \(code)."
    case .invalidResponse(let service):
      "Unexpected response from \(service)."
    }
  }
}
