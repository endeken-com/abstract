import SwiftUI

/// Every text input in Abstract looks the same: one steady fill that never
/// changes, one corner radius, and a border that is the only thing that
/// answers focus.
enum Field {
    static let radius: CGFloat = 10
    static let height: CGFloat = 30
    static let compactHeight: CGFloat = 24
    static let inset: CGFloat = 10
    /// Drawn weight of typed text where a field keeps the system font, to
    /// match `BTFont`'s one-step-lighter regular.
    static let weight: Font.Weight = .regular
}

extension View {
    /// The shared input chrome. Pass whether the field has focus.
    func btFieldChrome(focused: Bool, radius: CGFloat = Field.radius) -> some View {
        background(Color.btField, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(focused ? Color.btFieldBorderFocused : Color.btFieldBorder, lineWidth: 1)
            )
            .animation(.snappy(duration: 0.12), value: focused)
    }
}

/// Turns a TextField into the shared single-line style, tracking its own
/// focus. For fields that already bind focus, use `btFieldChrome(focused:)`.
private struct BTFieldModifier: ViewModifier {
    let compact: Bool
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .fontWeight(Field.weight)
            .focused($focused)
            .padding(.horizontal, compact ? 8 : Field.inset)
            .frame(height: compact ? Field.compactHeight : Field.height)
            .btFieldChrome(focused: focused)
    }
}

extension View {
    func btField(compact: Bool = false) -> some View { modifier(BTFieldModifier(compact: compact)) }
}

/// A single-line text field in the shared style.
struct BTTextField: View {
    let title: String
    @Binding var text: String
    var prompt: String? = nil
    var mono = false
    var compact = false
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    init(_ title: String, text: Binding<String>, prompt: String? = nil, mono: Bool = false, compact: Bool = false,
         onSubmit: @escaping () -> Void = {}) {
        self.title = title; _text = text; self.prompt = prompt; self.mono = mono; self.compact = compact; self.onSubmit = onSubmit
    }

    var body: some View {
        TextField(title, text: $text, prompt: prompt.map { Text($0) })
            .textFieldStyle(.plain)
            .font(mono ? BTFont.mono(compact ? 11.5 : 12.5) : (compact ? .btInputCompact : .btInput))
            .foregroundStyle(Color.btText)
            .focused($focused)
            .onSubmit(onSubmit)
            .padding(.horizontal, compact ? 8 : Field.inset)
            .frame(height: compact ? Field.compactHeight : Field.height)
            .btFieldChrome(focused: focused)
    }
}

/// A multi-line editor in the shared style; grows from `minHeight`.
struct BTTextEditor: View {
    @Binding var text: String
    var placeholder: String? = nil
    var mono = false
    var minHeight: CGFloat = 72
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(mono ? BTFont.mono(12.5) : .btInput)
            .foregroundStyle(Color.btText)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .padding(.horizontal, Field.inset - 5) // TextEditor insets its text by ~5pt itself
            .padding(.vertical, 8)
            .frame(minHeight: minHeight, alignment: .topLeading)
            .overlay(alignment: .topLeading) {
                if text.isEmpty, let placeholder {
                    Text(placeholder)
                        .font(mono ? BTFont.mono(12.5) : .btInput)
                        .foregroundStyle(Color.btTextTertiary)
                        .padding(.horizontal, Field.inset)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .btFieldChrome(focused: focused)
    }
}
