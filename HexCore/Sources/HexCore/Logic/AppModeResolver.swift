import Foundation

/// Resolves the AI processing mode based on the active application.
///
/// Resolution order (first match wins):
///   1. User-defined custom rules — always honored, even when the
///      "Auto-select mode by app" toggle is off. Adding a rule is an
///      explicit opt-in for that specific app, so requiring a second
///      toggle to make it work would be a UX trap.
///   2. Built-in heuristics (Mail → email, Slack → message, …) —
///      gated by `contextAwareEnabled` so users who don't want any
///      automatic behavior can leave the toggle off.
public enum AppModeResolver {
  public static func resolve(
    bundleID: String?,
    customRules: [AppModeRule],
    contextAwareEnabled: Bool
  ) -> AIProcessingMode? {
    guard let bundleID else { return nil }

    // Custom rules take priority and are always honored.
    if let rule = customRules.first(where: { !$0.bundleIdentifier.isEmpty && $0.bundleIdentifier == bundleID }) {
      return rule.mode
    }

    // Built-in heuristics are gated by the explicit toggle.
    guard contextAwareEnabled else { return nil }
    return defaultMode(for: bundleID)
  }

  private static func defaultMode(for bundleID: String) -> AIProcessingMode? {
    // Email clients
    if emailBundleIDs.contains(bundleID) { return .email }

    // Messaging apps
    if messagingBundleIDs.contains(bundleID) { return .message }

    // Code editors
    if codeBundleIDs.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.") { return .code }

    // Note-taking apps
    if noteBundleIDs.contains(bundleID) { return .notes }

    return nil
  }

  private static let emailBundleIDs: Set<String> = [
    "com.apple.mail",
    "com.microsoft.Outlook",
    "com.google.Gmail",
    "com.readdle.smartemail",
    "com.freron.MailMate",
    "com.superhuman.mail",
  ]

  private static let messagingBundleIDs: Set<String> = [
    "com.tinyspeck.slackmacgap",
    "com.apple.MobileSMS",
    "com.hnc.Discord",
    "net.whatsapp.WhatsApp",
    "com.facebook.archon",
    "org.telegram.desktop",
    "us.zoom.xos",
    "com.microsoft.teams2",
  ]

  private static let codeBundleIDs: Set<String> = [
    "com.microsoft.VSCode",
    "com.todesktop.230313mzl4w4u92",  // Cursor
    "dev.zed.Zed",
    "com.sublimetext.4",
    "com.apple.dt.Xcode",
  ]

  private static let noteBundleIDs: Set<String> = [
    "com.apple.Notes",
    "md.obsidian",
    "notion.id",
    "com.evernote.Evernote",
    "com.logseq.logseq",
    "net.bear-writer.bear",
  ]
}
