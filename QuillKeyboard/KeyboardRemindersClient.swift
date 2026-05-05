//
//  KeyboardRemindersClient.swift
//  QuillKeyboard
//
//  EventKit-backed reminder creation for the keyboard's Action mode.
//  Sandboxed keyboard extensions can call EventKit if the host app
//  declares NSRemindersUsageDescription (we do, in the keyboard's
//  Info.plist) and the user has granted Reminders access in the main
//  app. v1 only supports Apple Reminders — Todoist/Calendar/Gmail
//  need OAuth state we'd rather not bootstrap inside an extension.
//

import EventKit
import Foundation

enum KeyboardRemindersError: Error {
  case accessDenied
  case noDefaultCalendar
}

/// Concrete record returned to the keyboard view-model so it can show
/// the success badge with the right title.
struct KeyboardCreatedReminder: Equatable {
  let title: String
  let identifier: String
}

@MainActor
enum KeyboardRemindersClient {
  /// Single shared store — `EKEventStore` is heavyweight on init and
  /// the keyboard runs on a tight memory budget.
  private static let store = EKEventStore()

  static func create(_ intent: KeyboardActionIntent) async throws -> KeyboardCreatedReminder {
    let granted = (try? await store.requestFullAccessToReminders()) ?? false
    guard granted else { throw KeyboardRemindersError.accessDenied }

    let reminder = EKReminder(eventStore: store)
    reminder.title = intent.title
    if let notes = intent.notes, !notes.isEmpty {
      reminder.notes = notes
    }
    if let due = intent.dueDate, !due.isEmpty,
       let components = parseDueDate(due) {
      reminder.dueDateComponents = components
    }
    if let listName = intent.listName, !listName.isEmpty,
       let match = store.calendars(for: .reminder)
         .first(where: { $0.title.localizedCaseInsensitiveCompare(listName) == .orderedSame }) {
      reminder.calendar = match
    } else {
      reminder.calendar = store.defaultCalendarForNewReminders()
    }

    guard reminder.calendar != nil else {
      throw KeyboardRemindersError.noDefaultCalendar
    }

    try store.save(reminder, commit: true)
    return KeyboardCreatedReminder(
      title: reminder.title ?? intent.title,
      identifier: reminder.calendarItemIdentifier
    )
  }

  /// Slimmed copy of `IOSRemindersAdapter.parseDueDate` — the keyboard
  /// can't link HexCore, so we duplicate just the natural-language
  /// shapes the system prompt is likely to emit. Cheaper than dragging
  /// a date-parsing dependency into the extension.
  private static func parseDueDate(_ string: String) -> DateComponents? {
    let lower = string.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    let calendar = Calendar.current
    let now = Date()

    if lower == "today" {
      return calendar.dateComponents([.year, .month, .day], from: now)
    }
    if lower.hasPrefix("tomorrow") {
      guard let date = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
      return calendar.dateComponents([.year, .month, .day], from: date)
    }

    let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    for (index, name) in weekdays.enumerated() where lower.contains(name) {
      let targetWeekday = index + 1
      let currentWeekday = calendar.component(.weekday, from: now)
      var daysAhead = targetWeekday - currentWeekday
      if daysAhead <= 0 { daysAhead += 7 }
      if lower.contains("next") { daysAhead += 7 }
      guard let date = calendar.date(byAdding: .day, value: daysAhead, to: now) else { return nil }
      return calendar.dateComponents([.year, .month, .day], from: date)
    }

    return nil
  }
}
