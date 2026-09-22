import SwiftUI
import BacktickCore

/// Consecutive tool calls as a quiet list of one-line rows: no card, no tiles.
/// Long runs collapse to the last few, with the rest one click away.
struct ToolGroupView: View {
    let calls: [ToolCall]
    @State private var showAll = false

    var body: some View {
        let hidden = showAll ? 0 : max(0, calls.count - 4)
        VStack(alignment: .leading, spacing: 2) {
            if hidden > 0 {
                Button { withAnimation(.snappy) { showAll = true } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "ellipsis").font(.system(size: 11)).frame(width: 16)
                        Text("\(hidden) earlier tool call\(hidden == 1 ? "" : "s")")
                    }
                    .font(.btCallout)
                    .foregroundStyle(Color.btTextTertiary)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ForEach(calls.suffix(calls.count - hidden)) { call in
                ToolRow(call: call)
            }
        }
    }
}

private struct ToolRow: View {
    let call: ToolCall
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy(duration: 0.22)) { open.toggle() } } label: {
                HStack(spacing: Space.sm) {
                    Image(systemName: ToolPresentation.symbol(call.name))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(call.result?.isError == true ? Color.btRemoved : Color.btTextTertiary)
                        .frame(width: 16)
                    Text(ToolPresentation.verb(call.name, pending: call.result == nil))
                        .font(.btBodyMedium)
                        .foregroundStyle(Color.btTextSecondary)
                    if let target = ToolPresentation.target(call) {
                        Text(target).font(.btMono).foregroundStyle(Color.btTextSecondary).lineLimit(1).truncationMode(.middle)
                    }
                    if let edit = call.edit {
                        HStack(spacing: 4) {
                            Text("+\(edit.additions)").foregroundStyle(Color.btAdded)
                            Text("−\(edit.deletions)").foregroundStyle(Color.btRemoved)
                        }
                        .font(.btMonoSmall)
                    }
                    if call.result == nil {
                        ProgressView().controlSize(.mini)
                    } else if call.result?.isError == true {
                        Text("failed").font(.btCaption).foregroundStyle(Color.btRemoved)
                    }
                    Spacer(minLength: Space.sm)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.btTextTertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .opacity(hovering || open ? 1 : 0)
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if let edit = call.edit, !open {
                MiniDiff(edit: edit, maxLines: 8)
                    .padding(.leading, 24)
                    .padding(.top, 4)
                    .padding(.bottom, Space.sm)
            }

            if open {
                VStack(alignment: .leading, spacing: Space.md) {
                    Detail(label: "Input") { CodeText(ToolPresentation.inputText(call.input)) }
                    if let edit = call.edit { MiniDiff(edit: edit, maxLines: 80) }
                    if let result = call.result {
                        Detail(label: result.isError ? "Error" : "Output") {
                            OutputText(text: result.output, isError: result.isError)
                        }
                    }
                }
                .padding(.leading, 24)
                .padding(.top, 4)
                .padding(.bottom, Space.md)
                .transition(.opacity)
            }
        }
    }
}

private struct Detail<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(Color.btTextTertiary)
            content()
        }
    }
}

/// Monospaced text set apart by a leading rule instead of a box.
struct CodeText: View {
    let text: String
    /// Off when the surrounding block already carries a rule.
    var ruled = true
    init(_ text: String, ruled: Bool = true) { self.text = text; self.ruled = ruled }
    var body: some View {
        let content = ScrollView(.horizontal, showsIndicators: false) {
            Text(text).font(.btMono).foregroundStyle(Color.btTextSecondary).lineSpacing(2.5).textSelection(.enabled).fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if ruled { content.btLeadingRule() } else { content }
    }
}

private struct OutputText: View {
    let text: String
    let isError: Bool
    @State private var expanded = false
    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        VStack(alignment: .leading, spacing: 4) {
            Text(expanded || lines.count <= 14 ? text : lines.prefix(14).joined(separator: "\n"))
                .font(.btMono)
                .foregroundStyle(isError ? Color.btRemoved : Color.btTextSecondary)
                .lineSpacing(2.5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .btLeadingRule(isError ? Color.btRemoved : Color.btBorderStrong)
            if lines.count > 14 {
                Button(expanded ? "Show less" : "Show \(lines.count - 14) more lines") { expanded.toggle() }
                    .buttonStyle(.plain).font(.btCaption).foregroundStyle(Color.btTextTertiary)
                    .padding(.leading, Space.md + 2)
            }
        }
    }
}

/// Changed lines only, washed green or red, in the flow of the text. No frame.
struct MiniDiff: View {
    let edit: EditPreview
    let maxLines: Int

    var body: some View {
        let lines = Array(edit.lines.prefix(maxLines))
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 0) {
                    Text(line.origin == .added ? "+" : line.origin == .removed ? "−" : " ")
                        .frame(width: 18, alignment: .center)
                        .foregroundStyle(line.origin == .added ? Color.btAdded : line.origin == .removed ? Color.btRemoved : Color.btTextTertiary)
                    Text(line.content.isEmpty ? " " : line.content)
                        .foregroundStyle(line.origin == .context ? Color.btTextTertiary : Color.btText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.btMono)
                .padding(.vertical, 1.5)
                .background(line.origin == .added ? Color.btAddedWash : line.origin == .removed ? Color.btRemovedWash : .clear)
            }
            if edit.lines.count > lines.count {
                Text("\(edit.lines.count - lines.count) more lines").font(.btCaption).foregroundStyle(Color.btTextTertiary)
                    .padding(.leading, 18).padding(.top, 4)
            }
        }
        .textSelection(.enabled)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

enum ToolPresentation {
    static func symbol(_ name: String) -> String {
        switch name.lowercased() {
        case "read", "notebookread": "doc.text"
        case "write": "doc.badge.plus"
        case "edit", "multiedit", "notebookedit", "apply_patch", "file_change": "pencil"
        case "bash", "shell", "command_execution": "terminal"
        case "grep", "glob", "search": "magnifyingglass"
        case "webfetch", "websearch", "web_search": "globe"
        case "todowrite", "todo_list": "checklist"
        case "task", "agent": "person.2"
        default: "wrench.and.screwdriver"
        }
    }

    static func verb(_ name: String, pending: Bool = false) -> String {
        if pending {
            switch name.lowercased() {
            case "read": return "Reading"
            case "write": return "Creating"
            case "edit", "multiedit": return "Editing"
            case "bash", "shell", "command_execution": return "Running"
            case "grep", "websearch", "web_search": return "Searching"
            case "glob": return "Listing"
            case "webfetch": return "Fetching"
            case "task", "agent": return "Delegating"
            default: break
            }
        }
        return switch name.lowercased() {
        case "read": "Read"
        case "write": "Created"
        case "edit", "multiedit": "Edited"
        case "bash", "shell", "command_execution": "Ran"
        case "grep": "Searched"
        case "glob": "Listed"
        case "webfetch": "Fetched"
        case "websearch", "web_search": "Searched the web"
        case "task", "agent": "Delegated"
        case "todowrite", "todo_list": "Updated plan"
        default: name
        }
    }

    static func target(_ call: ToolCall) -> String? {
        guard case .object(let o) = call.input else { return nil }
        for key in ["file_path", "path", "notebook_path", "command", "pattern", "url", "query", "description"] {
            if let v = o[key]?.string, !v.isEmpty {
                if key == "command" || key == "description" || key == "query" || key == "pattern" { return v }
                return v.split(separator: "/").suffix(3).joined(separator: "/")
            }
        }
        return nil
    }

    static func inputText(_ input: JSONValue) -> String {
        if case .object(let o) = input, let cmd = o["command"]?.string, o.count <= 3 { return cmd }
        return input.pretty()
    }
}
