import Foundation

/// Resolves the AI processing mode based on the active application.
///
/// Custom user rules are checked first. If no custom rule matches,
/// built-in defaults are used for common apps.
public enum AppModeResolver {
  public static func resolve(
    bundleID: String?,
    customRules: [AppModeRule],
    contextAwareEnabled: Bool
  ) -> AIProcessingMode? {
    guard contextAwareEnabled, let bundleID else { return nil }

    // Custom rules take priority
    if let rule = customRules.first(where: { $0.bundleIdentifier == bundleID }) {
      return rule.mode
    }

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
