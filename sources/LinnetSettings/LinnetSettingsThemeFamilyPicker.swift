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
  private let columns = [GridItem(.adaptive(minimum: 124, maximum: 176), spacing: 10)]
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
        if let pair = catalog.pair(for: family) {
          let selected = selection == family
          Button {
            selection = family
          } label: {
            themeCard(family: family, pair: pair, selected: selected)
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
  }

  private func themeCard(
    family: LinnetSettingsDocument.ThemeFamily,
    pair: LinnetSettingsAppearancePreview.Catalog.ThemePair,
    selected: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 0) {
        themeHalf(pair.light, isDark: false)
        themeHalf(pair.dark, isDark: true)
      }
      .frame(height: 54)
      .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .stroke(Color(nsColor: NSColor.separatorColor), lineWidth: 0.5)
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

  private func themeHalf(
    _ scheme: LinnetSettingsAppearancePreview.Catalog.Scheme,
    isDark: Bool
  ) -> some View {
    ZStack(alignment: .topTrailing) {
      LinnetSettingsThemeSurface(
        palette: scheme.palette,
        isTranslucent: scheme.isTranslucent,
        isDark: isDark
      )
      Capsule()
        .fill(scheme.palette.selectedPrimary.color)
        .frame(width: 24, height: 5)
        .padding(6)
        .background {
          if scheme.selectionStyle == .tile {
            RoundedRectangle(
              cornerRadius: scheme.highlightedCornerRadius,
              style: .continuous
            )
            .fill(scheme.palette.selectedBackground.color)
          }
        }
        .overlay(alignment: .bottom) {
          if scheme.selectionStyle == .underline {
            Rectangle().fill(scheme.palette.selectedBackground.color).frame(height: 2)
          }
        }
        .overlay(alignment: .leading) {
          if scheme.selectionStyle == .bar {
            RoundedRectangle(cornerRadius: 1)
              .fill(scheme.palette.selectedBackground.color).frame(width: 2)
          }
        }
        .accessibilityHidden(true)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
