//
//  PhotoAnalysis.swift
//  Quill (iOS)
//
//  Sidecar data persisted next to each photo JPEG describing what the
//  AI saw. Stored as `<photo-id>.json` in the photo's note directory
//  (see `PhotoStore.analysisURL(noteID:photoID:)`). Intentionally flat
//  and small — if we ever want richer structure (speaker metadata, per-
//  bullet citations, etc.) we can evolve this struct; JSON-on-disk is
//  forgiving of added optional fields.
//

import Foundation

struct PhotoAnalysis: Codable, Equatable, Hashable {
  /// One-sentence description of the image.
  var summary: String
  /// 3–6 bullet points extracted from the image (slide bullets,
  /// whiteboard items, menu highlights, etc).
  var keyDetails: [String]
  /// Verbatim readable text from the image, or nil if there is none.
  var transcribedText: String?
  var analyzedAt: Date
  /// The model identifier that produced this analysis, so future runs
  /// can decide whether to re-analyze on upgrade.
  var model: String
}
