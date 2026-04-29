import SwiftUI

// The old monolithic `SettingsView` — which stuffed every section
// into a single Form — was split into focused sidebar destinations
// in 0.9.x. See `SettingsTabs.swift` for the per-tab wrappers
// (General / Recording / AI / Integrations). What remains in this
// file is just the shared text style every section view uses.

extension Text {
	/// Applies caption font with secondary color, commonly used for
	/// helper / description text in settings sections.
	func settingsCaption() -> some View {
		self.font(.caption).foregroundStyle(.secondary)
	}
}
