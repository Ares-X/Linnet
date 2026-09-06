// Visual theme-family selection for the Appearance settings draft. Theme
// colors and treatments still come only from the bundled squirrel.yaml catalog.

import AppKit
import SwiftUI

extension LinnetSettingsDocument.ThemeFamily {
  fileprivate var settingsTitle: LocalizedStringKey {
    switch self {
    case .paperLedger: "Xuan"
    case .moonJade: "Moon"
    case .sidecarSlate: "Slate"
    case .clayTiles: "Clay"
    case .mistJade: "Mist"
    case .nativeGlass: "Glass"
    case .inkCinnabar: "Ink"
    }
  }
}
/// The single Settings entry point for selecting a theme family. Every card
/// projects its paired Light and Dark schemes from the bundled Catalog; the
/// native Settings chrome never inherits a candidate-window palette.
struct LinnetSettingsThemeFamilyPicker: View {
  @Binding var selection: LinnetSettingsDocument.ThemeFamily
  @Binding var mode: LinnetSettingsDocument.ThemeMode
  private let columns = [GridItem(.adaptive(minimum: 190, maximum: 250), spacing: 10)]
  var body: some View {
    GroupBox("Theme") {
      VStack(alignment: .leading, spacing: 10) {
        Text("Each theme includes paired Light and Dark appearances.")
          .font(.caption)
          .foregroundStyle(.secondary)

        switch LinnetSettingsAppearancePreview.Catalog.bundled {
        case .success(let catalog)
        where LinnetSettingsDocument.ThemeFamily.allCases.allSatisfy({
          catalog.pair(for: $0) != nil
        }):
          themeGrid(catalog)
        case .success, .failure:
          Label(
            "Preview unavailable. The bundled theme data is missing or invalid.",
            systemImage: "exclamationmark.triangle"
          )
          .font(.callout)
          .foregroundStyle(.secondary)
          .accessibilityLabel(Text("Local candidate appearance preview unavailable"))
        }

        Divider()

        Picker("Appearance mode", selection: $mode) {
          Text("System").tag(LinnetSettingsDocument.ThemeMode.system)
          Text("Light").tag(LinnetSettingsDocument.ThemeMode.light)
          Text("Dark").tag(LinnetSettingsDocument.ThemeMode.dark)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("settings.appearance.mode")
        Text(
          "System follows the active text window when macOS exposes its appearance; otherwise it follows the macOS appearance."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .padding(8)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func themeGrid(
    _ catalog: LinnetSettingsAppearancePreview.Catalog
  ) -> some View {
    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
      ForEach(LinnetSettingsDocument.ThemeFamily.allCases, id: \.self) { family in
        let selected = selection == family
        Button {
          selection = family
        } label: {
          themeCard(family: family, catalog: catalog, selected: selected)
        }
        .buttonStyle(.borderless)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(family.settingsTitle))
        .accessibilityIdentifier("settings.appearance.theme.\(family.rawValue)")
        .accessibilityValue(selected ? Text("Selected") : Text("Not selected"))
        .accessibilityHint(Text("Choose this candidate-window theme."))
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
  }

  private func themeCard(
    family: LinnetSettingsDocument.ThemeFamily,
    catalog: LinnetSettingsAppearancePreview.Catalog,
    selected: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      VStack(spacing: 5) {
        themeSample(family, mode: .light, catalog: catalog)
        themeSample(family, mode: .dark, catalog: catalog)
      }

      HStack(spacing: 5) {
        Text(family.settingsTitle)
          .font(.callout.weight(.medium))
          .foregroundStyle(.primary)
        Spacer(minLength: 2)
        if selected {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.tint)
            .accessibilityHidden(true)
        }
      }
    }
    .padding(7)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color(nsColor: NSColor.controlBackgroundColor))
    }
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(
          selected ? Color.accentColor : Color(nsColor: NSColor.separatorColor),
          lineWidth: selected ? 2 : 1
        )
    }
    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  @ViewBuilder
  private func themeSample(
    _ family: LinnetSettingsDocument.ThemeFamily,
    mode: LinnetSettingsDocument.ThemeMode,
    catalog: LinnetSettingsAppearancePreview.Catalog
  ) -> some View {
    let appearance = LinnetSettingsDocument.Appearance(
      fontPoint: 13, themeMode: mode,
      chineseCandidateLayout: .horizontal, englishCandidateLayout: .horizontal,
      pageSize: 3, themeFamily: family)
    if case .success(let preview) = LinnetSettingsAppearancePreview.presentation(
      for: appearance, systemIsDark: mode == .dark, catalog: catalog) {
      let fonts = (
        label: LinnetCandidatePresentation.platformFont(
          fontNames: [], size: preview.labelFontPoint),
        candidate: LinnetCandidatePresentation.platformFont(
          fontNames: [], size: preview.candidateFontPoint))
      HStack(spacing: 8) {
        Image(systemName: preview.isDark ? "moon" : "sun.max")
          .font(.system(size: 10))
          .foregroundStyle(preview.palette.secondary.color)
          .frame(width: 12)
        HStack(spacing: LinnetCandidatePresentation.inlineCandidateSeparatorWidth(font: fonts.candidate)) {
          LinnetSettingsAppearancePreview.candidate("1", "输入", selected: true, preview, fonts: fonts)
          LinnetSettingsAppearancePreview.candidate("2", "候选", selected: false, preview, fonts: fonts)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        LinnetSettingsThemeSurface(
          palette: preview.palette, isTranslucent: preview.isTranslucent, isDark: preview.isDark)
      }
      .clipShape(RoundedRectangle(cornerRadius: preview.cornerRadius))
      .overlay {
        RoundedRectangle(cornerRadius: preview.cornerRadius)
          .stroke(preview.palette.border.color, lineWidth: 0.5)
      }
      .accessibilityHidden(true)
    }
  }
}
