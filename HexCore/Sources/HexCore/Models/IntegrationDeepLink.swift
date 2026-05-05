import Foundation

/// Per-integration deep links for the completion badge tap-through.
/// Returns `nil` when no URL scheme exists or when the platform's app
/// support is unknown — callers should treat the missing URL as
/// "render a non-tappable pill" rather than as an error.
///
/// Per-item links are intentionally *not* exposed here yet:
///   - Apple Reminders: `EKReminder` doesn't expose a URL builder.
///   - Apple Calendar: `EKEvent.eventIdentifier` can be passed to
///     `x-apple-calevent://`, but the format isn't stable across iOS
///     versions and ours is a v1.
///   - Todoist: `https://todoist.com/showTask?id=<id>` works on web
///     but the iOS app deep link is undocumented.
///   - Google Calendar / Gmail: official URL schemes target the app
///     root only — per-item URLs require a session-bearing https://
///     redirect we don't want to mint client-side.
///
/// The app-root deep link is still useful: the most-recently-created
/// item is at the top of the integration's inbox / today view, so
/// "Added to Reminders" → Reminders app opens to the new item. v2
/// can layer per-item URLs in for the integrations where they're
/// stable.
public enum IntegrationDeepLink {
  /// URL that opens the integration's iOS / macOS app at its root.
  public static func appRoot(for id: Integration.Identifier) -> URL? {
    let raw: String? = switch id {
    case .appleReminders: "x-apple-reminderkit://"
    case .calendar: "calshow:"
    case .todoist: "todoist://"
    case .gmail: "googlegmail://"
    case .googleCalendar: "googlecalendar://"
    case .notion: "notion://"
    case .things: "things:///show?query="
    case .slack: "slack://"
    case .linear: "linear://"
    }
    return raw.flatMap { URL(string: $0) }
  }
}
