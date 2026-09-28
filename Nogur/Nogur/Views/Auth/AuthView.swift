//
//  AuthView.swift
//  Nogur
//
//  Created by Filip Bumbu on 28/09/2026.
//

import SwiftUI

struct AuthView: View {
  private enum Field: Hashable {
    case email
    case password
    case confirmPassword
  }

  @ObservedObject var viewModel: AuthViewModel
  @FocusState private var focusedField: Field?

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        glossyBackground

        ScrollView {
          authCard
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
            .frame(minHeight: geometry.size.height)
        }
        .scrollIndicators(.hidden)
      }
    }
    .frame(
      minWidth: 640,
      minHeight: 500
    )
    .onAppear {
      focusedField = .email
    }
    .onChange(of: viewModel.mode) { _, _ in
      focusedField = .email
    }
  }

  private var glossyBackground: some View {
    ZStack {
      Color(nsColor: .windowBackgroundColor)

      Circle()
        .fill(Color.accentColor.opacity(0.16))
        .frame(width: 420, height: 420)
        .blur(radius: 90)
        .offset(x: -260, y: -190)

      Circle()
        .fill(Color.purple.opacity(0.11))
        .frame(width: 360, height: 360)
        .blur(radius: 100)
        .offset(x: 300, y: 220)

      LinearGradient(
        colors: [
          Color.white.opacity(0.1),
          Color.clear,
        ],
        startPoint: .top,
        endPoint: .bottom
      )
    }
    .ignoresSafeArea()
  }

  private var authCard: some View {
    VStack(spacing: 16) {
      identity

      VStack(spacing: 5) {
        Text(viewModel.mode.title)
          .font(.title2)
          .fontWeight(.semibold)

        Text(viewModel.mode.subtitle)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }

      Picker(
        "Authentication mode",
        selection: $viewModel.mode
      ) {
        ForEach(AuthMode.allCases) { mode in
          Text(mode.pickerTitle)
            .tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(3)
      .background(
        .ultraThinMaterial,
        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
      )

      VStack(spacing: 12) {
        emailField
        passwordField

        if viewModel.mode == .signup {
          confirmPasswordField
        }
      }

      errorArea

      Button(action: submit) {
        HStack(spacing: 8) {
          if viewModel.isLoading {
            ProgressView()
              .controlSize(.small)
          }

          Text(
            viewModel.isLoading
              ? "Please wait..."
              : viewModel.mode.buttonTitle
          )
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 22)
      }
      .buttonStyle(GlossyPrimaryButtonStyle())
      .keyboardShortcut(.defaultAction)
      .disabled(!viewModel.canSubmit)
      .accessibilityIdentifier("auth.submit")
    }
    .controlSize(.large)
    .frame(width: 380)
    .padding(28)
    .background {
      ZStack {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .fill(.ultraThinMaterial)

        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .fill(
            LinearGradient(
              colors: [
                Color.white.opacity(0.24),
                Color.white.opacity(0.05),
                Color.clear,
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
      }
    }
    .overlay {
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .stroke(
          LinearGradient(
            colors: [
              Color.white.opacity(0.72),
              Color.white.opacity(0.2),
              Color.primary.opacity(0.08),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          ),
          lineWidth: 1
        )
    }
    .shadow(
      color: Color.accentColor.opacity(0.12),
      radius: 32,
      y: 14
    )
    .shadow(
      color: .black.opacity(0.09),
      radius: 18,
      y: 10
    )
  }

  private var identity: some View {
    HStack(spacing: 11) {
      ZStack {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(.ultraThinMaterial)

        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(
            LinearGradient(
              colors: [
                Color.accentColor.opacity(0.24),
                Color.accentColor.opacity(0.08),
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )

        Image(systemName: "display")
          .font(.system(size: 21, weight: .medium))
          .foregroundStyle(.tint)
      }
      .frame(width: 42, height: 42)
      .accessibilityHidden(true)

      Text("Nogur")
        .font(.system(size: 26, weight: .bold, design: .rounded))
    }
  }

  private var emailField: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Email address")
        .font(.callout)
        .fontWeight(.medium)

      TextField(
        "name@example.com",
        text: $viewModel.email
      )
      .textContentType(.emailAddress)
      .textFieldStyle(.plain)
      .modifier(GlossyFieldStyle(isFocused: focusedField == .email))
      .focused($focusedField, equals: .email)
      .onSubmit {
        focusedField = .password
      }
      .accessibilityIdentifier("auth.email")
    }
  }

  private var passwordField: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Password")
        .font(.callout)
        .fontWeight(.medium)

      SecureField(
        "At least 8 characters",
        text: $viewModel.password
      )
      .textContentType(
        viewModel.mode == .login
          ? .password
          : .newPassword
      )
      .textFieldStyle(.plain)
      .modifier(GlossyFieldStyle(isFocused: focusedField == .password))
      .focused($focusedField, equals: .password)
      .onSubmit {
        if viewModel.mode == .signup {
          focusedField = .confirmPassword
        } else {
          submit()
        }
      }
      .accessibilityIdentifier("auth.password")
    }
  }

  private var confirmPasswordField: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Confirm password")
        .font(.callout)
        .fontWeight(.medium)

      SecureField(
        "Enter your password again",
        text: $viewModel.confirmPassword
      )
      .textContentType(.newPassword)
      .textFieldStyle(.plain)
      .modifier(GlossyFieldStyle(isFocused: focusedField == .confirmPassword))
      .focused(
        $focusedField,
        equals: .confirmPassword
      )
      .onSubmit {
        submit()
      }
      .accessibilityIdentifier("auth.confirmPassword")
    }
  }

  @ViewBuilder
  private var errorArea: some View {
    if let errorMessage = viewModel.errorMessage {
      Label {
        Text(errorMessage)
          .fixedSize(
            horizontal: false,
            vertical: true
          )
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
      }
      .font(.callout)
      .foregroundStyle(.red)
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        Color.red.opacity(0.08),
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .accessibilityIdentifier("auth.error")
    } else {
      Color.clear
        .frame(height: 32)
    }
  }

  private func submit() {
    Task {
      await viewModel.submit()
    }
  }
}

#Preview {
  AuthView(viewModel: AuthViewModel())
}

private struct GlossyFieldStyle: ViewModifier {
  let isFocused: Bool

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, 11)
      .frame(height: 36)
      .background(
        .thinMaterial,
        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(
            LinearGradient(
              colors: [
                Color.white.opacity(0.2),
                Color.clear,
              ],
              startPoint: .top,
              endPoint: .bottom
            )
          )
          .allowsHitTesting(false)
      }
      .overlay {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .stroke(
            isFocused
              ? Color.accentColor.opacity(0.85)
              : Color.white.opacity(0.42),
            lineWidth: isFocused ? 1.5 : 1
          )
          .allowsHitTesting(false)
      }
      .shadow(
        color: isFocused
          ? Color.accentColor.opacity(0.16)
          : Color.black.opacity(0.04),
        radius: isFocused ? 7 : 3,
        y: 2
      )
  }
}

private struct GlossyPrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(.white)
      .padding(.horizontal, 16)
      .padding(.vertical, 7)
      .background {
        ZStack {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(
              LinearGradient(
                colors: [
                  Color.accentColor.opacity(0.88),
                  Color.accentColor,
                ],
                startPoint: .top,
                endPoint: .bottom
              )
            )

          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(
              LinearGradient(
                colors: [
                  Color.white.opacity(0.28),
                  Color.clear,
                ],
                startPoint: .top,
                endPoint: .center
              )
            )
        }
      }
      .overlay {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(Color.white.opacity(0.35), lineWidth: 1)
      }
      .shadow(
        color: Color.accentColor.opacity(isEnabled ? 0.28 : 0),
        radius: 10,
        y: 5
      )
      .opacity(isEnabled ? 1 : 0.45)
      .brightness(configuration.isPressed ? -0.08 : 0)
  }
}
