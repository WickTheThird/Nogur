//
//  APIClient.swift
//  Nogur
//
//  Created by Filip Bumbu on 28/09/2026.
//

import Foundation

extension Notification.Name {
  static let nogurAuthenticationExpired = Notification.Name(
    "com.filipbumbu.Nogur.authenticationExpired"
  )
}

enum HTTPMethod: String, Sendable {
  case delete = "DELETE"
  case get = "GET"
  case post = "POST"
}

enum APIError: LocalizedError, Sendable, Equatable {
  case cancelled
  case invalidRequest
  case invalidResponse
  case notAuthenticated
  case timedOut
  case server(statusCode: Int, response: APIErrorResponse)
  case transport(String)

  var statusCode: Int? {
    if case .server(let statusCode, _) = self {
      return statusCode
    }
    return nil
  }

  var errorDescription: String? {
    switch self {
    case .cancelled:
      return "The request was cancelled."
    case .invalidRequest:
      return "Nogur could not create the request."
    case .invalidResponse:
      return "Nogur received an invalid response from the server."
    case .notAuthenticated:
      return "Sign in again to continue."
    case .timedOut:
      return "The server took too long to respond."
    case .server(_, let response):
      return response.detail
    case .transport(let message):
      return message
    }
  }
}

struct EmptyResponse: Decodable, Sendable {}

actor APIClient {
  static let production = APIClient(
    baseURL: URL(string: "https://api.bumbuindustries.com/v1")!,
    tokenStore: TokenStore.shared
  )

  nonisolated let baseURL: URL

  private let session: URLSession
  private let tokenStore: any TokenStoring
  private let identityStore: DeviceIdentityStore
  private var refreshTask: Task<TokenPair, Error>?

  init(
    baseURL: URL,
    tokenStore: any TokenStoring = TokenStore.shared,
    identityStore: DeviceIdentityStore = .shared,
    session: URLSession? = nil
  ) {
    self.baseURL = baseURL
    self.tokenStore = tokenStore
    self.identityStore = identityStore

    if let session {
      self.session = session
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = 20
      configuration.timeoutIntervalForResource = 45
      configuration.waitsForConnectivity = true
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      self.session = URLSession(configuration: configuration)
    }
  }

  func register(email: String, password: String) async throws -> TokenPair {
    try await send(
      path: "auth/register",
      method: .post,
      body: RegisterRequest(email: email, password: password),
      requiresAuthentication: false
    )
  }

  func login(email: String, password: String) async throws -> TokenPair {
    try await send(
      path: "auth/login",
      method: .post,
      body: LoginRequest(email: email, password: password),
      requiresAuthentication: false
    )
  }

  func refresh() async throws -> TokenPair {
    if let refreshTask {
      return try await refreshTask.value
    }

    guard let refreshToken = tokenStore.refreshToken else {
      authenticationDidFail()
      throw APIError.notAuthenticated
    }

    let task = Task<TokenPair, Error> { [baseURL, session, tokenStore] in
      let url = baseURL.appendingPathComponent("auth/refresh")
      var request = URLRequest(url: url, timeoutInterval: 20)
      request.httpMethod = HTTPMethod.post.rawValue
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.httpBody = try JSONCoding.encoder.encode(
        RefreshRequest(refreshToken: refreshToken)
      )

      let pair: TokenPair = try await Self.execute(request, session: session)
      try tokenStore.save(pair, emailAddress: nil)
      return pair
    }
    refreshTask = task

    do {
      let tokens = try await task.value
      refreshTask = nil
      return tokens
    } catch {
      refreshTask = nil
      authenticationDidFail()
      throw error
    }
  }

  func send<Response: Decodable & Sendable>(
    path: String,
    method: HTTPMethod = .get,
    queryItems: [URLQueryItem] = [],
    requiresAuthentication: Bool = true,
    requiresDevice: Bool = false,
    retryAfterUnauthorized: Bool = true
  ) async throws -> Response {
    try await send(
      path: path,
      method: method,
      bodyData: nil,
      queryItems: queryItems,
      requiresAuthentication: requiresAuthentication,
      requiresDevice: requiresDevice,
      retryAfterUnauthorized: retryAfterUnauthorized
    )
  }

  func send<Response: Decodable & Sendable, Body: Encodable & Sendable>(
    path: String,
    method: HTTPMethod = .post,
    body: Body,
    queryItems: [URLQueryItem] = [],
    requiresAuthentication: Bool = true,
    requiresDevice: Bool = false,
    retryAfterUnauthorized: Bool = true
  ) async throws -> Response {
    let bodyData = try JSONCoding.encoder.encode(body)
    return try await send(
      path: path,
      method: method,
      bodyData: bodyData,
      queryItems: queryItems,
      requiresAuthentication: requiresAuthentication,
      requiresDevice: requiresDevice,
      retryAfterUnauthorized: retryAfterUnauthorized
    )
  }

  func delete(path: String, requiresDevice: Bool = false) async throws {
    let _: EmptyResponse = try await send(
      path: path,
      method: .delete,
      bodyData: nil,
      queryItems: [],
      requiresAuthentication: true,
      requiresDevice: requiresDevice,
      retryAfterUnauthorized: true,
      acceptsEmptyResponse: true
    )
  }

  func websocketURL(ticket: String) throws -> URL {
    guard var components = URLComponents(
      url: baseURL.appendingPathComponent("ws"),
      resolvingAgainstBaseURL: false
    ) else {
      throw APIError.invalidRequest
    }
    components.scheme = components.scheme == "http" ? "ws" : "wss"
    components.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
    guard let url = components.url else { throw APIError.invalidRequest }
    return url
  }

  private func send<Response: Decodable & Sendable>(
    path: String,
    method: HTTPMethod,
    bodyData: Data?,
    queryItems: [URLQueryItem],
    requiresAuthentication: Bool,
    requiresDevice: Bool,
    retryAfterUnauthorized: Bool,
    acceptsEmptyResponse: Bool = false
  ) async throws -> Response {
    var request = try makeRequest(
      path: path,
      method: method,
      bodyData: bodyData,
      queryItems: queryItems,
      requiresAuthentication: requiresAuthentication,
      requiresDevice: requiresDevice
    )

    do {
      return try await Self.execute(
        request,
        session: session,
        acceptsEmptyResponse: acceptsEmptyResponse
      )
    } catch APIError.server(let statusCode, _)
      where statusCode == 401
        && requiresAuthentication
        && retryAfterUnauthorized
    {
      let tokens = try await refresh()
      request.setValue(
        "Bearer \(tokens.accessToken)",
        forHTTPHeaderField: "Authorization"
      )
      return try await Self.execute(
        request,
        session: session,
        acceptsEmptyResponse: acceptsEmptyResponse
      )
    }
  }

  private func makeRequest(
    path: String,
    method: HTTPMethod,
    bodyData: Data?,
    queryItems: [URLQueryItem],
    requiresAuthentication: Bool,
    requiresDevice: Bool
  ) throws -> URLRequest {
    let rawURL = baseURL.appendingPathComponent(path)
    guard var components = URLComponents(
      url: rawURL,
      resolvingAgainstBaseURL: false
    ) else {
      throw APIError.invalidRequest
    }
    if !queryItems.isEmpty {
      components.queryItems = queryItems
    }
    guard let url = components.url else {
      throw APIError.invalidRequest
    }

    var request = URLRequest(url: url, timeoutInterval: 20)
    request.httpMethod = method.rawValue
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let bodyData {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = bodyData
    }

    if requiresAuthentication {
      guard let accessToken = tokenStore.accessToken else {
        throw APIError.notAuthenticated
      }
      request.setValue(
        "Bearer \(accessToken)",
        forHTTPHeaderField: "Authorization"
      )
    }

    if requiresDevice {
      guard
        let deviceID = identityStore.deviceID,
        let deviceToken = identityStore.deviceToken
      else {
        throw DeviceIdentityError.notVerified
      }
      request.setValue(deviceID.uuidString, forHTTPHeaderField: "X-Device-ID")
      request.setValue(deviceToken, forHTTPHeaderField: "X-Device-Token")
    }
    return request
  }

  private static func execute<Response: Decodable & Sendable>(
    _ request: URLRequest,
    session: URLSession,
    acceptsEmptyResponse: Bool = false
  ) async throws -> Response {
    let data: Data
    let response: URLResponse

    do {
      (data, response) = try await session.data(for: request)
    } catch is CancellationError {
      throw APIError.cancelled
    } catch let error as URLError where error.code == .cancelled {
      throw APIError.cancelled
    } catch let error as URLError where error.code == .timedOut {
      throw APIError.timedOut
    } catch {
      throw APIError.transport(error.localizedDescription)
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      throw APIError.invalidResponse
    }

    guard (200..<300).contains(httpResponse.statusCode) else {
      let errorResponse = (try? JSONCoding.decoder.decode(
        APIErrorResponse.self,
        from: data
      )) ?? APIErrorResponse(
        detail: HTTPURLResponse.localizedString(
          forStatusCode: httpResponse.statusCode
        )
      )
      throw APIError.server(
        statusCode: httpResponse.statusCode,
        response: errorResponse
      )
    }

    if acceptsEmptyResponse && data.isEmpty {
      guard let empty = EmptyResponse() as? Response else {
        throw APIError.invalidResponse
      }
      return empty
    }

    do {
      return try JSONCoding.decoder.decode(Response.self, from: data)
    } catch {
      throw APIError.invalidResponse
    }
  }

  private func authenticationDidFail() {
    tokenStore.clear()
    NotificationCenter.default.post(name: .nogurAuthenticationExpired, object: nil)
  }
}

enum JSONCoding {
  static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .custom { decoder in
      let value = try decoder.singleValueContainer().decode(String.self)
      let fractional = ISO8601DateFormatter()
      fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = fractional.date(from: value) { return date }
      let standard = ISO8601DateFormatter()
      standard.formatOptions = [.withInternetDateTime]
      if let date = standard.date(from: value) { return date }
      throw DecodingError.dataCorruptedError(
        in: try decoder.singleValueContainer(),
        debugDescription: "Invalid ISO 8601 date: \(value)"
      )
    }
    return decoder
  }
}
