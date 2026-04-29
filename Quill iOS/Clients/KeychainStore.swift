//
//  KeychainStore.swift
//  Quill (iOS)
//
//  Direct Security-framework keychain helpers, bypassing the shared
//  `KeychainClient` (which uses the `@DependencyClient` macro). On iOS
//  with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` the macro-wrapped
//  call was silently not persisting API keys saved from Settings, so
//  the iOS target writes and reads keychain items itself here.
//
//  Uses the same service + account identifiers as `KeychainClient` so
//  macOS and iOS remain compatible if we ever share a keychain.
//

import Foundation
import Security

enum KeychainStore {
  private static let service = "com.joevasquez.Quill"

  private static func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  /// Save `value` under `account`. Returns the raw `OSStatus` from
  /// `SecItemAdd` (or `errSecParam` for local validation failures) so
  /// callers can surface concrete failure codes. Deletes any existing
  /// item first to avoid `errSecDuplicateItem`.
  @discardableResult
  static func save(account: String, value: String) -> OSStatus {
    guard !account.isEmpty else { return errSecParam }
    guard let data = value.data(using: .utf8) else { return errSecParam }

    SecItemDelete(baseQuery(account: account) as CFDictionary)

    var query = baseQuery(account: account)
    query[kSecValueData as String] = data
    // Protection class is set on save only — it's not reliable as a
    // query filter on `SecItemCopyMatching`.
    query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

    let status = SecItemAdd(query as CFDictionary, nil)
    print("KeychainStore.save(account=\(account), bytes=\(data.count)) status=\(status)")
    return status
  }

  /// Returns the stored string (if any) plus the raw `OSStatus` so
  /// callers can distinguish "not saved yet" (-25300) from other
  /// errors (-34018 missing entitlement, -25291 no keychain, etc.).
  static func read(account: String) -> (value: String?, status: OSStatus) {
    guard !account.isEmpty else { return (nil, errSecParam) }

    var query = baseQuery(account: account)
    query[kSecReturnData as String] = kCFBooleanTrue as Any
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess,
          let data = result as? Data,
          let str = String(data: data, encoding: .utf8)
    else {
      return (nil, status)
    }
    return (str, status)
  }

  @discardableResult
  static func delete(account: String) -> OSStatus {
    guard !account.isEmpty else { return errSecParam }
    return SecItemDelete(baseQuery(account: account) as CFDictionary)
  }
}
