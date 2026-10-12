import SwiftUI

// MARK: - Overview
//
// HighlightedTextFragment displays syntax-highlighted code using a two-phase approach.
// Tokenization runs asynchronously and is keyed by content, while highlighting runs
// synchronously on token or environment changes (theme, color scheme, dynamic type).
//
// The presentationIntent is preserved after highlighting so pasteboard formatters can
// reconstruct the block structure when copying code.

struct HighlightedTextFragment: View {
  @Environment(\.textEnvironment) private var textEnvironment

  @State private var model = Model()

  private let content: AttributedSubstring
  private let languageHint: String?
  private let theme: StructuredText.HighlighterTheme

  init(
    _ content: AttributedSubstring,
    languageHint: String?,
    theme: StructuredText.HighlighterTheme
  ) {
    self.content = content
    self.languageHint = languageHint
    self.theme = theme
  }

  var body: some View {
    TextFragment(model.highlightedCode ?? AttributedString(content))
      .foregroundStyle(theme.foregroundColor)
      .task(id: content) {
        await model.tokenize(
          content: content,
          languageHint: languageHint
        )
      }
      .onChange(of: Tuple(model.tokens, textEnvironment, content)) { _, newValue in
        model.highlight(
          tokens: newValue.values.0,
          presentationIntent: content.presentationIntent,
          using: theme,
          environment: newValue.values.1,
          marks: newValue.values.2
        )
      }
  }
}

extension HighlightedTextFragment {
  @MainActor @Observable final class Model {
    var tokens: [CodeToken] = []
    var highlightedCode: AttributedString?

    func tokenize(content: AttributedSubstring, languageHint: String?) async {
      let code = String(content.characters[...])
      tokens = [CodeToken(content: code, type: .plain)]

      if let tokenizer = CodeTokenizer.shared, let languageHint {
        tokens = await tokenizer.tokenize(code: code, language: languageHint)
      }
    }

    func highlight(
      tokens: [CodeToken],
      presentationIntent: PresentationIntent?,
      using theme: StructuredText.HighlighterTheme,
      environment: TextEnvironmentValues,
      marks: AttributedSubstring? = nil
    ) {
      var attributes = AttributeContainer()
      // Re-apply the presentation intent for pasteboard formatters
      attributes.presentationIntent = presentationIntent
      ForegroundColorProperty(theme.foregroundColor)
        .apply(in: &attributes, environment: environment)
      var highlightedCode = AttributedString()

      for token in tokens {
        var content = AttributedString(token.content)
        var tokenAttributes = attributes

        if let tokenProperties = theme.tokenProperties[token.type] {
          tokenProperties.apply(in: &tokenAttributes, environment: environment)
        }

        content.mergeAttributes(tokenAttributes)
        highlightedCode.append(content)
      }

      // Added for Abstract: backgrounds the parser set on the code (find
      // matches) carry over to the highlighted code, which has the same characters.
      if let marks, marks.characters.count == highlightedCode.characters.count {
        typealias Background = AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute
        for (color, range) in marks.runs[Background.self] {
          guard let color else { continue }
          let start = marks.characters.distance(from: marks.startIndex, to: range.lowerBound)
          let length = marks.characters.distance(from: range.lowerBound, to: range.upperBound)
          let lower = highlightedCode.characters.index(highlightedCode.startIndex, offsetBy: start)
          let upper = highlightedCode.characters.index(lower, offsetBy: length)
          highlightedCode[lower..<upper].backgroundColor = color
        }
      }

      self.highlightedCode = highlightedCode
    }
  }
}
