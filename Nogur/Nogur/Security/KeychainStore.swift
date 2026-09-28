//
//  KeychainStore.swift
//  Nogur
//
//  Created by Filip Bumbu on 28/09/2026.
//

import Foundation
import Security

enum KeychainError: LocalizedError {
  case unhandledStatus(OSStatus)
  case invalidData

  var errorDescription: String? {
    switch self {
    case .unhandledStatus(let status):
      let description = SecCopyErrorMessageString(status, nil) as String?
      return description ?? "Keychain error \(status)"
    case .invalidData:
      return "The saved Keychain is invalid"
    }
  }
}

struct KeychainStore {
  let service: String

  func save(
    _ value: String,
    account: String
  ) throws {
    guard let data = value.data(using: .utf8) else {
      throw KeychainError.invalidData
    }

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]

    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]

    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

    if updateStatus == errSecSuccess {
      return
    }

    guard updateStatus == errSecItemNotFound else {
      throw KeychainError.unhandledStatus(updateStatus)
    }

    var newItem = query
    attributes.forEach {
      key, value in newItem[key] = value
    }

    let addStatus = SecItemAdd(newItem as CFDictionary, nil)

    guard addStatus == errSecSuccess else {
      throw KeychainError.unhandledStatus(addStatus)
    }
  }

  func read(account: String) throws -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var result: CFTypeRef?

    let status = SecItemCopyMatching(query as CFDictionary, &result)

    if status == errSecItemNotFound {
      return nil
    }

    guard status == errSecSuccess else {
      throw KeychainError.unhandledStatus(status)
    }

    guard
      let data = result as? Data,
      let value = String(data: data, encoding: .utf8)
    else {
      throw KeychainError.invalidData
    }

    return value
  }

  func delete(account: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]

    let status = SecItemDelete(query as CFDictionary)

    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError.unhandledStatus(status)
    }
  }
}
