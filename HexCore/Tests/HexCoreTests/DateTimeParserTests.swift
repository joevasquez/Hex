import Foundation
import Testing
@testable import HexCore

/// Locks the parser's behavior on the day/time strings the LLM commonly
/// emits. The parser previously broke on "tomorrow morning at 2pm" — exact
/// string compare for "today"/"tomorrow" returned nil whenever the user
/// (or the LLM) included a filler qualifier like "morning"/"afternoon".
/// These tests pin the post-fix shape so it doesn't regress.
struct DateTimeParserTests {
  // MARK: - Helpers

  /// Day-offset between two dates, computed in calendar days. Lets us
  /// assert "tomorrow" without hardcoding the test wall clock.
  private func dayOffset(from a: Date, to b: Date) -> Int {
    let cal = Calendar.current
    let aDay = cal.startOfDay(for: a)
    let bDay = cal.startOfDay(for: b)
    return cal.dateComponents([.day], from: aDay, to: bDay).day ?? 0
  }

  private func components(of date: Date) -> (hour: Int, minute: Int) {
    let c = Calendar.current.dateComponents([.hour, .minute], from: date)
    return (c.hour ?? 0, c.minute ?? 0)
  }

  // MARK: - The bug from Joe's report

  @Test
  func tomorrowMorningAt2pm_resolvesToTomorrowAt14h() throws {
    // The exact phrasing that produced today-at-9am before the fix.
    let result = try #require(parseDateAndTime("tomorrow morning at 2pm"))
    #expect(dayOffset(from: Date(), to: result) == 1)
    let (hour, minute) = components(of: result)
    #expect(hour == 14)
    #expect(minute == 0)
  }

  @Test
  func tomorrowAfternoonAt3pm_resolvesToTomorrowAt15h() throws {
    let result = try #require(parseDateAndTime("tomorrow afternoon at 3pm"))
    #expect(dayOffset(from: Date(), to: result) == 1)
    #expect(components(of: result).hour == 15)
  }

  @Test
  func tomorrowEveningAt7pm_resolvesToTomorrowAt19h() throws {
    let result = try #require(parseDateAndTime("tomorrow evening at 7pm"))
    #expect(dayOffset(from: Date(), to: result) == 1)
    #expect(components(of: result).hour == 19)
  }

  // MARK: - Today markers

  @Test
  func today_resolvesToToday() throws {
    let result = try #require(parseDateAndTime("today"))
    #expect(dayOffset(from: Date(), to: result) == 0)
  }

  @Test
  func tonightAt9pm_resolvesToTodayAt21h() throws {
    let result = try #require(parseDateAndTime("tonight at 9pm"))
    #expect(dayOffset(from: Date(), to: result) == 0)
    #expect(components(of: result).hour == 21)
  }

  @Test
  func thisEveningAt7pm_resolvesToTodayAt19h() throws {
    let result = try #require(parseDateAndTime("this evening at 7pm"))
    #expect(dayOffset(from: Date(), to: result) == 0)
    #expect(components(of: result).hour == 19)
  }

  @Test
  func thisMorningAt10am_resolvesToTodayAt10h() throws {
    let result = try #require(parseDateAndTime("this morning at 10am"))
    #expect(dayOffset(from: Date(), to: result) == 0)
    #expect(components(of: result).hour == 10)
  }

  // MARK: - Tomorrow markers

  @Test
  func tomorrow_resolvesToTomorrowAt9am() throws {
    // No explicit time → default to 9 AM.
    let result = try #require(parseDateAndTime("tomorrow"))
    #expect(dayOffset(from: Date(), to: result) == 1)
    #expect(components(of: result).hour == 9)
  }

  @Test
  func tomorrowAt1030am_resolvesToTomorrowAt1030() throws {
    let result = try #require(parseDateAndTime("tomorrow at 10:30am"))
    #expect(dayOffset(from: Date(), to: result) == 1)
    let (hour, minute) = components(of: result)
    #expect(hour == 10)
    #expect(minute == 30)
  }

  // MARK: - Time-only edge cases

  @Test
  func twelvePm_isNoon_notMidnight() throws {
    let result = try #require(parseDateAndTime("today at 12pm"))
    #expect(components(of: result).hour == 12)
  }

  @Test
  func twelveAm_isMidnight_hour0() throws {
    let result = try #require(parseDateAndTime("today at 12am"))
    #expect(components(of: result).hour == 0)
  }

  // MARK: - Weekday markers (these already worked but pin them)

  @Test
  func fridayAt2pm_resolvesToNextFridayAt14h() throws {
    let result = try #require(parseDateAndTime("Friday at 2pm"))
    let weekday = Calendar.current.component(.weekday, from: result)
    #expect(weekday == 6) // Friday in Calendar.current's English-style ordering
    #expect(components(of: result).hour == 14)
  }

  @Test
  func fridayMorningAt9am_resolvesToNextFridayAt9h() throws {
    let result = try #require(parseDateAndTime("Friday morning at 9am"))
    let weekday = Calendar.current.component(.weekday, from: result)
    #expect(weekday == 6)
    #expect(components(of: result).hour == 9)
  }

  // MARK: - Garbage / nil

  @Test
  func unparseableString_returnsNil() {
    #expect(parseDateAndTime("flarble blorp") == nil)
  }
}
