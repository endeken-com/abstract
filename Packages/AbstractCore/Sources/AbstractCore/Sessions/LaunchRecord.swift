import Foundation
import Synchronization

/// The safe, replayable part of the exact process invocation for one turn.
/// Never persist a raw LaunchSpec: its arguments and environment can hold credentials.
public struct LaunchRecord: Sendable, Hashable, Codable {
    public static let hidden = "••••"

    public var binary: String
    public var version: String?
    public var args: [String]
    public var cwd: String
    public var env: [String: String]
    public var prompt: String?
    public var model: String?
    public var effort: String?
    public var stdinInitial: String?

    public init(spec: LaunchSpec, prompt: String?, model: String?, effort: String?,
                binary: String? = nil, version: String? = nil) {
        let secretNames = ["KEY", "TOKEN", "SECRET", "PASSWORD"]
        let secretValues = spec.env.compactMap { name, value in
            secretNames.contains(where: { name.uppercased().contains($0) }) && !value.isEmpty ? value : nil
        }.sorted { $0.count > $1.count }
        func safe(_ value: String) -> String {
            var result = value
            for secret in secretValues { result = result.replacingOccurrences(of: secret, with: Self.hidden) }
            return SecretMasking.maskTokens(result).replacingOccurrences(of: SecretMasking.replacement, with: Self.hidden)
        }
        self.binary = safe(binary ?? spec.command)
        self.version = version.map(safe)
        var previousWasSecretFlag = false
        self.args = spec.args.map { argument in
            defer { previousWasSecretFlag = argument.hasPrefix("-") && secretNames.contains(where: { argument.uppercased().contains($0) })
                && !argument.contains("=") }
            if previousWasSecretFlag { return Self.hidden }
            if let equals = argument.firstIndex(of: "="),
               secretNames.contains(where: { argument[..<equals].uppercased().contains($0) }) {
                return safe(String(argument[..<equals])) + "=" + Self.hidden
            }
            return safe(argument)
        }
        self.cwd = safe(spec.cwd)
        self.env = spec.env.mapValues(safe)
        for name in spec.env.keys where secretNames.contains(where: { name.uppercased().contains($0) }) {
            self.env[name] = Self.hidden
        }
        self.prompt = prompt.map(safe)
        self.model = model.map(safe)
        self.effort = effort.map(safe)
        self.stdinInitial = spec.stdinInitial.map(safe)
    }

    public init?(_ line: OutputLine) {
        guard line.stream == .launch,
              let value = try? JSONDecoder().decode(Self.self, from: Data(line.line.utf8)) else { return nil }
        self = value
    }

    public var line: OutputLine {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return OutputLine(stream: .launch, line: String(decoding: data, as: UTF8.self))
    }

    /// Quoted for zsh/sh. Hidden credentials are omitted, including arguments
    /// that contained one; a copied command never includes the placeholder.
    public var shellCommand: String {
        let environment = env.sorted { $0.key < $1.key }.compactMap { key, value -> String? in
            guard !value.contains(Self.hidden) else { return nil }
            return "\(key)=\(Self.quote(value))"
        }
        var copiedArgs: [String] = []
        for arg in args {
            if arg.contains(Self.hidden) {
                if copiedArgs.last?.hasPrefix("-") == true, copiedArgs.last != "--" { copiedArgs.removeLast() }
            } else {
                copiedArgs.append(arg)
            }
        }
        let words = ([binary] + copiedArgs).filter { !$0.contains(Self.hidden) }.map(Self.quote)
        let command = (["env"] + environment + words).joined(separator: " ")
        let invocation: String
        if let stdinInitial, !stdinInitial.contains(Self.hidden) {
            invocation = "printf %s \(Self.quote(stdinInitial)) | \(command)"
        } else {
            invocation = command
        }
        return "cd \(Self.quote(cwd)) && \(invocation)"
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Resolve and inspect a binary once per path. A failed or slow version probe
/// leaves the version blank; it must never stop the agent from starting.
public enum LaunchInspection {
    private static let versions = Mutex<[String: String]>([:])

    public static func record(spec: LaunchSpec, prompt: String?, model: String?, effort: String?) -> LaunchRecord {
        let path = LocalExecutor.resolveExecutable(spec.command, searchPath: spec.env["PATH"] ?? LoginShell.blockingPath(),
                                                   home: LocalExecutor.shared.homeDirectory, cwd: spec.cwd) ?? spec.command
        let cached = versions.withLock { $0[path] }
        let version = cached ?? probeVersion(path)
        if let version { versions.withLock { $0[path] = version } }
        return LaunchRecord(spec: spec, prompt: prompt, model: model, effort: effort, binary: path, version: version)
    }

    private static func probeVersion(_ binary: String) -> String? {
        guard binary.hasPrefix("/") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); return nil }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).first.map(String.init)
    }
}
