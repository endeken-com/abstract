import AbstractCore
import AVFoundation
import SwiftUI

/// Settings › ABEL (ABS-203): install or remove ABEL, the voice assistant
/// that floats over every app, and how it listens and speaks.
struct AbelSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var status: String?

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    install
                } label: {
                    Text("ABEL")
                    Text(summary)
                }
                if model.abelInstalled, let status {
                    LabeledContent("Now", value: status)
                }
            } header: {
                Text("Abstract's Built-in Expert Listener")
            } footer: {
                Text("ABEL hears and speaks on this Mac only. No audio is sent anywhere or saved, and ABEL asks for the microphone under its own name, so Abstract never does.")
                    .font(.btCaption)
                    .foregroundStyle(Color.btTextTertiary)
            }
            .id("abel.install")

            if model.abelInstalled {
                listening.id("abel.listening")
                speaking.id("abel.speaking")
            }
        }
        .settingsScrollablePane()
        .task(id: model.abelState) {
            model.refreshAbelState()
            status = model.abelInstalled ? await model.abelStatus() : nil
        }
    }

    private var summary: String {
        switch model.abelState {
        case .installed: "A voice assistant that floats over every app. Hold ⌥Space to talk to it."
        case .notInstalled: "A voice assistant that floats over every app: dictate into chats and hear their replies."
        case .needsApproval: "macOS is waiting for you to allow ABEL in System Settings › General › Login Items."
        case let .unavailable(reason): reason
        }
    }

    @ViewBuilder private var install: some View {
        switch model.abelState {
        case .installed:
            Button("Remove ABEL") { model.removeAbel() }
        case .notInstalled:
            Button("Install ABEL") { model.installAbel() }
        case .needsApproval:
            Button("Open Login Items") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
            }
        case .unavailable:
            EmptyView()
        }
    }

    private var listening: some View {
        Section("Listening") {
            Toggle(isOn: binding(\.wakePhrase)) {
                Text("Listen for “Hey Abel”")
                Text("Say “Hey Abel” or “Ei Abel” instead of holding ⌥Space. ABEL pauses while the screen is locked or shared.")
            }
            ForEach(AbelSettings.supportedLanguages, id: \.self) { code in
                Toggle(isOn: Binding(
                    get: { model.abelSettings.languages.contains(code) },
                    set: { on in
                        model.updateAbelSettings { settings in
                            var languages = settings.languages.filter { $0 != code }
                            if on { languages.append(code) }
                            settings.languages = AbelSettings(languages: languages).languages
                        }
                    })) {
                    Text("Understand \(AbelSettings.languageName(code))")
                }
            }
            Toggle(isOn: binding(\.showOrb)) {
                Text("Show the orb")
                Text("When it's hidden, the orb still appears while ABEL listens or answers.")
            }
        }
    }

    private var speaking: some View {
        Section {
            Picker("Voice", selection: binding(\.voice)) {
                Text("The system's voice").tag(String?.none)
                ForEach(Self.voices(model.abelSettings.languages), id: \.id) { voice in
                    Text("\(voice.name) (\(voice.language))").tag(Optional(voice.id))
                }
            }
            LabeledContent("Chats read aloud") {
                Text(spokenChats)
                    .foregroundStyle(Color.btTextSecondary)
            }
        } header: {
            Text("Speaking")
        } footer: {
            Text("Turn on Read Replies Aloud from a chat's menu in the sidebar. ABEL reads the reply's first paragraph and skips code; talking or pressing ⌥Space stops it.")
                .font(.btCaption)
                .foregroundStyle(Color.btTextTertiary)
        }
    }

    private var spokenChats: String {
        let names = model.abelSettings.speakReplies.compactMap { model.session($0)?.name }
        return names.isEmpty ? "None" : names.joined(separator: ", ")
    }

    private func binding<T>(_ key: WritableKeyPath<AbelSettings, T>) -> Binding<T> {
        Binding(get: { model.abelSettings[keyPath: key] },
                set: { value in model.updateAbelSettings { $0[keyPath: key] = value } })
    }

    private static func voices(_ languages: [String]) -> [(id: String, name: String, language: String)] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in languages.contains { voice.language.hasPrefix(String($0.prefix(2))) } }
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
            .map { ($0.identifier, $0.name, $0.language) }
    }
}
