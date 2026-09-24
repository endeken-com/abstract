import SwiftUI

/// Settings › Appearance: the interface's typeface, size and weight.
struct InterfaceFontSection: View {
    @AppStorage(UIFontChoice.familyKey) private var family = UIFontChoice.defaults.family
    @AppStorage(UIFontChoice.sizeKey) private var size = UIFontChoice.defaults.size
    @AppStorage(UIFontChoice.weightKey) private var weight = UIFontChoice.defaults.weight

    var body: some View {
        Section {
            FamilyPicker(family: $family, featured: [(UIFontChoice.defaults.family, "Inter"), (UIFontChoice.system, "SF Pro (System)")],
                         families: FontFamilies.all)
            PointSizeField(title: "Size", value: $size, range: UIFontChoice.sizes, step: 0.5, unit: "pt")
            Picker("Weight", selection: $weight) {
                ForEach(FontWeightChoice.allCases.filter { $0 != .bold }) { Text($0.title).tag($0) }
            }
            Text("Sidebar, tabs, settings and panes. The chat keeps its own text settings below.")
                .font(UIFontChoice(family: family, size: size, weight: weight).font(13, .regular))
                .foregroundStyle(Color.btTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, Space.xs)
        } header: {
            HStack {
                Text("Interface font")
                Spacer()
                ResetButton(visible: family != UIFontChoice.defaults.family || size != UIFontChoice.defaults.size
                            || weight != UIFontChoice.defaults.weight) {
                    for key in [UIFontChoice.familyKey, UIFontChoice.sizeKey, UIFontChoice.weightKey] {
                        UserDefaults.standard.removeObject(forKey: key)
                    }
                }
            }
        }
    }
}

/// Settings › Appearance: the code editor's typeface and how it sets lines.
struct EditorFontSection: View {
    @AppStorage(EditorFontChoice.familyKey) private var family = EditorFontChoice.defaults.family
    @AppStorage(EditorFontChoice.sizeKey) private var size = EditorFontChoice.defaults.size
    @AppStorage(EditorFontChoice.weightKey) private var weight = EditorFontChoice.defaults.weight
    @AppStorage(EditorFontChoice.ligaturesKey) private var ligatures = EditorFontChoice.defaults.ligatures
    @AppStorage(EditorFontChoice.lineHeightKey) private var lineHeight = EditorFontChoice.defaults.lineHeight

    private var choice: EditorFontChoice {
        EditorFontChoice(family: family, size: size, weight: weight, ligatures: ligatures, lineHeight: lineHeight)
    }

    var body: some View {
        Section {
            FamilyPicker(family: $family, featured: [(EditorFontChoice.defaults.family, "JetBrains Mono"), (EditorFontChoice.systemMono, "SF Mono")],
                         families: FontFamilies.monospaced)
            PointSizeField(title: "Size", value: $size, range: EditorFontChoice.sizes, step: 0.5, unit: "pt")
            Picker("Weight", selection: $weight) {
                ForEach(FontWeightChoice.allCases) { Text($0.title).tag($0) }
            }
            Toggle(isOn: $ligatures) {
                Text("Ligatures")
                Text("Draw pairs like != and => as one sign, in fonts that have them.")
            }
            PointSizeField(title: "Line height", value: $lineHeight, range: EditorFontChoice.lineHeights, step: 0.1, unit: "×")
            let font = choice.nsFont
            Text("let ready = items.count != 0 && state >= .loaded\nitems.forEach { item -> Void in render(item) }")
                .font(Font(font))
                .lineSpacing(CGFloat(lineHeight - 1) * font.pointSize)
                .foregroundStyle(Color.btSyntaxPlain)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.btCode, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.vertical, Space.xs)
        } header: {
            HStack {
                Text("Editor font")
                Spacer()
                ResetButton(visible: choice != EditorFontChoice.defaults) {
                    for key in [EditorFontChoice.familyKey, EditorFontChoice.sizeKey, EditorFontChoice.weightKey,
                                EditorFontChoice.ligaturesKey, EditorFontChoice.lineHeightKey] {
                        UserDefaults.standard.removeObject(forKey: key)
                    }
                }
            }
        }
    }
}

/// The bundled faces and the system's first, then every installed family.
private struct FamilyPicker: View {
    @Binding var family: String
    let featured: [(family: String, title: String)]
    let families: [String]

    var body: some View {
        Picker("Family", selection: $family) {
            ForEach(featured, id: \.family) { Text($0.title).tag($0.family) }
            Divider()
            ForEach(families.filter { name in !featured.contains { $0.family == name } }, id: \.self) { Text($0).tag($0) }
        }
    }
}

/// An exact number to type, with a stepper beside it.
private struct PointSizeField: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: clamped, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .btField(compact: true)
                    .frame(width: 58)
                Text(unit).foregroundStyle(Color.btTextTertiary).frame(width: 14, alignment: .leading)
                Stepper(title, value: clamped, in: range, step: step).labelsHidden()
            }
        }
    }

    private var clamped: Binding<Double> {
        Binding(get: { value }, set: { value = (min(max($0, range.lowerBound), range.upperBound) * 10).rounded() / 10 })
    }
}

private struct ResetButton: View {
    let visible: Bool
    let action: () -> Void

    var body: some View {
        if visible {
            Button("Restore Defaults", action: action)
                .buttonStyle(.link)
                .font(.btCallout)
        }
    }
}
