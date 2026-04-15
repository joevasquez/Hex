import Testing
@testable import HexCore

struct AppModeResolverTests {
  @Test
  func returnsNilWhenDisabled() {
    let result = AppModeResolver.resolve(
      bundleID: "com.apple.mail",
      customRules: [],
      contextAwareEnabled: false
    )
    #expect(result == nil)
  }

  @Test
  func returnsNilForNilBundleID() {
    let result = AppModeResolver.resolve(
      bundleID: nil,
      customRules: [],
      contextAwareEnabled: true
    )
    #expect(result == nil)
  }

  @Test
  func resolvesEmailApps() {
    #expect(
      AppModeResolver.resolve(bundleID: "com.apple.mail", customRules: [], contextAwareEnabled: true) == .email
    )
    #expect(
      AppModeResolver.resolve(bundleID: "com.microsoft.Outlook", customRules: [], contextAwareEnabled: true) == .email
    )
  }

  @Test
  func resolvesMessagingApps() {
    #expect(
      AppModeResolver.resolve(bundleID: "com.tinyspeck.slackmacgap", customRules: [], contextAwareEnabled: true) == .message
    )
    #expect(
      AppModeResolver.resolve(bundleID: "com.hnc.Discord", customRules: [], contextAwareEnabled: true) == .message
    )
  }

  @Test
  func resolvesCodeEditors() {
    #expect(
      AppModeResolver.resolve(bundleID: "com.microsoft.VSCode", customRules: [], contextAwareEnabled: true) == .code
    )
    #expect(
      AppModeResolver.resolve(bundleID: "com.jetbrains.intellij", customRules: [], contextAwareEnabled: true) == .code
    )
  }

  @Test
  func resolvesNoteApps() {
    #expect(
      AppModeResolver.resolve(bundleID: "com.apple.Notes", customRules: [], contextAwareEnabled: true) == .notes
    )
    #expect(
      AppModeResolver.resolve(bundleID: "md.obsidian", customRules: [], contextAwareEnabled: true) == .notes
    )
  }

  @Test
  func returnsNilForUnknownApps() {
    #expect(
      AppModeResolver.resolve(bundleID: "com.unknown.app", customRules: [], contextAwareEnabled: true) == nil
    )
  }

  @Test
  func customRulesOverrideDefaults() {
    let customRule = AppModeRule(
      bundleIdentifier: "com.apple.mail",
      appName: "Mail",
      mode: .notes  // Override email → notes
    )
    let result = AppModeResolver.resolve(
      bundleID: "com.apple.mail",
      customRules: [customRule],
      contextAwareEnabled: true
    )
    #expect(result == .notes)
  }

  @Test
  func customRulesForUnknownApps() {
    let customRule = AppModeRule(
      bundleIdentifier: "com.mycompany.internal",
      appName: "InternalApp",
      mode: .code
    )
    let result = AppModeResolver.resolve(
      bundleID: "com.mycompany.internal",
      customRules: [customRule],
      contextAwareEnabled: true
    )
    #expect(result == .code)
  }
}
