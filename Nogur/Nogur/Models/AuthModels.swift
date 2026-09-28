//
//  AuthModels.swift
//  Nogur
//
//  Created by Filip Bumbu on 28/09/2026.
//

import Foundation

struct TokenPair: Decodable {
  let accessToken: String
  let refreshToken: String
  let tokenType: String
  let expiresIn: Int
}

struct RegisterRequest: Encodable {
  let email: String
  let password: String
}

struct LoginRequest: Encodable {
  let email: String
  let password: String
}

struct APIErrorResponse: Decodable {
  let detail: String
}
