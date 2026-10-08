//
//  TokenStore.swift
//  Nogur
//
//  Created by Filip Bumbu on 28/09/2026.
//

import Foundation

protocol TokenStoring: AnyObject, Sendable {
  var accessToken: String? { get }
  var refreshToken: String? { get }
  var emailAddress: String? { get }
  var hasSession: Bool { get }

  func save(_ tokens: TokenPair, emailAddress: String?) throws
  func clear()
}

final class TokenStore: TokenStoring, @unchecked Sendable {
  static let shared = TokenStore()

  private enum Account {
    static let accessToken = "access-token"
    static let refreshToken = "refresh-token"
    static let emailAddress = "email-address"
  }

  private let keychain: any SecureStoring
  private let lock = NSLock()

  init(
    service: String = Bundle.main.bundleIdentifier ?? "com.filipbumbu.Nogur",
    keychain: (any SecureStoring)? = nil
  ) {
    self.keychain = keychain ?? KeychainStore(service: service)
  }

  var accessToken: String? {
    read(Account.accessToken)
  }

  var refreshToken: String? {
    read(Account.refreshToken)
  }

  var emailAddress: String? {
    read(Account.emailAddress)
  }

  var hasSession: Bool {
    accessToken != nil && refreshToken != nil
  }

  func save(
    _ tokens: TokenPair,
    emailAddress: String? = nil
  ) throws {
    lock.lock()
    defer { lock.unlock() }

    do {
      try keychain.save(
        tokens.accessToken,
        account: Account.accessToken
      )

      try keychain.save(
        tokens.refreshToken,
        account: Account.refreshToken
      )

      if let emailAddress {
        try keychain.save(
          emailAddress,
          account: Account.emailAddress
        )
      }
    } catch {
      clearWithoutLock()
      throw error
    }
  }

  func clear() {
    lock.lock()
    defer { lock.unlock() }
    clearWithoutLock()
  }

  private func read(_ account: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return try? keychain.read(account: account)
  }

  private func clearWithoutLock() {
    try? keychain.delete(account: Account.accessToken)
    try? keychain.delete(account: Account.refreshToken)
    try? keychain.delete(account: Account.emailAddress)
  }
}
