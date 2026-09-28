//
//  DashboardComponents.swift
//  Nogur
//
//  Created by Filip Bumbu on 28/09/2026.
//

import SwiftUI

struct DashboardPage<Content: View>: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    ZStack {
      Color(nsColor: .windowBackgroundColor)

      if !reduceTransparency {
        Circle()
          .fill(Color.accentColor.opacity(0.11))
          .frame(width: 420, height: 420)
          .blur(radius: 110)
          .offset(x: -330, y: -250)

        Circle()
          .fill(Color.purple.opacity(0.07))
          .frame(width: 340, height: 340)
          .blur(radius: 110)
          .offset(x: 390, y: 260)
      }

      ScrollView {
        content
          .frame(maxWidth: 920, alignment: .leading)
          .padding(36)
          .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .scrollIndicators(.hidden)
    }
  }
}

struct DashboardHeader: View {
  let title: String
  let subtitle: String
  let systemImage: String

  var body: some View {
    HStack(spacing: 16) {
      ZStack {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(Color.accentColor.opacity(0.13))

        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(Color.white.opacity(0.45), lineWidth: 1)

        Image(systemName: systemImage)
          .font(.system(size: 24, weight: .medium))
          .foregroundStyle(.tint)
      }
      .frame(width: 54, height: 54)
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.system(size: 28, weight: .bold, design: .rounded))

        Text(subtitle)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }
}

struct GlassPanel<Content: View>: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .padding(22)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(
            reduceTransparency
              ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
              : AnyShapeStyle(.ultraThinMaterial)
          )
      }
      .overlay {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .stroke(
            LinearGradient(
              colors: [
                Color.white.opacity(0.62),
                Color.white.opacity(0.18),
                Color.primary.opacity(0.07),
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            ),
            lineWidth: 1
          )
      }
      .shadow(color: .black.opacity(0.07), radius: 16, y: 8)
  }
}

struct AccountDetailRow: View {
  let systemImage: String
  let title: String
  let value: String
  let supportingText: String

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: systemImage)
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(.tint)
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.callout)
          .foregroundStyle(.secondary)

        Text(value)
          .font(.body.weight(.medium))
          .textSelection(.enabled)

        Text(supportingText)
          .font(.caption)
          .foregroundStyle(.tertiary)
      }

      Spacer(minLength: 12)
    }
    .accessibilityElement(children: .combine)
  }
}

struct StatusPill: View {
  let title: String
  let systemImage: String
  let color: Color

  var body: some View {
    Label(title, systemImage: systemImage)
      .font(.caption.weight(.semibold))
      .foregroundStyle(color)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(color.opacity(0.11), in: Capsule())
  }
}
