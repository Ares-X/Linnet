//
//  LinnetSettingsPage.swift
//  The single visual hierarchy owner for every Settings tab.
//

import SwiftUI

enum LinnetSettingsLayoutMetrics {
  static let minimumWindowWidth: CGFloat = 760
  static let defaultWindowWidth: CGFloat = 960
  static let minimumWindowHeight: CGFloat = 520
  static let defaultWindowHeight: CGFloat = 640
  static let minimumColumnWidth: CGFloat = 400
  static let columnSpacing: CGFloat = 20
  static let pageHorizontalInset: CGFloat = 28
}

/// The single adaptive content grid used by Settings pages with two peer
/// groups. The default window keeps both columns visible; the compact minimum
/// stacks them without shrinking controls or localized text.
struct LinnetSettingsTwoColumnLayout<Leading: View, Trailing: View>: View {
  private let leading: Leading
  private let trailing: Trailing

  init(
    @ViewBuilder leading: () -> Leading,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.leading = leading()
    self.trailing = trailing()
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: LinnetSettingsLayoutMetrics.columnSpacing) {
        column(leading)
        column(trailing)
      }
      VStack(alignment: .leading, spacing: LinnetSettingsLayoutMetrics.columnSpacing) {
        column(leading)
        column(trailing)
      }
    }
  }

  private func column(_ content: some View) -> some View {
    content.frame(
      minWidth: LinnetSettingsLayoutMetrics.minimumColumnWidth,
      maxWidth: .infinity,
      alignment: .topLeading)
  }
}

struct LinnetSettingsPage<Content: View>: View {
  let title: LocalizedStringKey
  let summary: LocalizedStringKey
  private let systemImage: String
  @ViewBuilder let content: Content

  init(
    _ title: LocalizedStringKey,
    summary: LocalizedStringKey,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.summary = summary
    self.systemImage = systemImage
    self.content = content()
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        header
        content
      }
      .frame(maxWidth: 980, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .top)
      .padding(.horizontal, LinnetSettingsLayoutMetrics.pageHorizontalInset)
      .padding(.top, 24)
      .padding(.bottom, 32)
    }
    .accessibilityIdentifier("settings.page.scroll")
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: systemImage)
        .symbolRenderingMode(.hierarchical)
        .font(.system(size: 19, weight: .semibold))
        .foregroundStyle(.tint)
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.title3.weight(.semibold))
        Text(summary)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

}
