import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

/// Controls how a finished transcript reaches the user — clipboard
/// insertion vs. simulated keypresses, and whether to leave a copy on
/// the clipboard. Lives under the Recording tab next to the recording
/// behavior knobs; previously these were buried in the General catch-all.
struct RecordingOutputSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		Section {
			Label {
				Toggle(
					"Use clipboard to insert",
					isOn: Binding(
						get: { store.hexSettings.useClipboardPaste },
						set: { store.send(.setUseClipboardPaste($0)) }
					)
				)
				Text("Use clipboard to insert text. Fast but may not restore all clipboard content.\nTurn off to use simulated keypresses. Slower, but doesn't need to restore clipboard")
			} icon: {
				Image(systemName: "doc.on.doc.fill")
			}

			Label {
				Toggle(
					"Copy to clipboard",
					isOn: Binding(
						get: { store.hexSettings.copyToClipboard },
						set: { store.send(.setCopyToClipboard($0)) }
					)
				)
				Text("Copy transcription text to clipboard in addition to pasting it")
			} icon: {
				Image(systemName: "doc.on.clipboard")
			}
		} header: {
			Text("Output")
		}
		.enableInjection()
	}
}
