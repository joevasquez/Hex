//
//  PhotoStore.swift
//  Quill (iOS)
//
//  Sidecar photo storage for inline note images. Photos live under
//  Application Support at `photos/<note-id>/<photo-id>.jpg` so they
//  travel with the app container and are trivially deletable when the
//  owning note is removed. The body string references each photo by
//  UUID via a `![photo](<uuid>)` token; see `NoteContent.swift`.
//

import Foundation
import UIKit

@MainActor
final class PhotoStore {
  static let shared = PhotoStore()

  private let rootURL: URL

  private init() {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    self.rootURL = support.appendingPathComponent("photos", isDirectory: true)
    try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  /// Persist `image` under `noteID`'s directory and return the new photo's UUID.
  /// Images are downscaled to a max 1568px long edge (Anthropic's recommended
  /// vision size) at JPEG quality 0.75 — keeps notes small and stays under
  /// the 5 MB vision-API cap without a separate re-encode before upload.
  func savePhoto(_ image: UIImage, for noteID: UUID) throws -> UUID {
    let photoID = UUID()
    let dir = rootURL.appendingPathComponent(noteID.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("\(photoID.uuidString).jpg")

    let resized = downscaled(image, maxEdge: 1568)
    guard let data = resized.jpegData(compressionQuality: 0.75) else {
      throw NSError(
        domain: "PhotoStore", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Could not encode JPEG"]
      )
    }
    try data.write(to: url, options: [.atomic])
    return photoID
  }

  func url(noteID: UUID, photoID: UUID) -> URL {
    rootURL
      .appendingPathComponent(noteID.uuidString, isDirectory: true)
      .appendingPathComponent("\(photoID.uuidString).jpg")
  }

  /// Sidecar JSON next to the photo's JPEG, holding AI analysis output.
  func analysisURL(noteID: UUID, photoID: UUID) -> URL {
    rootURL
      .appendingPathComponent(noteID.uuidString, isDirectory: true)
      .appendingPathComponent("\(photoID.uuidString).json")
  }

  func loadImage(noteID: UUID, photoID: UUID) -> UIImage? {
    UIImage(contentsOfFile: url(noteID: noteID, photoID: photoID).path)
  }

  /// Raw JPEG bytes for a photo — used when uploading to a vision API
  /// so we don't pay the decode-then-reencode round trip.
  func imageData(noteID: UUID, photoID: UUID) -> Data? {
    try? Data(contentsOf: url(noteID: noteID, photoID: photoID))
  }

  func saveAnalysis(_ analysis: PhotoAnalysis, noteID: UUID, photoID: UUID) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(analysis)
    try data.write(to: analysisURL(noteID: noteID, photoID: photoID), options: [.atomic])
  }

  func loadAnalysis(noteID: UUID, photoID: UUID) -> PhotoAnalysis? {
    guard let data = try? Data(contentsOf: analysisURL(noteID: noteID, photoID: photoID)) else {
      return nil
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(PhotoAnalysis.self, from: data)
  }

  /// Called when a note is deleted; wipes the whole sidecar directory.
  func deleteAllPhotos(noteID: UUID) {
    let dir = rootURL.appendingPathComponent(noteID.uuidString, isDirectory: true)
    try? FileManager.default.removeItem(at: dir)
  }

  private func downscaled(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
    let size = image.size
    let longest = max(size.width, size.height)
    guard longest > maxEdge else { return image }
    let scale = maxEdge / longest
    let newSize = CGSize(width: size.width * scale, height: size.height * scale)
    // Force scale=1 — the default uses the main screen's scale factor
    // (typically 3x on iPhone) which would re-inflate the rendered image
    // to 3x the target pixel count, defeating the downscale entirely.
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
    return renderer.image { _ in
      image.draw(in: CGRect(origin: .zero, size: newSize))
    }
  }
}
