import SwiftUI
import AbstractCore

/// The invocation saved with one turn, with secrets already removed in the log.
struct LaunchDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    let record: LaunchRecord

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack {
                Text("How this turn started").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    detail("Agent", [record.binary, record.version].compactMap { $0 }.joined(separator: " · "))
                    detail("Arguments", displayArgs.map(quote).joined(separator: " "))
                    if let prompt = record.prompt, !prompt.isEmpty {
                        detail("Prompt", prompt.count > 240 ? String(prompt.prefix(240)) + "…" : prompt)
                    }
                    detail("Folder", record.cwd)
                    detail("Model", record.model ?? "Agent default")
                    detail("Effort", record.effort ?? "Agent default")
                    if !record.env.isEmpty {
                        detail("Environment", record.env.sorted { $0.key < $1.key }
                            .map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Copy as shell command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.shellCommand, forType: .string)
            }
        }
        .padding(Space.lg)
        .frame(width: 620, height: 470)
    }

    private var displayArgs: [String] {
        guard let prompt = record.prompt, !prompt.isEmpty,
              let last = record.args.last, last.contains(prompt) else { return record.args }
        return Array(record.args.dropLast())
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).font(.btChatCaption).foregroundStyle(Color.btTextSecondary)
            Text(value.isEmpty ? "—" : value).font(.btChatMonoSmall).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
