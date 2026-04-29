//
//  KeychainClient.swift
//  Quill
//
//  Stores and retrieves API keys from the system Keychain (macOS + iOS).
//

import Dependencies
import DependenciesMacros
import Foundation
import Security

@DependencyClient
struct KeychainClient {
  var save: @Sendable (String, String) async throws -> Void
  var read: @Sendable (String) async -> String?
  var delete: @Sendable (String) async -> Void
}

extension KeychainClient: DependencyKey {
  static var liveValue: Self {
    let live = KeychainClientLive()
    return .init(
      save: { key, value in
        try live.save(key: key, value: value)
      },
      read: { key in
        live.read(key: key)
      },
      delete: { key in
        live.delete(key: key)
      }
    )
  }
}

extension DependencyValues {
  var keychain: KeychainClient {
    get { self[KeychainClient.self] }
    set { self[KeychainClient.self] = newValue }
  }
}

// MARK: - Keychain Keys

enum KeychainKey {
  static let openAIAPIKey = "com.joevasquez.Quill.openAIAPIKey"
  static let anthropicAPIKey = "com.joevasquez.Quill.anthropicAPIKey"
}

// MARK: - Live Implementation

private struct KeychainClientLive {
  private let service = "com.joevasquez.Quill"

  /// Lookup attributes (class + service + account) used for read, delete,
  /// and as the base for save. `kSecAttrAccessible` is *deliberately* NOT
  /// included here: on iOS, passing it to `SecItemCopyMatching` can cause
  /// the query to miss items that were saved with the same attribute
  /// (the system doesn't always treat it as an equality filter). Keep
  /// accessible as a save-only attribute.
  ///
  /// Uses the standard `[String: Any] as CFDictionary` bridge — the Swift
  /// runtime wraps values in a toll-free bridge that correctly retains
  /// them for the lifetime of the dictionary. (An earlier version of this
  /// file used `CFDictionaryCreateMutable` with `nil` retain callbacks to
  /// "avoid bridging edge cases"; that was the wrong call — `nil`
  /// callbacks mean the dictionary does NOT retain its values, so the
  /// `CFData` for `kSecValueData` was being deallocated before
  /// `SecItemAdd` read it, which crashed inside `CFGetTypeID`.)
  private func lookupQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  func save(key: String, value: String) throws {
    guard !key.isEmpty else { return }
    guard let data = value.data(using: .utf8) else { return }

    // Delete any existing item first so SecItemAdd doesn't collide.
    delete(key: key)

    var query = lookupQuery(account: key)
    query[kSecValueData as String] = data
    // Required on iOS (sets the item's protection class); a safe hint on
    // macOS. "WhenUnlockedThisDeviceOnly" = readable only while the device
    // is unlocked, and never synced to iCloud or included in backups —
    // appropriate for API keys.
    query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw KeychainError.saveFailed(status)
    }
  }

  func read(key: String) -> String? {
    guard !key.isEmpty else { return nil }

    var query = lookupQuery(account: key)
    query[kSecReturnData as String] = kCFBooleanTrue
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    guard status == errSecSuccess,
          let data = result as? Data,
          let string = String(data: data, encoding: .utf8)
    else {
      return nil
    }
    return string
  }

  func delete(key: String) {
    guard !key.isEmpty else { return }
    SecItemDelete(lookupQuery(account: key) as CFDictionary)
  }
}

private enum KeychainError: LocalizedError {
  case saveFailed(OSStatus)

  var errorDescription: String? {
    switch self {
    case .saveFailed(let status):
      "Failed to save to Keychain (status: \(status))"
    }
  }
}
