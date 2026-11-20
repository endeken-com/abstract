import AppKit
import AbstractCore

/// Demo mode's sub-task limit check (ABS-214).
/// `ABSTRACT_DEMO_SUBTASKS=<delay>,<limit>,<lowered>` waits, installs and
/// turns on the Delegation plugin from `ABSTRACT_DEMO_SUBTASKS_PLUGIN=<folder>`,
/// sets Sub-tasks per chat to `<limit>`, and calls its `delegate` tool from
/// one chat until it's refused. Then it lowers the setting to `<lowered>`,
/// logs that every sub-task stayed, and asks once more through the plugin
/// and once straight through the app. `ABSTRACT_DEMO_SUBTASKS_SHOT=<png>`
/// saves Settings › Agents.
enum SubtaskLimitProbe {
    static let pluginId = "sh.abstract.delegation"

    static func runIfRequested(_ model: AppModel) {
        guard let spec = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_SUBTASKS"] else { return }
        let parts = spec.split(separator: ",").compactMap { Int($0) }
        guard parts.count == 3 else { return }
        Task {
            try? await Task.sleep(for: .seconds(Double(parts[0])))
            await run(model, limit: parts[1], lowered: parts[2])
        }
    }

    private static func run(_ model: AppModel, limit: Int, lowered: Int) async {
        if let folder = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_SUBTASKS_PLUGIN"] {
            do {
                let record = try model.plugins.install(from: URL(fileURLWithPath: folder), sourceKind: .user, enable: true)
                model.plugins.setAlwaysAllowed(record.id, .chatsCreate, true)
                log("subtasks probe: installed \(record.id) \(record.version)")
            } catch {
                log("subtasks probe: install failed: \(error)"); return
            }
        }
        for _ in 0..<60 where model.pluginBackground?.isRunning(pluginId) != true {
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard model.pluginBackground?.isRunning(pluginId) == true else { log("subtasks probe: plugin not running"); return }
        // Its page loads and says it's ready a moment after it starts.
        try? await Task.sleep(for: .seconds(5))
        guard let parent = model.sessions.first(where: { $0.projectId != nil && $0.branch != nil && $0.parentSessionId == nil }) else {
            log("subtasks probe: no parent chat"); return
        }

        model.subtasksPerChat = limit
        let mac = model.pluginSnapshot(capabilities: [], revision: 0).macs.first { $0.isThisMac }
        log("subtasks probe: setting \(model.subtasksPerChat), snapshot subtasksPerChat \(mac?.subtasksPerChat.map(String.init) ?? "absent")")
        for index in 1...(limit + 1) {
            log("subtasks probe: delegate #\(index): \(await delegate(model, parent: parent.id, index: index))")
        }
        log("subtasks probe: \(children(model, parent.id)) sub-tasks at \(limit)")

        model.subtasksPerChat = lowered
        log("subtasks probe: lowered to \(lowered); \(children(model, parent.id)) sub-tasks stay")
        log("subtasks probe: delegate after lowering: \(await delegate(model, parent: parent.id, index: limit + 2))")
        let project = model.projects.first { $0.id == parent.projectId }
        let key = project.map { PluginSnapshot.projectKey(macId: model.remote.identity.id, projectId: $0.id) }
        do {
            _ = try await model.performPluginAction(PluginAction(capability: .chatsCreate, projectKey: key, text: "One more",
                                                                 parentId: parent.id), pluginName: "Probe")
            log("subtasks probe: app started one over the limit")
        } catch {
            log("subtasks probe: app refused: \(error.localizedDescription)")
        }
        log("subtasks probe: \(children(model, parent.id)) sub-tasks at the end")

        if let path = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_SUBTASKS_SHOT"] {
            model.subtasksPerChat = limit
            // The Debug app shares the real app's defaults: put the tab back.
            let tab = UserDefaults.standard.string(forKey: "settingsTab")
            defer {
                if let tab { UserDefaults.standard.set(tab, forKey: "settingsTab") }
                else { UserDefaults.standard.removeObject(forKey: "settingsTab") }
            }
            UserDefaults.standard.set(SettingsTab.agents.rawValue, forKey: "settingsTab")
            model.isSettingsOpen = true
            try? await Task.sleep(for: .seconds(1.5))
            if let image = WindowCapture.image() {
                try? image.write(to: URL(fileURLWithPath: path))
                log("subtasks probe: shot \(path)")
            }
        }
        log("subtasks probe: done")
    }

    private static func delegate(_ model: AppModel, parent: String, index: Int) async -> String {
        let input: JSONValue = .object(["title": .string("Part \(index)"), "prompt": .string("Do part \(index) of the work."),
                                        "agent": .string("claude")])
        switch await model.pluginBackground?.callTool(pluginId, name: "delegate", input: input, chatId: parent) {
        case .result(let text): return "started: \(text.prefix(60))"
        case .failed(let why): return "refused: \(why)"
        case nil: return "no background host"
        }
    }

    private static func children(_ model: AppModel, _ parent: String) -> Int {
        model.sessions.count { $0.parentSessionId == parent }
    }
}
