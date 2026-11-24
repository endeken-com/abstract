import SwiftUI
import AppKit
import AbstractCore

/// Settings › Devices › Chat feed (MCP), ABS-217: the read-only endpoint
/// another assistant follows your open chats through.
struct ChatFeedSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var port = ""
    @State private var origins = ""
    @State private var copiedToken = false
    @State private var confirmingRevoke = false
    @FocusState private var focused: Field?

    private enum Field: Hashable { case port, origins }

    var body: some View {
        let feed = model.chatFeed
        Section {
            Toggle(isOn: Binding(get: { feed.settings.enabled }, set: { on in feed.update { $0.enabled = on } })) {
                Text("Let other assistants read your open chats")
                Text(statusLine(feed))
            }
            LabeledContent {
                HStack(spacing: Space.sm) {
                    Text(verbatim: feed.endpointURL).font(.btMonoSmall).foregroundStyle(Color.btTextSecondary).textSelection(.enabled)
                    Button("Copy") { copy(feed.endpointURL) }.buttonStyle(.bt(.secondary, size: .small))
                }
            } label: {
                Text("Address")
                Text("On this Mac only. Reach it from elsewhere through a tunnel.")
            }
            LabeledContent {
                TextField("Port", text: $port, prompt: Text(String(ChatFeedSettings.defaultPort)))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: 100)
                    .focused($focused, equals: .port)
                    .onSubmit(commitPort)
            } label: {
                Text("Port")
                if portIsValid {
                    Text("From 1024 to 65535.")
                } else {
                    Text("Enter a port from 1024 to 65535.").foregroundStyle(Color.btWarning)
                }
            }
            LabeledContent {
                HStack(spacing: Space.sm) {
                    Button(feed.hasToken ? "Rotate token" : "Generate token") {
                        copy(feed.rotateToken())
                        copiedToken = true
                    }.buttonStyle(.bt(.secondary, size: .small))
                    Button("Revoke") { confirmingRevoke = true }
                        .buttonStyle(.bt(.secondary, size: .small))
                        .disabled(!feed.hasToken && !feed.settings.enabled)
                }
            } label: {
                Text("Access token")
                if copiedToken {
                    Text("Copied. Paste it into the assistant now: Abstract won't show it again.").foregroundStyle(Color.btWarning)
                } else {
                    Text(feed.hasToken
                         ? "Kept in the Keychain. Rotating replaces it at once; Revoke also turns the feed off."
                         : "No token yet: nothing can read the feed until you make one.")
                }
            }
            Toggle(isOn: Binding(get: { feed.settings.filter.hidesCodeBlocks },
                                 set: { on in feed.update { $0.filter.hidesCodeBlocks = on } })) {
                Text("Hide code blocks")
                Text("Each one arrives as “[bloco de código: swift, 12 linhas]”.")
            }
            Toggle(isOn: Binding(get: { feed.settings.filter.redactsHealthData },
                                 set: { on in feed.update { $0.filter.redactsHealthData = on } })) {
                Text("Hide health data")
                Text("Best effort: CPF and CNS numbers, birth dates, record numbers, and names after “Paciente”, “Sr.” or “Sra.”. It lowers the risk but can't guarantee no patient data gets through.")
            }
            LabeledContent {
                TextField("Origins", text: $origins, prompt: Text("None"), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .lineLimit(1...4)
                    .frame(maxWidth: 260)
                    .focused($focused, equals: .origins)
                    .onSubmit(commitOrigins)
            } label: {
                Text("Allowed web origins")
                Text("Only for a web page calling it from a browser, one per line. Assistants calling from a server need none.")
            }
        } header: {
            Text("Chat feed (MCP)")
        } footer: {
            SettingsCaption("Read-only: it lists, reads and searches open chats, and nothing else. Archived chats, tool calls, command output and files never leave, and secrets always arrive as [REDACTED]. At most 60 requests a minute.")
        }
        .id("devices.chatFeed")
        .confirmationDialog("Revoke the chat feed's access?", isPresented: $confirmingRevoke) {
            Button("Revoke", role: .destructive) {
                feed.revoke()
                copiedToken = false
            }
        } message: {
            Text("The token stops working at once and the feed turns off. Assistants using it lose access until you make a new token.")
        }
        .onAppear {
            port = String(feed.settings.port)
            origins = feed.settings.allowedOrigins.joined(separator: "\n")
        }
        .onChange(of: focused) { old, _ in
            if old == .port { commitPort() }
            if old == .origins { commitOrigins() }
        }
        .onDisappear {
            commitPort()
            commitOrigins()
            copiedToken = false
        }

        Section {
            if feed.lastCalls.isEmpty {
                Text("No calls yet.").font(.btCallout).foregroundStyle(Color.btTextSecondary)
            } else {
                ForEach(Array(feed.lastCalls.enumerated()), id: \.offset) { _, call in
                    ChatFeedCallRow(call: call)
                }
            }
        } header: {
            Text("Last calls")
        } footer: {
            SettingsCaption("When, which tool, which chat and how it went. The log never keeps what was asked or answered.")
        }
        .id("devices.chatFeedCalls")
        .task {
            while !Task.isCancelled {
                feed.refreshLastCalls()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func statusLine(_ feed: ChatFeedService) -> String {
        switch feed.status {
        case .off: "Off. Nothing listens."
        case .needsToken: "Generate a token to start."
        case .starting: "Starting…"
        case .listening: "On, for requests with the token."
        case .failed(let message): message
        }
    }

    private var portIsValid: Bool {
        let value = port.trimmingCharacters(in: .whitespaces)
        return value.isEmpty || UInt16(value).map { $0 >= 1024 } == true
    }

    private func commitPort() {
        let value = port.trimmingCharacters(in: .whitespaces)
        guard portIsValid else { return }
        let next = value.isEmpty ? ChatFeedSettings.defaultPort : UInt16(value)!
        model.chatFeed.update { $0.port = next }
        port = String(next)
    }

    private func commitOrigins() {
        let list = ChatFeedSettings.origins(typed: origins)
        model.chatFeed.update { $0.allowedOrigins = list }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct ChatFeedCallRow: View {
    let call: ChatFeedLog.Entry

    var body: some View {
        HStack(spacing: Space.md) {
            Text(call.time, format: .dateTime.hour().minute().second())
                .font(.btMonoSmall).foregroundStyle(Color.btTextTertiary)
            Text(verbatim: call.tool ?? call.method ?? "—").font(.btMonoSmall)
            if let chat = call.chatId {
                Text(verbatim: String(chat.prefix(8))).font(.btMonoSmall).foregroundStyle(Color.btTextSecondary)
            }
            Spacer()
            Text(verbatim: outcome).font(.btMonoSmall).foregroundStyle(call.code == 200 && call.toolError != true ? Color.btTextSecondary : Color.btWarning)
            Text(verbatim: "\(call.ms) ms").font(.btMonoSmall).foregroundStyle(Color.btTextTertiary)
        }
    }

    private var outcome: String {
        switch call.code {
        case 200: call.toolError == true ? "error" : "ok"
        case 202: "ok"
        case 401: "401 no token"
        case 403: "403 origin"
        case 429: "429 too many"
        default: String(call.code)
        }
    }
}
