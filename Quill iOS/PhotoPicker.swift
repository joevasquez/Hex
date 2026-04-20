//
//  PhotoPicker.swift
//  Quill (iOS)
//
//  Thin SwiftUI wrappers around PHPickerViewController (library) and
//  UIImagePickerController (camera). Both deliver a single UIImage back
//  through a closure and dismiss themselves on selection or cancel.
//

import PhotosUI
import SwiftUI
import UIKit

struct PhotoLibraryPicker: UIViewControllerRepresentable {
  let onPick: (UIImage?) -> Void

  func makeUIViewController(context: Context) -> PHPickerViewController {
    var config = PHPickerConfiguration()
    config.selectionLimit = 1
    config.filter = .images
    let vc = PHPickerViewController(configuration: config)
    vc.delegate = context.coordinator
    return vc
  }

  func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

  final class Coordinator: NSObject, PHPickerViewControllerDelegate {
    let onPick: (UIImage?) -> Void
    init(onPick: @escaping (UIImage?) -> Void) { self.onPick = onPick }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
      guard let provider = results.first?.itemProvider,
            provider.canLoadObject(ofClass: UIImage.self) else {
        picker.dismiss(animated: true) { self.onPick(nil) }
        return
      }
      provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
        let image = object as? UIImage
        DispatchQueue.main.async {
          picker.dismiss(animated: true) { self?.onPick(image) }
        }
      }
    }
  }
}

struct CameraPicker: UIViewControllerRepresentable {
  let onPick: (UIImage?) -> Void

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let vc = UIImagePickerController()
    vc.sourceType = .camera
    vc.allowsEditing = false
    vc.delegate = context.coordinator
    return vc
  }

  func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

  final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    let onPick: (UIImage?) -> Void
    init(onPick: @escaping (UIImage?) -> Void) { self.onPick = onPick }

    func imagePickerController(
      _ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      let image = info[.originalImage] as? UIImage
      picker.dismiss(animated: true) { self.onPick(image) }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      picker.dismiss(animated: true) { self.onPick(nil) }
    }
  }
}
