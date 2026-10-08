//
//  KeychainStore.swift
//  Nogur
//
//  Created by Filip Bumbu on 28/09/2026.
//

import Foundation
import Security

protocol SecureStoring: Sendable {
  func save(_ value: String, account: String) throws
  func read(account: String) throws -> String?
  func delete(account: String) throws
}

enum KeychainError: LocalizedError {
  case unhandledStatus(OSStatus)
  case invalidData

  var errorDescription: String? {
    switch self {
    case .unhandledStatus(let status):
      let description = SecCopyErrorMessageString(status, nil) as String?
      return description ?? "Keychain error \(status)"
    case .invalidData:
      return "The saved Keychain vault is invalid"
    }
  }
}

private final class KeychainVaultCache: @unchecked Sendable {
  static let shared = KeychainVaultCache()

  let lock = NSLock()
  var valuesByService: [String: [String: String]] = [:]
  var failuresByService: [String: KeychainError] = [:]
}

struct KeychainStore: SecureStoring, Sendable {
  private static let vaultAccount = "nogur-vault-v1"

  let service: String
  private let cache = KeychainVaultCache.shared

  func save(_ value: String, account: String) throws {
    cache.lock.lock()
    defer { cache.lock.unlock() }

    var values = try loadValuesLocked()
    values[account] = value
    try writeVault(values)
    cache.valuesByService[service] = values
  }

  func read(account: String) throws -> String? {
    cache.lock.lock()
    defer { cache.lock.unlock() }
    return try loadValuesLocked()[account]
  }

  func delete(account: String) throws {
    cache.lock.lock()
    defer { cache.lock.unlock() }

    var values = try loadValuesLocked()
    guard values.removeValue(forKey: account) != nil else { return }
    try writeVault(values)
    cache.valuesByService[service] = values
  }

  private func loadValuesLocked() throws -> [String: String] {
    if let values = cache.valuesByService[service] {
      return values
    }
    if let failure = cache.failuresByService[service] {
      throw failure
    }

    do {
      let values: [String: String]
      if let vaultData = try readVaultData() {
        values = try JSONDecoder().decode([String: String].self, from: vaultData)
      } else {
        values = try readLegacyDeviceKey()
        try writeVault(values)
      }
      cache.valuesByService[service] = values
      return values
    } catch let error as KeychainError {
      cache.failuresByService[service] = error
      throw error
    } catch {
      let failure = KeychainError.invalidData
      cache.failuresByService[service] = failure
      throw failure
    }
  }

  private func readVaultData() throws -> Data? {
    var query = baseQuery(account: Self.vaultAccount)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else {
      throw KeychainError.unhandledStatus(status)
    }
    guard let data = result as? Data else { throw KeychainError.invalidData }
    return data
  }

  private func readLegacyDeviceKey() throws -> [String: String] {
    let account = "device-private-key"
    var query = baseQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return [:] }
    guard status == errSecSuccess else {
      throw KeychainError.unhandledStatus(status)
    }

    guard
      let data = result as? Data,
      let value = String(data: data, encoding: .utf8)
    else { throw KeychainError.invalidData }
    return [account: value]
  }

  private func writeVault(_ values: [String: String]) throws {
    let data = try JSONEncoder().encode(values)
    let query = baseQuery(account: Self.vaultAccount)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]

    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw KeychainError.unhandledStatus(updateStatus)
    }

    var item = query
    attributes.forEach { key, value in item[key] = value }
    let addStatus = SecItemAdd(item as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw KeychainError.unhandledStatus(addStatus)
    }
  }

  private func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}
