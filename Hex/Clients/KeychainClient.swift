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

  /// Build a CFDictionary query using CFMutableDictionary to avoid any Swift bridging
  /// edge cases with `[String: Any]` → CFDictionary. This defensively ensures no
  /// values are nil before the query reaches Security.framework.
  private func makeQuery(
    account: String,
    extras: [(CFString, CFTypeRef)] = []
  ) -> CFDictionary? {
    guard !account.isEmpty else { return nil }

    let query = CFDictionaryCreateMutable(
      kCFAllocatorDefault,
      0,
      nil,  // keys unretained (CFString constants)
      nil   // values unretained
    )!

    // Required fields
    CFDictionarySetValue(query, Unmanaged.passUnretained(kSecClass).toOpaque(),
                         Unmanaged.passUnretained(kSecClassGenericPassword).toOpaque())
    CFDictionarySetValue(query, Unmanaged.passUnretained(kSecAttrService).toOpaque(),
                         Unmanaged.passUnretained(service as CFString).toOpaque())
    CFDictionarySetValue(query, Unmanaged.passUnretained(kSecAttrAccount).toOpaque(),
                         Unmanaged.passUnretained(account as CFString).toOpaque())

    // iOS requires kSecAttrAccessible; macOS uses it as a hint.
    // "WhenUnlockedThisDeviceOnly" means: only readable when the device is unlocked,
    // and never synced to iCloud or backed up — correct for API keys.
    CFDictionarySetValue(query,
                         Unmanaged.passUnretained(kSecAttrAccessible).toOpaque(),
                         Unmanaged.passUnretained(kSecAttrAccessibleWhenUnlockedThisDeviceOnly).toOpaque())

    for (cfKey, cfValue) in extras {
      CFDictionarySetValue(query,
                           Unmanaged.passUnretained(cfKey).toOpaque(),
                           Unmanaged.passUnretained(cfValue).toOpaque())
    }

    return query
  }

  func save(key: String, value: String) throws {
    guard !key.isEmpty else { return }
    guard let data = value.data(using: .utf8) else { return }

    // Delete any existing item first (safely — ignore result)
    delete(key: key)

    guard let query = makeQuery(
      account: key,
      extras: [(kSecValueData, data as CFData)]
    ) else {
      throw KeychainError.invalidInput
    }

    let status = SecItemAdd(query, nil)
    guard status == errSecSuccess else {
      throw KeychainError.saveFailed(status)
    }
  }

  func read(key: String) -> String? {
    guard !key.isEmpty else { return nil }

    let trueValue = kCFBooleanTrue!
    guard let query = makeQuery(
      account: key,
      extras: [
        (kSecReturnData, trueValue),
        (kSecMatchLimit, kSecMatchLimitOne),
      ]
    ) else { return nil }

    var result: AnyObject?
    let status = SecItemCopyMatching(query, &result)

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
    guard let query = makeQuery(account: key) else { return }
    SecItemDelete(query)
  }
}

private enum KeychainError: LocalizedError {
  case saveFailed(OSStatus)
  case invalidInput

  var errorDescription: String? {
    switch self {
    case .saveFailed(let status):
      "Failed to save to Keychain (status: \(status))"
    case .invalidInput:
      "Invalid Keychain input"
    }
  }
}
