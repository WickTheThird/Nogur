//
//  TokenStore.swift
//  Nogur
//
//  Created by Filip Bumbu on 28/09/2026.
//

import Foundation

final class TokenStore {
  static let shared = TokenStore()

  private enum Account {
    static let accessToken = "access-token"
    static let refreshToken = "refresh-token"
    static let emailAddress = "email-address"
  }

  private let keychain: KeychainStore

  init(
    service: String = Bundle.main.bundleIdentifier ?? "com.filipbumbu.Nogur"
  ) {
    keychain = KeychainStore(service: service)
  }

  var accessToken: String? {
    try? keychain.read(account: Account.accessToken)
  }

  var refreshToken: String? {
    try? keychain.read(account: Account.refreshToken)
  }

  var emailAddress: String? {
    try? keychain.read(account: Account.emailAddress)
  }

  var hasSession: Bool {
    accessToken != nil && refreshToken != nil
  }

  func save(
    _ tokens: TokenPair,
    emailAddress: String
  ) throws {
    do {
      try keychain.save(
        tokens.accessToken,
        account: Account.accessToken
      )

      try keychain.save(
        tokens.refreshToken,
        account: Account.refreshToken
      )

      try keychain.save(
        emailAddress,
        account: Account.emailAddress
      )
    } catch {
      clear()
      throw error
    }
  }

  func clear() {
    try? keychain.delete(account: Account.accessToken)
    try? keychain.delete(account: Account.refreshToken)
    try? keychain.delete(account: Account.emailAddress)
  }
}
