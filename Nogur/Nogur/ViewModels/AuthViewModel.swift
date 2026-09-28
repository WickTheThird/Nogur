//
//  AuthViewModel.swift
//  Nogur
//
//  Created by Filip Bumbu on 28/09/2026.
//

import Combine
import Foundation

enum AuthMode: String, CaseIterable, Identifiable {
  case login
  case signup

  var id: Self {
    self
  }

  var title: String {
    switch self {
    case .login:
      return "Welcome back"

    case .signup:
      return "Create your account"
    }
  }

  var subtitle: String {
    switch self {
    case .login:
      return "Sign in to access your Nogur devices."

    case .signup:
      return "Create an account to connect your first Mac."
    }
  }

  var buttonTitle: String {
    switch self {
    case .login:
      return "Sign In"

    case .signup:
      return "Create Account"
    }
  }

  var pickerTitle: String {
    switch self {
    case .login:
      return "Sign In"

    case .signup:
      return "Sign Up"
    }
  }
}

@MainActor
final class AuthViewModel: ObservableObject {
  @Published var mode: AuthMode = .login {
    didSet {
      guard mode != oldValue else { return }

      password = ""
      confirmPassword = ""
      errorMessage = nil
    }
  }

  @Published var email = ""
  @Published var password = ""
  @Published var confirmPassword = ""

  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage: String?
  @Published private(set) var isAuthenticated: Bool
  @Published private(set) var currentEmail: String?

  private let apiClient: APIClient
  private let tokenStore: TokenStore

  init(
    apiClient: APIClient? = nil,
    tokenStore: TokenStore? = nil
  ) {
    let resolvedAPIClient = apiClient ?? .production
    let resolvedTokenStore = tokenStore ?? .shared

    self.apiClient = resolvedAPIClient
    self.tokenStore = resolvedTokenStore
    isAuthenticated = resolvedTokenStore.hasSession
    currentEmail = resolvedTokenStore.emailAddress
  }

  var canSubmit: Bool {
    guard !isLoading else {
      return false
    }

    guard
      !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !password.isEmpty
    else {
      return false
    }

    if mode == .signup {
      return !confirmPassword.isEmpty
    }

    return true
  }

  func submit() async {
    guard !isLoading else {
      return
    }

    errorMessage = nil

    if let validationError {
      errorMessage = validationError
      return
    }

    isLoading = true
    defer {
      isLoading = false
    }

    let normalizedEmail =
      email
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    do {
      let tokens: TokenPair

      switch mode {
      case .login:
        tokens = try await apiClient.login(
          email: normalizedEmail,
          password: password
        )

      case .signup:
        tokens = try await apiClient.register(
          email: normalizedEmail,
          password: password
        )
      }

      try tokenStore.save(
        tokens,
        emailAddress: normalizedEmail
      )
      currentEmail = normalizedEmail
      isAuthenticated = true
    } catch is CancellationError {
      return
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func signOut() {
    tokenStore.clear()

    email = ""
    password = ""
    confirmPassword = ""
    errorMessage = nil
    currentEmail = nil
    isAuthenticated = false
  }

  private var validationError: String? {
    let normalizedEmail = email.trimmingCharacters(
      in: .whitespacesAndNewlines
    )

    let emailPattern = #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#

    if normalizedEmail.range(
      of: emailPattern,
      options: .regularExpression
    ) == nil {
      return "Enter a valid email address."
    }

    if password.count < 8 {
      return "Your password must contain at least 8 characters."
    }

    if mode == .signup && password != confirmPassword {
      return "The passwords do not match."
    }

    return nil
  }
}
