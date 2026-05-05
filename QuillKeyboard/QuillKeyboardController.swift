//
//  QuillKeyboardController.swift
//  QuillKeyboard
//
//  Custom keyboard input view controller. Hosts a SwiftUI keyboard view
//  that records audio, transcribes via SFSpeechRecognizer, optionally
//  cleans up via the user's AI provider, then inserts the result into
//  the host app's text field via `textDocumentProxy`.
//
//  v1 scope:
//   - One big purple Dictate button. Hold-to-talk + tap-to-toggle both work.
//   - Live partial transcript shown while speaking.
//   - On stop: insert the transcript at the cursor in the host app.
//   - "Enhance" toggle: when on, runs the transcript through the user's
//     configured AI provider with a context-aware prompt that includes
//     the surrounding text from the host field (via
//     `textDocumentProxy.documentContextBeforeInput/AfterInput`).
//   - Standard keyboard utilities: backspace, return, space, "next
//     keyboard" globe, dismiss.
//
//  Memory: keyboard extensions are capped at ~48 MB on iPhone, so we
//  deliberately do NOT bundle WhisperKit here. SFSpeech's on-device
//  model is small and ships with iOS, which keeps us well under budget.
//

import SwiftUI
import UIKit

final class QuillKeyboardController: UIInputViewController {
  private var hostController: UIHostingController<KeyboardRootView>?
  private let viewModel = KeyboardRecordingViewModel()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear

    // The keyboard view is SwiftUI. Wire the proxy + a "switch keyboard"
    // hook into the view-model so the SwiftUI side stays UIKit-free.
    viewModel.bind(
      proxy: textDocumentProxy,
      advanceToNextKeyboard: { [weak self] in self?.advanceToNextInputMode() },
      dismissKeyboard: { [weak self] in self?.dismissKeyboard() }
    )

    let root = KeyboardRootView(viewModel: viewModel)
    let host = UIHostingController(rootView: root)
    host.view.translatesAutoresizingMaskIntoConstraints = false
    host.view.backgroundColor = .clear
    addChild(host)
    view.addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      host.view.topAnchor.constraint(equalTo: view.topAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    host.didMove(toParent: self)
    hostController = host
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    // Stop any in-flight recording so we don't leak the audio session
    // when the user dismisses the keyboard mid-dictation.
    viewModel.cancelIfNeeded()
  }

  override func textDidChange(_ textInput: UITextInput?) {
    super.textDidChange(textInput)
    // Refresh the cached "context before / after" snapshot so the
    // Enhance prompt always has the freshest surrounding text. This
    // fires after every text mutation in the host app.
    viewModel.refreshHostContext()
  }
}
