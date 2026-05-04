import Foundation

/// Parses natural-language date+time strings (e.g. "June 3rd at 2pm",
/// "tomorrow at 10:30am", "Friday at noon") into a concrete `Date`.
/// Used by calendar adapters and confirmation panels to seed pickers.
/// Defaults time to 9:00 AM when only a date is given.
public func parseDateAndTime(_ string: String) -> Date? {
  let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
  let lower = trimmed.lowercased()
  let cal = Calendar.current
  let now = Date()

  var datePart: Date?
  var timePart: (hour: Int, minute: Int)?

  let timePattern = /(?:at\s+|@\s*)(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?/
  if let match = lower.firstMatch(of: timePattern) {
    var hour = Int(match.1)!
    let minute = match.2.map { Int($0)! } ?? 0
    if let period = match.3 {
      let p = period.replacingOccurrences(of: ".", with: "")
      if p == "pm" && hour < 12 { hour += 12 }
      if p == "am" && hour == 12 { hour = 0 }
    }
    timePart = (hour, minute)
  }

  let dateString: String
  if let range = lower.firstRange(of: /\s*(?:at\s+|@\s*)\d{1,2}(?::\d{2})?\s*(?:am|pm|a\.m\.|p\.m\.)?.*$/) {
    dateString = String(lower[lower.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
  } else {
    dateString = lower
  }

  // Match "tomorrow" first so "tomorrow morning at 2pm" (or any other
  // qualifier) lands on +1 day. Previously this was an exact-string
  // comparison, which broke whenever the user added a filler like
  // "morning"/"afternoon"/"evening". Same widening for today markers
  // ("tonight", "this morning", "this evening") which previously
  // returned nil and silently fell back to today-at-9am.
  if dateString.contains("tomorrow") {
    datePart = cal.date(byAdding: .day, value: 1, to: now)
  } else if dateString.isEmpty
              || dateString.contains("today")
              || dateString.contains("tonight")
              || dateString.contains("this morning")
              || dateString.contains("this afternoon")
              || dateString.contains("this evening")
              || dateString.contains("this night") {
    datePart = now
  } else {
    let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    for (index, name) in weekdays.enumerated() {
      if dateString.contains(name) {
        let targetWeekday = index + 1
        let currentWeekday = cal.component(.weekday, from: now)
        var daysAhead = targetWeekday - currentWeekday
        if daysAhead <= 0 { daysAhead += 7 }
        if dateString.contains("next") { daysAhead += 7 }
        datePart = cal.date(byAdding: .day, value: daysAhead, to: now)
        break
      }
    }

    if datePart == nil {
      if dateString.contains("next week") {
        datePart = cal.date(byAdding: .weekOfYear, value: 1, to: now)
      } else if dateString.contains("in two weeks") || dateString.contains("in 2 weeks") {
        datePart = cal.date(byAdding: .weekOfYear, value: 2, to: now)
      }
    }

    if datePart == nil {
      let formatter = DateFormatter()
      for format in ["MMMM d", "MMM d", "MMMM d, yyyy", "MMM d, yyyy", "MM/dd", "MM/dd/yyyy"] {
        formatter.dateFormat = format
        if let date = formatter.date(from: trimmed.replacing(/\s*(?:at\s+|@\s*).+$/, with: "")) {
          var components = cal.dateComponents([.month, .day], from: date)
          let year = format.contains("yyyy")
            ? cal.component(.year, from: date)
            : cal.component(.year, from: now)
          components.year = year
          if let resolved = cal.date(from: components), resolved < now, !format.contains("yyyy") {
            components.year = year + 1
          }
          datePart = cal.date(from: components)
          break
        }
      }
    }
  }

  guard let baseDate = datePart else { return nil }

  let hour = timePart?.hour ?? 9
  let minute = timePart?.minute ?? 0
  return cal.date(bySettingHour: hour, minute: minute, second: 0, of: baseDate)
}
