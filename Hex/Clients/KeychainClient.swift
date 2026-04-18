//
//  KeychainClient.swift
//  Hex
//
//  Stores and retrieves API keys from the macOS Keychain.
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

  func save(key: String, value: String) throws {
    guard let data = value.data(using: .utf8) else { return }

    // Delete existing item first
    delete(key: key)

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
      kSecValueData as String: data,
    ]

    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw KeychainError.saveFailed(status)
    }
  }

  func read(key: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]

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
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]

    SecItemDelete(query as CFDictionary)
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
