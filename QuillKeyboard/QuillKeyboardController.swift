//
//  QuillKeyboardController.swift
//  QuillKeyboard
//
//  Custom keyboard input view controller. Hosts a SwiftUI keyboard view
//  that delegates dictation to the parent Quill app via the App Group
//  bridge (see `KeyboardBridge` and `KeyboardRecordingViewModel`).
//
//  iOS denies microphone access to non-focal extension processes, so we
//  never record audio in-process. The keyboard is the trigger + the
//  text-insertion surface; the parent app is the recorder.
//

import SwiftUI
import UIKit

final class QuillKeyboardController: UIInputViewController {
  private var hostController: UIHostingController<KeyboardRootView>?
  private let viewModel = KeyboardRecordingViewModel()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear

    viewModel.bind(
      proxy: textDocumentProxy,
      advanceToNextKeyboard: { [weak self] in self?.advanceToNextInputMode() },
      dismissKeyboard: { [weak self] in self?.dismissKeyboard() },
      openURL: { [weak self] url in self?.openContainingApp(url) }
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

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // The user just came back from the parent Quill app — pick up any
    // recorded transcript that was waiting in the App Group mailbox.
    Task { @MainActor in viewModel.checkForBridgeResult() }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    // Don't auto-cancel the outstanding bridge request on dismiss — the
    // user may dismiss the keyboard while the parent app is still
    // recording, and that's fine. The result will land on the next
    // appearance.
  }

  override func textDidChange(_ textInput: UITextInput?) {
    super.textDidChange(textInput)
    viewModel.refreshHostContext()
    // Also poll for a pending bridge result here — `viewWillAppear` is
    // not guaranteed to fire when the user switches back to a host app
    // that already has the keyboard up.
    Task { @MainActor in viewModel.checkForBridgeResult() }
  }

  /// Opens a `quill://` URL in the parent app. Extensions can't call
  /// `UIApplication.shared.open` directly; the documented escape hatch
  /// is `extensionContext?.open(_:completionHandler:)`.
  ///
  /// `extensionContext.open` is only available to a subset of extension
  /// types. Keyboard extensions historically did NOT have it, but the
  /// modern documented workaround for keyboards is to walk the responder
  /// chain looking for `UIApplication`.
  private func openContainingApp(_ url: URL) {
    var responder: UIResponder? = self
    while let r = responder {
      if let app = r as? UIApplication {
        app.open(url, options: [:], completionHandler: nil)
        return
      }
      responder = r.next
    }
    // Fallback — best effort. On modern iOS this path is rarely hit.
    extensionContext?.open(url)
  }
}
