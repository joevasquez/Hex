import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct GeneralSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	/// Privacy-first default: opt-in. Stored under the same UserDefaults
	/// key the live `SentryErrorMonitoring` adapter reads, so toggling
	/// here directly gates capture (after the next `configure()` call).
	@AppStorage(ErrorMonitoringSettings.crashReportingEnabledKey)
	private var crashReportingEnabled: Bool = false

	var body: some View {
		Section {
			Label {
				Toggle("Open on Login",
				       isOn: Binding(
				       	get: { store.hexSettings.openOnLogin },
				       	set: { store.send(.toggleOpenOnLogin($0)) }
				       ))
			} icon: {
				Image(systemName: "arrow.right.circle")
			}

			Label {
				Toggle(
					"Show Dock Icon",
					isOn: Binding(
						get: { store.hexSettings.showDockIcon },
						set: { store.send(.toggleShowDockIcon($0)) }
					)
				)
			} icon: {
				Image(systemName: "dock.rectangle")
			}
		} header: {
			Text("App")
		}

		Section {
			Label {
				Toggle("Send anonymous crash reports", isOn: $crashReportingEnabled)
					.onChange(of: crashReportingEnabled) { _, _ in
						// Re-run configure() so SentrySDK starts/stops to
						// match the new flag without a relaunch.
						ErrorMonitoring.configure()
					}
			} icon: {
				Image(systemName: "ladybug")
			}
		} header: {
			Text("Privacy")
		} footer: {
			Text("Off by default. When on, Quill sends crash stack traces and OS version to Sentry — never your transcripts, audio, notes, or contacts. Helps Joe diagnose problems you can't easily reproduce.")
				.font(.caption)
				.foregroundStyle(.secondary)
		}
		.enableInjection()
	}
}
