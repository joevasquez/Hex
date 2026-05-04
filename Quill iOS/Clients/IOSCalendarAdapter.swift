import EventKit
import Foundation
import HexCore

@MainActor
enum IOSCalendarAdapter {
  private static let store = EKEventStore()

  static func requestAccess() async -> Bool {
    (try? await store.requestFullAccessToEvents()) ?? false
  }

  static func fetchCalendars() async -> [String] {
    guard await requestAccess() else { return [] }
    return store.calendars(for: .event).map(\.title)
  }

  static func createEvent(_ intent: ActionIntent) async throws -> String {
    guard await requestAccess() else {
      throw IOSActionError.accessDenied("Calendar")
    }

    let event = EKEvent(eventStore: store)
    event.title = intent.title

    if let s = intent.startDate, let e = intent.endDate {
      event.startDate = s
      event.endDate = e
    } else if let dueDateString = intent.dueDate, !dueDateString.isEmpty,
              let startDate = parseDateAndTime(dueDateString) {
      event.startDate = startDate
      let minutes = intent.duration ?? 60
      event.endDate = startDate.addingTimeInterval(Double(minutes) * 60)
    } else {
      let fallback = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
      event.startDate = fallback
      event.endDate = fallback.addingTimeInterval(3600)
    }

    if let listName = intent.listName, !listName.isEmpty {
      let calendars = store.calendars(for: .event)
      if let match = calendars.first(where: { $0.title.localizedCaseInsensitiveCompare(listName) == .orderedSame }) {
        event.calendar = match
      } else {
        event.calendar = store.defaultCalendarForNewEvents
      }
    } else {
      event.calendar = store.defaultCalendarForNewEvents
    }

    guard event.calendar != nil else {
      throw IOSActionError.accessDenied("Calendar")
    }

    var notesText = intent.notes ?? ""
    if let attendees = intent.attendees, !attendees.isEmpty {
      let attendeeLine = "Attendees: " + attendees.joined(separator: ", ")
      notesText = notesText.isEmpty ? attendeeLine : attendeeLine + "\n\n" + notesText
    }
    if !notesText.isEmpty {
      event.notes = notesText
    }

    try store.save(event, span: .thisEvent, commit: true)
    return event.calendarItemIdentifier
  }
}
