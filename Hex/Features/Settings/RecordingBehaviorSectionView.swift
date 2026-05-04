import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

/// Toggles that affect what happens to the system *during* a recording —
/// audio behavior (pause / mute / do-nothing), sleep prevention, and the
/// always-warm capture engine. Lives under the Recording tab so all of
/// the user's recording-time knobs sit together; previously these were
/// scattered into the General catch-all.
struct RecordingBehaviorSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		Section {
			Label {
				HStack(alignment: .center) {
					Text("Audio Behavior while Recording")
					Spacer()
					Picker("", selection: Binding(
						get: { store.hexSettings.recordingAudioBehavior },
						set: { store.send(.setRecordingAudioBehavior($0)) }
					)) {
						Label("Pause Media", systemImage: "pause")
							.tag(RecordingAudioBehavior.pauseMedia)
						Label("Mute Volume", systemImage: "speaker.slash")
							.tag(RecordingAudioBehavior.mute)
						Label("Do Nothing", systemImage: "hand.raised.slash")
							.tag(RecordingAudioBehavior.doNothing)
					}
					.pickerStyle(.menu)
				}
			} icon: {
				Image(systemName: "speaker.wave.2")
			}

			Label {
				Toggle(
					"Prevent System Sleep while Recording",
					isOn: Binding(
						get: { store.hexSettings.preventSystemSleep },
						set: { store.send(.togglePreventSystemSleep($0)) }
					)
				)
			} icon: {
				Image(systemName: "zzz")
			}

			Label {
				Toggle(
					"Super Fast Mode",
					isOn: Binding(
						get: { store.hexSettings.superFastModeEnabled },
						set: { store.send(.toggleSuperFastMode($0)) }
					)
				)
				Text("Keep the microphone warm and prepend a short in-memory buffer for near-instant capture. macOS will keep showing the microphone indicator while this mode is armed.")
			} icon: {
				Image(systemName: "bolt.circle")
			}
		} header: {
			Text("During Recording")
		}
		.enableInjection()
	}
}
