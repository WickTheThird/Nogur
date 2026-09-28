//
//  APIClient.swift
//  Nogur
//
//  Created by Filip Bumbu on 28/09/2026.
//

import Foundation

enum APIError: LocalizedError {
  case invalidResponse
  case server(statusCode: Int, message: String)
  case transport(Error)

  var errorDescription: String? {
    switch self {
    case .invalidResponse:
      return "Nogur received an invalid response from the server."

    case .server(_, let message):
      return message

    case .transport(let error):
      return error.localizedDescription
    }
  }
}

struct APIClient {
  static let production = APIClient(
    baseURL: URL(string: "https://api.bumbuindustries.com")!
  )

  private let baseURL: URL
  private let session: URLSession

  init(
    baseURL: URL,
    session: URLSession = .shared
  ) {
    self.baseURL = baseURL
    self.session = session
  }

  func register(
    email: String,
    password: String
  ) async throws -> TokenPair {
    try await post(
      path: "auth/register",
      body: RegisterRequest(email: email, password: password)
    )
  }

  func login(
    email: String,
    password: String
  ) async throws -> TokenPair {
    try await post(
      path: "auth/login",
      body: LoginRequest(email: email, password: password)
    )
  }

  private func post<Response: Decodable, Body: Encodable>(
    path: String,
    body: Body
  ) async throws -> Response {
    let url = baseURL.appendingPathComponent(path)

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue(
      "application/json",
      forHTTPHeaderField: "Content-Type"
    )
    request.setValue(
      "application/json",
      forHTTPHeaderField: "Accept"
    )
    request.httpBody = try JSONEncoder().encode(body)

    let result: (Data, URLResponse)

    do {
      result = try await session.data(for: request)
    } catch {
      throw APIError.transport(error)
    }

    let (data, response) = result

    guard let httpResponse = response as? HTTPURLResponse else {
      throw APIError.invalidResponse
    }

    guard (200..<300).contains(httpResponse.statusCode) else {
      let errorResponse = try? JSONDecoder().decode(
        APIErrorResponse.self,
        from: data
      )

      let fallbackMessage = HTTPURLResponse.localizedString(
        forStatusCode: httpResponse.statusCode
      )

      throw APIError.server(
        statusCode: httpResponse.statusCode,
        message: errorResponse?.detail ?? fallbackMessage
      )
    }

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    do {
      return try decoder.decode(Response.self, from: data)
    } catch {
      throw APIError.invalidResponse
    }
  }
}
