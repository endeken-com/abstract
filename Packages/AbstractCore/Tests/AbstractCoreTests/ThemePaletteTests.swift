import Foundation
import Testing
import AbstractCore

@Suite struct ThemePaletteTests {
    /// The background a foreground sits on, made opaque.
    private func surfaces(in theme: Theme) -> [(PaletteRole, Swatch)] {
        let canvas = PaletteRole.canvas.swatch(in: theme)
        return PaletteRole.backgrounds.map { ($0, $0.swatch(in: theme).over(canvas)) }
    }

    @Test func contrastMatchesWCAG() {
        #expect(abs(Swatch(0x000000).contrast(on: Swatch(0xFFFFFF)) - 21) < 0.01)
        #expect(abs(Swatch(0x777777).contrast(on: Swatch(0xFFFFFF)) - 4.48) < 0.01)
        #expect(Swatch(0xFFFFFF).contrast(on: Swatch(0xFFFFFF)) == 1)
        #expect(Swatch(0xFFFFFF, alpha: 0).contrast(on: Swatch(0x000000)) == 1, "a clear colour is the background")
    }

    @Test func inkTextReadsOnEverySurface() {
        for (background, surface) in surfaces(in: .ink) {
            for role in PaletteRole.foregrounds {
                let ratio = role.swatch(in: .ink).contrast(on: surface)
                let floor = role == .text || role == .prose ? 7.0 : 4.5
                #expect(ratio >= floor, "Ink \(role) on \(background): \(String(format: "%.2f", ratio)):1")
            }
        }
    }

    @Test func inkSyntaxReadsAtSevenToOneOnBlack() {
        let black = PaletteRole.code.swatch(in: .ink)
        #expect(black == Swatch(0x000000))
        for role in PaletteRole.allCases where role.rawValue.hasPrefix("syntax") {
            #expect(role.swatch(in: .ink).contrast(on: black) >= 7, "\(role)")
        }
    }

    @Test func inkTextReadsOnItsWashes() {
        let canvas = PaletteRole.canvas.swatch(in: .ink)
        for wash in [PaletteRole.selection, .hover, .addedWash, .removedWash, .findMatch, .findCurrent] {
            let under = wash.swatch(in: .ink).over(canvas)
            #expect(PaletteRole.text.swatch(in: .ink).contrast(on: under) >= 4.5, "text on \(wash)")
        }
        let accent = PaletteRole.accent.swatch(in: .ink)
        #expect(PaletteRole.onAccent.swatch(in: .ink).contrast(on: accent) >= 7)
    }

    @Test func inkIsTrueBlackWithVisibleBorders() {
        for role in [PaletteRole.canvas, .sidebar, .code] {
            #expect(role.swatch(in: .ink) == Swatch(0x000000), "\(role)")
        }
        let black = Swatch(0x000000)
        let surfaces = [PaletteRole.surface, .surfaceRaised, .inset].map { $0.swatch(in: .ink).luminance }
        #expect(surfaces == surfaces.sorted(), "surfaces step up, back to front")
        // Borders are what separates Ink's surfaces, so they must show.
        #expect(PaletteRole.border.swatch(in: .ink).contrast(on: black) >= 2)
        #expect(PaletteRole.borderStrong.swatch(in: .ink).contrast(on: black) >= 3)
        #expect(PaletteRole.fieldBorderFocused.swatch(in: .ink).contrast(on: black)
                > PaletteRole.fieldBorder.swatch(in: .ink).contrast(on: black))
    }

    @Test func findMatchesAreToldApart() {
        let canvas = PaletteRole.canvas.swatch(in: .ink)
        let match = PaletteRole.findMatch.swatch(in: .ink).over(canvas)
        let current = PaletteRole.findCurrent.swatch(in: .ink).over(canvas)
        #expect(match != current)
        #expect(current.contrast(on: match) >= 1.3)
        #expect(PaletteRole.added.swatch(in: .ink) != PaletteRole.removed.swatch(in: .ink))
    }

    /// Graphite and Paper aren't held to Ink's bar; their ratios are reported.
    @Test func reportsGraphiteAndPaperContrast() {
        for theme in [Theme.graphite, .paper] {
            let canvas = PaletteRole.canvas.swatch(in: theme)
            let lowest = PaletteRole.foregrounds
                .map { ($0, $0.swatch(in: theme).contrast(on: canvas)) }
                .min { $0.1 < $1.1 }
            if let (role, ratio) = lowest {
                print("\(theme): lowest is \(role) at \(String(format: "%.2f", ratio)):1 on the canvas")
                #expect(ratio > 1)
            }
        }
    }

    @Test func everyColourHasAValueInEveryTheme() {
        for role in PaletteRole.allCases {
            let values = Theme.allCases.map { role.swatch(in: $0) }
            #expect(values.allSatisfy { (0...1).contains($0.alpha) && $0.hex <= 0xFFFFFF }, "\(role)")
        }
        #expect(PaletteRole.canvas.swatch(in: .graphite) != PaletteRole.canvas.swatch(in: .ink))
    }

    @Test func choiceResolvesToAThemePerAppearance() {
        #expect(ThemeChoice.allCases == [.system, .graphite, .paper, .ink])
        #expect(ThemeChoice.ink.isDark == true)
        #expect(ThemeChoice.ink.theme(dark: true, increasedContrast: false) == .ink)
        #expect(ThemeChoice.graphite.theme(dark: true, increasedContrast: true) == .graphite,
                "a theme picked by name stays put when Increase contrast is on")
        #expect(ThemeChoice.system.theme(dark: true, increasedContrast: false) == .graphite)
        #expect(ThemeChoice.system.theme(dark: true, increasedContrast: true) == .ink)
        #expect(ThemeChoice.system.theme(dark: false, increasedContrast: true) == .paper)
        // A view forced light (the settings previews) draws in Paper whatever is picked.
        #expect(ThemeChoice.ink.theme(dark: false, increasedContrast: false) == .paper)
    }

    @Test func paperStrengthensItsBordersOnlyUnderMatchSystem() {
        #expect(ThemeChoice.system.strongerBorders(dark: false, increasedContrast: true))
        #expect(!ThemeChoice.paper.strongerBorders(dark: false, increasedContrast: true))
        #expect(!ThemeChoice.system.strongerBorders(dark: true, increasedContrast: true))
        let plain = PaletteRole.border.swatch(in: .paper)
        let strong = PaletteRole.border.swatch(in: .paper, strongerBorders: true)
        #expect(strong.alpha > plain.alpha)
        #expect(PaletteRole.text.swatch(in: .paper, strongerBorders: true) == PaletteRole.text.swatch(in: .paper))
    }
}
