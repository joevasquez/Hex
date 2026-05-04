//
//  IOSSystemActionQueueExecutor.swift
//  Quill (iOS)
//
//  iOS-side ActionQueueExecutor — routes a queued ActionIntent to the
//  right `@MainActor enum` adapter. Installed once at app launch by
//  `QuilliOSApp.init`.
//
//  iOS Action mode supports Reminders, Apple Calendar, Todoist, Gmail,
//  and Google Calendar. Each routes to a `@MainActor enum` adapter that
//  shares the same access-token plumbing (IOSGoogleOAuthClient for
//  Gmail/GCal; KeychainStore for Todoist; EventKit for Apple).
//

import Foundation
import HexCore

@MainActor
public final class IOSSystemActionQueueExecutor: ActionQueueExecutor {
  public init() {}

  public func execute(_ intent: ActionIntent) async throws {
    switch intent.targetIntegration {
    case .appleReminders:
      _ = try await IOSRemindersAdapter.createReminder(intent)
    case .calendar:
      _ = try await IOSCalendarAdapter.createEvent(intent)
    case .todoist:
      _ = try await IOSTodoistAdapter.createTask(intent)
    case .gmail:
      _ = try await IOSGmailAdapter.createDraft(intent)
    case .googleCalendar:
      _ = try await IOSGoogleCalendarAdapter.createEvent(intent)
    default:
      throw IOSActionError.invalidResponse(intent.targetIntegration.rawValue)
    }
  }
}
