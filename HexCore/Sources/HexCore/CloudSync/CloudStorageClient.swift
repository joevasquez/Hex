import Foundation
import os

private let storageLogger = Logger(subsystem: "com.joevasquez.Quill", category: "cloudSync")

/// Thin wrapper around the JSON Cloud Storage REST API. Pairs with
/// `FirestoreClient` so the whole sync surface is REST + OAuth (no
/// Firebase SDK). All methods take an OAuth access token granted with
/// `https://www.googleapis.com/auth/devstorage.read_write`.
public actor CloudStorageClient {
  private let bucket: String

  /// CharacterSet for percent-encoding GCS object names that go in the
  /// URL *path* (e.g. `/o/{name}`). Slashes MUST be encoded as `%2F` —
  /// `.urlPathAllowed` includes `/` so we strip it explicitly. Without
  /// this, `users/foo/photos/bar.jpg` is sent as raw slashes and GCS
  /// interprets the segments as nested API paths, returning 404.
  private static let objectNameAllowed: CharacterSet = {
    var set = CharacterSet.urlPathAllowed
    set.remove(charactersIn: "/")
    return set
  }()

  public init(bucket: String = CloudSyncConstants.gcsBucket) {
    self.bucket = bucket
  }

  // MARK: - Upload

  /// Upload `data` at `objectPath` (e.g. "users/foo/photos/abc.jpg").
  /// Uses the simple media upload endpoint — fine for files up to ~5 MB
  /// (which is what photos already cap at after `PhotoStore` downscale).
  public func uploadObject(
    objectPath: String,
    data: Data,
    contentType: String,
    accessToken: String
  ) async throws {
    var components = URLComponents(string: "https://storage.googleapis.com/upload/storage/v1/b/\(bucket)/o")!
    components.queryItems = [
      URLQueryItem(name: "uploadType", value: "media"),
      URLQueryItem(name: "name", value: objectPath),
    ]
    guard let url = components.url else {
      throw CloudSyncError.uploadFailed(0)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
    request.httpBody = data
    request.timeoutInterval = 60

    let (_, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      storageLogger.error("GCS upload failed: HTTP \(code, privacy: .public) path=\(objectPath, privacy: .public)")
      throw CloudSyncError.uploadFailed(code)
    }
  }

  // MARK: - Download

  /// Fetch the raw bytes at `objectPath`. Returns nil for 404 (object
  /// doesn't exist) so callers can no-op gracefully.
  public func downloadObject(
    objectPath: String,
    accessToken: String
  ) async throws -> Data? {
    let encodedPath = objectPath.addingPercentEncoding(withAllowedCharacters: Self.objectNameAllowed) ?? objectPath
    let url = URL(string: "https://storage.googleapis.com/storage/v1/b/\(bucket)/o/\(encodedPath)?alt=media")!

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 60

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw CloudSyncError.fetchFailed(0)
    }
    if http.statusCode == 404 {
      return nil
    }
    guard (200...299).contains(http.statusCode) else {
      storageLogger.error("GCS download failed: HTTP \(http.statusCode, privacy: .public) path=\(objectPath, privacy: .public)")
      throw CloudSyncError.fetchFailed(http.statusCode)
    }
    return data
  }

  // MARK: - Delete

  public func deleteObject(
    objectPath: String,
    accessToken: String
  ) async throws {
    let encodedPath = objectPath.addingPercentEncoding(withAllowedCharacters: Self.objectNameAllowed) ?? objectPath
    let url = URL(string: "https://storage.googleapis.com/storage/v1/b/\(bucket)/o/\(encodedPath)")!

    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 30

    let (_, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 204 || http.statusCode == 404 || (200...299).contains(http.statusCode) else {
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      throw CloudSyncError.deleteFailed(code)
    }
  }
}

// MARK: - Path helpers

public enum CloudPhotoPath {
  /// Stable GCS object path for a given user/note/photo.
  /// Mirrors the iOS local layout (`photos/<note-id>/<photo-id>.jpg`)
  /// scoped under the user.
  public static func jpeg(userEmail: String, noteId: UUID, photoId: UUID) -> String {
    "users/\(sanitize(userEmail))/photos/\(noteId.uuidString)/\(photoId.uuidString).jpg"
  }

  public static func analysisJSON(userEmail: String, noteId: UUID, photoId: UUID) -> String {
    "users/\(sanitize(userEmail))/photos/\(noteId.uuidString)/\(photoId.uuidString).json"
  }

  /// Same sanitizer used for Firestore paths so a user's photos and
  /// notes/manifests share the same logical user folder.
  public static func sanitize(_ email: String) -> String {
    email.replacingOccurrences(of: ".", with: "_")
         .replacingOccurrences(of: "@", with: "_at_")
  }
}
