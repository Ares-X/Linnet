//
//  LinnetSettingsPage.swift
//  The single visual hierarchy owner for every Settings tab.
//

import SwiftUI

enum LinnetSettingsLayoutMetrics {
  static let minimumWindowWidth: CGFloat = 960
  static let defaultWindowWidth: CGFloat = 1040
  static let windowHeight: CGFloat = 600
  static let minimumColumnWidth: CGFloat = 400
  static let columnSpacing: CGFloat = 20
  static let pageHorizontalInset: CGFloat = 28
}

enum LinnetSettingsPageMark {
  case systemSymbol(String)
  case latinABC
}

struct LinnetSettingsPageMarkView: View {
  enum Context {
    case pageHeader
    case tab
  }

  let mark: LinnetSettingsPageMark
  let context: Context

  @ViewBuilder
  var body: some View {
    switch mark {
    case .systemSymbol(let name):
      Image(systemName: name)
        .symbolRenderingMode(.hierarchical)
    case .latinABC:
      Text(verbatim: "ABC")
        .tracking(context == .pageHeader ? -0.7 : -0.4)
    }
  }
}

/// The single content grid used by Settings pages that have two peer groups.
/// The Settings window minimum is sized to preserve these columns, so
/// localized copy wraps inside a column instead of changing page topology.
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
    HStack(alignment: .top, spacing: LinnetSettingsLayoutMetrics.columnSpacing) {
      leading.frame(
        minWidth: LinnetSettingsLayoutMetrics.minimumColumnWidth,
        maxWidth: .infinity,
        alignment: .topLeading)
      trailing.frame(
        minWidth: LinnetSettingsLayoutMetrics.minimumColumnWidth,
        maxWidth: .infinity,
        alignment: .topLeading)
    }
  }
}

struct LinnetSettingsPage<Content: View>: View {
  let title: LocalizedStringKey
  let summary: LocalizedStringKey
  private let mark: LinnetSettingsPageMark
  @ViewBuilder let content: Content

  init(
    _ title: LocalizedStringKey,
    summary: LocalizedStringKey,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.summary = summary
    self.mark = .systemSymbol(systemImage)
    self.content = content()
  }

  init(
    _ title: LocalizedStringKey,
    summary: LocalizedStringKey,
    mark: LinnetSettingsPageMark,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.summary = summary
    self.mark = mark
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
      LinnetSettingsPageMarkView(mark: mark, context: .pageHeader)
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
