//
//  QuillRecordingState.swift
//  Quill (iOS)
//
//  Recording UI split into two pieces:
//  - `transcriptCard` lives in the scroll area (where the note canvas
//    normally sits) so longer transcripts can scroll naturally.
//  - `WaveformBottomBar` is rendered as a fixed safe-area inset above
//    the FAB cluster — meets the user's expectation that the waveform
//    is always visible at the bottom of the screen, never covered by
//    the transcript content.
//
//  The bars are driven by `Timer.publish` rather than `TimelineView`'s
//  `onChange(of: context.date)`. The latter wasn't reliably firing
//  because TimelineView's date isn't an SwiftUI-tracked value — onChange
//  saw it as "unchanged" and skipped the sample. The Timer pattern is
//  the canonical SwiftUI sampling pattern and works deterministically.
//

import Combine
import SwiftUI

/// The big "Live transcript" card that lives in the scrollable canvas
/// area. The waveform is rendered separately by `WaveformBottomBar`
/// so it stays pinned to the bottom of the screen.
struct QuillRecordingTranscriptCard: View {
  let transcript: String

  /// Max height of the scrollable transcript region. Picked to leave
  /// room above for the header / mode pill and below for the waveform
  /// + FAB cluster on a typical 6.1" iPhone — past this the body
  /// scrolls internally instead of pushing the card under the
  /// waveform inset.
  private let scrollMaxHeight: CGFloat = 280

  /// Anchor at the bottom of the text so we can auto-scroll-to-newest
  /// on every transcript change. Empty transparent rect, just there
  /// to give the ScrollViewReader something to target.
  private let bottomAnchor = "transcriptBottom"

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Live transcript", systemImage: "mic.fill")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.purple)

      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            Text(displayTranscript)
              .font(.body)
              .foregroundStyle(.primary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .multilineTextAlignment(.leading)
            // Sentinel to scroll to — keeps the latest line just
            // above the bottom edge as new words land.
            Color.clear.frame(height: 1).id(bottomAnchor)
          }
        }
        .frame(maxHeight: scrollMaxHeight)
        .onChange(of: transcript) { _, _ in
          // Defer the scroll so the new text has laid out before we
          // ask for the bottom — otherwise SwiftUI sometimes scrolls
          // to the prior bottom and falls one line behind.
          withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
          }
        }
        // Same auto-scroll on first appear so a long pre-existing
        // transcript opens at the latest text rather than the top.
        .onAppear {
          DispatchQueue.main.async {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
          }
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      // Solid white per the spec — keeps the transcript page-like
      // against the lavender app bg.
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Color.white)
    )
    .overlay(
      // 0.5px hairline at rgba(0,0,0,0.05) — almost invisible, just
      // enough edge so the white card doesn't melt into a near-white
      // app bg.
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(Color.black.opacity(0.05), lineWidth: 0.5)
    )
    // No external bottom padding — the outer ScrollView's recording-
    // mode bottom spacer + the waveform card's own internal vertical
    // padding already produce the right amount of breath.
  }

  private var displayTranscript: String {
    transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "Listening…"
      : transcript
  }
}

/// Pinned-to-bottom waveform card. 32 vertical purple bars driven by
/// the recorder's `meterLevel`, rolling oldest → newest left to right.
///
/// Sampling: previously used `Timer.publish + onReceive`, which
/// captured `meterLevel` once at view-appear time and never saw
/// updates. Now we observe `vm.meterLevel` via `.onChange` — every
/// publish from `RecordingViewModel` (which itself updates ~10Hz from
/// `recorder.averagePower`) immediately advances the rolling buffer.
/// No timer, no stale captures.
struct WaveformBottomBar: View {
  /// Observed directly so changes to `meterLevel` are SwiftUI-tracked.
  /// We don't pass `meterLevel: Float` as a prop because the surrounding
  /// closures would capture stale values and the bars would freeze.
  @ObservedObject var vm: RecordingViewModel

  /// Rolling 32-sample history. Floor of 0.04 keeps a baseline shape
  /// on first paint instead of all bars collapsing to zero.
  @State private var history: [Float] = Array(repeating: 0.04, count: 32)

  var body: some View {
    HStack(alignment: .center, spacing: 4) {
      ForEach(Array(history.enumerated()), id: \.offset) { _, sample in
        Capsule()
          .fill(Color(red: 0.486, green: 0.227, blue: 0.929))  // #7c3aed
          .frame(maxWidth: .infinity)
          .frame(height: barHeight(for: sample))
      }
    }
    .frame(height: 56, alignment: .center)
    .padding(.horizontal, 22)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity)
    .background(
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(
          LinearGradient(
            colors: [
              Color(red: 0.953, green: 0.910, blue: 1.000),  // #f3e8ff
              Color(red: 0.929, green: 0.882, blue: 0.976),  // #ede1f9
            ],
            startPoint: .top,
            endPoint: .bottom
          )
        )
    )
    .overlay(
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .stroke(
          Color(red: 0.486, green: 0.227, blue: 0.929).opacity(0.18),  // rgba(124,58,237,0.18)
          lineWidth: 0.5
        )
    )
    .padding(.horizontal, 16)
    .animation(.easeOut(duration: 1.0 / 12.0), value: history)
    .onChange(of: vm.meterLevel) { _, newLevel in
      var next = history
      next.removeFirst()
      next.append(max(0.04, min(1, newLevel)))
      history = next
    }
  }

  /// Maps a 0...1 sample to a 6...56pt bar height. Square-rooting
  /// compresses the dynamic range so quiet voice still produces
  /// visible motion without loud spikes pinning the top.
  private func barHeight(for sample: Float) -> CGFloat {
    let scaled = CGFloat(sqrt(max(0, sample)))
    return 6 + (56 - 6) * scaled
  }
}
