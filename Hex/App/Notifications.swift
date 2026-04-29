import Foundation
import HexCore

extension NSNotification.Name {
  /// Posted when app mode settings change (dock icon visibility, etc.)
  static let updateAppMode = NSNotification.Name("UpdateAppMode")
  /// Posted when an action intent is parsed and ready for user confirmation.
  static let presentActionConfirmation = NSNotification.Name("PresentActionConfirmation")
  /// Posted when an action is successfully executed.
  static let actionConfirmationExecuted = NSNotification.Name("ActionConfirmationExecuted")
  /// Posted when an action confirmation is cancelled.
  static let actionConfirmationCancelled = NSNotification.Name("ActionConfirmationCancelled")
}

enum ActionConfirmationNotification {
  static let intentKey = "actionIntent"

  static func post(intent: ActionIntent) {
    NotificationCenter.default.post(
      name: .presentActionConfirmation,
      object: nil,
      userInfo: [intentKey: intent]
    )
  }
}
