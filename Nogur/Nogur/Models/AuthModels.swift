//
//  AuthModels.swift
//  Nogur
//
//  Created by Filip Bumbu on 28/09/2026.
//

import Foundation

struct TokenPair: Codable, Sendable, Equatable {
  let accessToken: String
  let refreshToken: String
  let tokenType: String
  let expiresIn: Int
}

struct RegisterRequest: Encodable, Sendable {
  let email: String
  let password: String
}

struct LoginRequest: Encodable, Sendable {
  let email: String
  let password: String
}

struct RefreshRequest: Encodable, Sendable {
  let refreshToken: String
}

struct APIErrorResponse: Decodable, Sendable, Equatable {
  let detail: String
  let code: String?
  let fieldErrors: [String: [String]]?

  init(
    detail: String,
    code: String? = nil,
    fieldErrors: [String: [String]]? = nil
  ) {
    self.detail = detail
    self.code = code
    self.fieldErrors = fieldErrors
  }

  private enum CodingKeys: String, CodingKey {
    case detail
    case code
    case fieldErrors = "field_errors"
  }

  private struct ValidationIssue: Decodable {
    let loc: [StringOrInt]
    let msg: String
  }

  private enum StringOrInt: Decodable {
    case string(String)
    case int(Int)

    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let value = try? container.decode(String.self) { self = .string(value) }
      else { self = .int(try container.decode(Int.self)) }
    }

    var text: String {
      switch self {
      case .string(let value): value
      case .int(let value): String(value)
      }
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    code = try container.decodeIfPresent(String.self, forKey: .code)
    if let message = try? container.decode(String.self, forKey: .detail) {
      detail = message
      fieldErrors = try container.decodeIfPresent(
        [String: [String]].self,
        forKey: .fieldErrors
      )
      return
    }

    let issues = (try? container.decode([ValidationIssue].self, forKey: .detail)) ?? []
    var fields: [String: [String]] = [:]
    for issue in issues {
      let field = issue.loc.drop(while: { $0.text == "body" }).map(\.text).joined(separator: ".")
      fields[field.isEmpty ? "request" : field, default: []].append(issue.msg)
    }
    detail = issues.first?.msg ?? "The server rejected the request."
    fieldErrors = fields.isEmpty ? nil : fields
  }
}
