import Foundation
import JavaScriptCore
import SwiftUI

/// Syntax colour for code in the diff and the file reader. It runs the Prism
/// grammars Textual already ships (the same ones that colour code blocks in
/// the chat) in its own JavaScript context, off the main thread.
actor CodeHighlighter {
    static let shared = CodeHighlighter()

    struct Token: Sendable, Hashable {
        let text: String
        let kind: String
    }

    private let context: JSContext?

    init() {
        let script = Bundle.main.url(forResource: "textual_Textual", withExtension: "bundle")
            .flatMap(Bundle.init(url:))?
            .url(forResource: "prism-bundle", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let context = script.flatMap { _ in JSContext() }
        // Grammars Textual's bundle lacks: Makefile, INI, Terraform, Protobuf, Nix, R, Julia…
        let extra = Bundle.main.url(forResource: "prism-extra", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        if let context, let script { Self.load([script, extra].compactMap { $0 }, into: context) }
        self.context = context
    }

    /// Runs the bundles with each grammar (one line each) in its own
    /// try/catch. As shipped, a grammar that throws (Textual's bundle has
    /// SPARQL before the Turtle grammar it extends) stops every grammar after
    /// it, Docker among them; this way only that one is lost.
    private static func load(_ scripts: [String], into context: JSContext) {
        for script in scripts {
            let guarded = script.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                line.hasPrefix("Prism.") || line.hasPrefix("!function") ? "try{" + line + "\n}catch(e){}" : String(line)
            }
            context.evaluateScript(guarded.joined(separator: "\n"))
        }
    }

    /// `code`'s tokens, one array per line; nil when the language is unknown.
    func lines(_ code: String, language: String) -> [[Token]]? {
        guard let context, let tokenize = context.objectForKeyedSubscript("tokenizeCode"),
              let array = tokenize.call(withArguments: [code, language])?.toArray() as? [[String: String]]
        else { return nil }
        let tokens = array.compactMap { t in t["content"].map { Token(text: $0, kind: t["type"] ?? "plain") } }
        if tokens.count == 1, tokens[0].kind == "plain", array.count == 1 { return nil }
        var lines: [[Token]] = [[]]
        for token in tokens {
            let parts = token.text.split(separator: "\n", omittingEmptySubsequences: false)
            for (i, part) in parts.enumerated() {
                if i > 0 { lines.append([]) }
                if !part.isEmpty { lines[lines.count - 1].append(Token(text: String(part), kind: token.kind)) }
            }
        }
        return lines
    }

    /// Prism's name for a file's language, from its name (Dockerfile,
    /// Makefile, Gemfile, dotfiles) or its extension.
    nonisolated static func language(for path: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        if let byName = names[name] { return byName }
        if name.hasPrefix("dockerfile.") || name.hasSuffix(".dockerfile") || name.hasPrefix("containerfile") { return "docker" }
        if name.hasPrefix(".env") { return "bash" }
        if name.hasPrefix("makefile.") { return "makefile" }
        return extensions[(name as NSString).pathExtension]
    }

    private nonisolated static let names: [String: String] = [
        "dockerfile": "docker", "containerfile": "docker",
        "makefile": "makefile", "gnumakefile": "makefile", "bsdmakefile": "makefile",
        "cmakelists.txt": "cmake",
        "gemfile": "ruby", "rakefile": "ruby", "podfile": "ruby", "fastfile": "ruby", "appfile": "ruby", "vagrantfile": "ruby",
        "brewfile": "ruby", "guardfile": "ruby", "dangerfile": "ruby", "capfile": "ruby", "matchfile": "ruby",
        "jenkinsfile": "groovy",
        ".gitignore": "ignore", ".dockerignore": "ignore", ".npmignore": "ignore", ".prettierignore": "ignore",
        ".eslintignore": "ignore", ".hgignore": "ignore", ".vscodeignore": "ignore",
        ".editorconfig": "ini", ".gitconfig": "ini", ".gitmodules": "ini", ".npmrc": "ini", ".pylintrc": "ini", "setup.cfg": "ini",
        ".zshrc": "bash", ".bashrc": "bash", ".profile": "bash", ".bash_profile": "bash", ".zprofile": "bash", ".zshenv": "bash",
        ".bash_aliases": "bash", "procfile": "bash",
        ".babelrc": "json", ".eslintrc": "json", ".prettierrc": "json", ".swcrc": "json",
        "cargo.lock": "toml", "poetry.lock": "toml", "uv.lock": "toml", "pdm.lock": "toml", "pipfile": "toml",
        "yarn.lock": "yaml",
    ]

    private nonisolated static let extensions: [String: String] = [
        "swift": "swift",
        "ts": "typescript", "mts": "typescript", "cts": "typescript", "tsx": "tsx",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "jsx",
        "py": "python", "pyi": "python", "pyw": "python",
        "rb": "ruby", "gemspec": "ruby", "rake": "ruby", "ru": "ruby", "podspec": "ruby", "erb": "erb",
        "rs": "rust", "go": "go", "java": "java", "kt": "kotlin", "kts": "kotlin",
        "gradle": "groovy", "groovy": "groovy",
        "c": "c", "h": "c", "cc": "cpp", "cpp": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp", "hxx": "cpp", "ino": "cpp",
        "m": "objectivec", "mm": "objectivec", "cs": "csharp", "php": "php",
        "sh": "bash", "bash": "bash", "zsh": "bash", "fish": "bash", "env": "bash", "command": "bash",
        "bat": "batch", "cmd": "batch", "ps1": "powershell", "psm1": "powershell",
        "json": "json", "jsonc": "json", "json5": "json", "jsonl": "json", "geojson": "json", "ipynb": "json",
        "webmanifest": "json", "code-workspace": "json",
        "yml": "yaml", "yaml": "yaml", "toml": "toml",
        "ini": "ini", "cfg": "ini", "conf": "ini", "xcconfig": "ini", "properties": "properties",
        "md": "markdown", "markdown": "markdown", "mdx": "markdown",
        "html": "markup", "htm": "markup", "xhtml": "markup", "xml": "markup", "svg": "markup", "plist": "markup",
        "vue": "markup", "svelte": "markup", "astro": "markup", "xib": "markup", "storyboard": "markup",
        "entitlements": "markup", "xcscheme": "markup", "csproj": "markup", "resx": "markup",
        "hbs": "handlebars", "handlebars": "handlebars",
        "css": "css", "scss": "scss", "sass": "sass", "less": "less",
        "sql": "sql", "graphql": "graphql", "gql": "graphql",
        "lua": "lua", "dart": "dart", "scala": "scala", "sc": "scala",
        "ex": "elixir", "exs": "elixir", "erl": "erlang", "hrl": "erlang", "hs": "haskell", "zig": "zig",
        "pl": "perl", "pm": "perl", "clj": "clojure", "cljs": "clojure", "cljc": "clojure", "edn": "clojure",
        "fs": "fsharp", "fsx": "fsharp", "fsi": "fsharp", "ml": "ocaml", "mli": "ocaml",
        "tex": "latex", "sty": "latex", "cls": "latex",
        "mk": "makefile", "cmake": "cmake",
        "tf": "hcl", "tfvars": "hcl", "hcl": "hcl",
        "nix": "nix", "proto": "protobuf", "r": "r", "jl": "julia", "sol": "solidity", "elm": "elm",
        "nim": "nim", "nims": "nim", "vim": "vim", "wgsl": "wgsl", "nginx": "nginx",
        "diff": "diff", "patch": "diff",
    ]
}

/// How token kinds are coloured: One Dark / One Light, the palette Paseo's
/// editor uses.
enum SyntaxStyle {
    static func attributed(_ tokens: [CodeHighlighter.Token]) -> AttributedString {
        var out = AttributedString()
        for token in tokens {
            var piece = AttributedString(token.text)
            if let color = color(token.kind) { piece.foregroundColor = color }
            out += piece
        }
        return out
    }

    static func color(_ kind: String) -> Color? {
        switch kind {
        case "keyword", "atrule", "important", "rule", "directive", "macro", "shebang-keyword": .btSyntaxKeyword
        case "string", "char", "attr-value", "template-string", "url", "regex", "value": .btSyntaxString
        case "number", "boolean", "constant", "symbol", "entity", "attribute", "annotation", "decorator", "label", "unit": .btSyntaxLiteral
        case "class-name", "builtin", "selector", "namespace", "type", "type-annotation", "section-name", "section": .btSyntaxType
        case "function", "function-name", "function-definition", "function-variable", "property-access", "method", "property", "target": .btSyntaxFunction
        case "tag", "key", "variable", "attr-name": .btSyntaxTag
        case "comment", "prolog", "doctype", "cdata", "doc-comment", "shebang", "coord": .btSyntaxComment
        case "operator": .btSyntaxOperator
        case "punctuation": .btSyntaxPlain
        case "inserted": .btAdded
        case "deleted": .btRemoved
        default: nil
        }
    }
}

/// Highlighted lines for one piece of code, loaded once and kept.
@Observable
final class HighlightCache {
    @ObservationIgnored private var loading: Set<String> = []
    private(set) var lines: [String: [AttributedString]] = [:]

    /// Colours `code` (lines joined by "\n") under `key`, once.
    func load(_ key: String, code: String, path: String) async {
        guard lines[key] == nil, !loading.contains(key), let language = CodeHighlighter.language(for: path) else { return }
        loading.insert(key)
        defer { loading.remove(key) }
        guard let tokens = await CodeHighlighter.shared.lines(code, language: language) else { return }
        lines[key] = tokens.map(SyntaxStyle.attributed)
    }
}
