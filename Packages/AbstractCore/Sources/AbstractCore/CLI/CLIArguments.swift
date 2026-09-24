import Foundation

/// A command's options: `--name value` or `--name=value`, plus bare switches.
/// Every option is required unless it's a switch; anything else is an error.
struct CLIArguments {
    private var values: [String: String] = [:]
    private var switches: Set<String> = []

    init(_ tokens: [String], options: [String], switches known: [String] = []) throws {
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            guard token.hasPrefix("--"), token.count > 2 else {
                throw CLIError(.invalidArguments, "Unexpected argument “\(token)”. Options look like --name value.")
            }
            var name = String(token.dropFirst(2))
            var value: String?
            if let eq = name.firstIndex(of: "=") {
                value = String(name[name.index(after: eq)...])
                name = String(name[..<eq])
            }
            if known.contains(name) {
                guard value == nil else { throw CLIError(.invalidArguments, "--\(name) takes no value.") }
                guard switches.insert(name).inserted else { throw CLIError(.invalidArguments, "--\(name) is given twice.") }
                i += 1
                continue
            }
            guard options.contains(name) else { throw Self.unknown(name) }
            if value == nil {
                guard i + 1 < tokens.count else { throw CLIError(.invalidArguments, "--\(name) needs a value.") }
                value = tokens[i + 1]
                i += 1
            }
            guard values[name] == nil else { throw CLIError(.invalidArguments, "--\(name) is given twice.") }
            values[name] = value
            i += 1
        }
        for name in options where values[name] == nil {
            throw CLIError(.invalidArguments, "--\(name) is required.")
        }
    }

    /// A required option's value, never empty.
    func value(_ name: String) throws -> String {
        guard let value = values[name], !value.isEmpty else { throw CLIError(.invalidArguments, "--\(name) is empty.") }
        return value
    }

    func isSet(_ name: String) -> Bool { switches.contains(name) }

    private static func unknown(_ name: String) -> CLIError {
        switch name {
        // Text never goes on the command line, where it would land in shell history and `ps`.
        case "prompt": CLIError(.invalidArguments, "Prompts are read from a file or stdin: use --prompt-file <path|->.")
        case "text": CLIError(.invalidArguments, "Text is read from a file or stdin: use --text-file <path|->.")
        default: CLIError(.invalidArguments, "Unknown option --\(name).")
        }
    }
}

/// A prompt or message from `--prompt-file`/`--text-file`: a path, or `-` for
/// stdin. Trimmed like the app's composer; never empty.
func readTextArgument(_ path: String, option: String, stdin: () -> Data) throws -> String {
    let data: Data
    if path == "-" {
        data = stdin()
    } else {
        guard let contents = FileManager.default.contents(atPath: path) else {
            throw CLIError(.invalidArguments, "Can't read \(path) (--\(option)).")
        }
        data = contents
    }
    guard let text = String(data: data, encoding: .utf8) else {
        throw CLIError(.invalidArguments, "--\(option) isn't UTF-8 text.")
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw CLIError(.invalidArguments, "--\(option) is empty.") }
    return trimmed
}
