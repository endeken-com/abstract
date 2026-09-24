import AppKit
import SwiftUI
import AbstractCore

/// Revund's mark, drawn in the text colour.
enum RevundMark {
    static let image: NSImage = {
        let svg = #"""
        <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="-170.45 0 792 792">
        <path d="M217.2,405.13l-11.56-216.11-7.98-149.14c-1.08,1.76-2.13,3.73-3.13,5.89l-3.05,7.58L26.72,462.69l105.87,78,84.62-135.56Z"/>
        <path d="M142.11,551.79l45.74,151.51,17.55,58.18c1.3.16,2.61.25,3.92.25,3.83,0,7.56-.69,11.1-2.04l7.57-4.15,8.82-4.82c39.19-21.42,71.6-53.24,93.73-92.04l93.83-164.57-197.26-78.52-85.01,136.19Z"/>
        <path d="M128.51,555.02l-100.67-74.17,22.41,138.96,135.83,131.46.04.04.04.04c.06.06.12.13.18.19l2.09,2.01-13.94-46.21-45.98-152.32Z"/>
        <path d="M323.08,163.27l-102.28-124.15-5.02-6.09c-1.6-1.44-3.15-2.37-4.65-2.77l8.45,158.01,11.44,213.85,192.76,76.73-78.8-274c-4.4-15.31-11.77-29.3-21.89-41.59Z"/>
        </svg>
        """#
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
        image.isTemplate = true
        return image
    }()
}

struct RevundGlyph: View {
    var size: CGFloat = 13
    var body: some View {
        Image(nsImage: RevundMark.image).renderingMode(.template).resizable().frame(width: size, height: size)
    }
}

extension RevundFinding.Severity {
    /// Blockers in red; the rest quieter, never a warning orange.
    var color: Color {
        switch self {
        case .blocker: .btRemoved
        case .warning: .btWarning
        case .nitpick: .btTextTertiary
        }
    }
}

// MARK: - Review pane

/// Beside the review's refresh button: review these changes with Revund.
/// Held open, it offers the branch as a whole too.
struct RevundReviewButton: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    /// Review the whole branch rather than what isn't committed.
    let branch: Bool
    @State private var service = RevundService.shared

    var body: some View {
        if service.isInstalled {
            Menu {
                Button("Review Uncommitted Changes") { start(branch: false) }
                Button("Review This Branch") { start(branch: true) }
                if service.isRunning(sessionId) {
                    Divider()
                    Button("Stop Review") { service.cancel(sessionId) }
                }
            } label: {
                if service.isRunning(sessionId) {
                    ProgressView().controlSize(.mini)
                } else {
                    RevundGlyph(size: 13)
                }
            } primaryAction: {
                start(branch: branch)
            }
            .menuStyle(.button)
            .buttonStyle(.icon(size: 26))
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(service.isRunning(sessionId))
            .help(branch ? "Review this branch with Revund (hold for more)" : "Review the uncommitted changes with Revund (hold for more)")
        }
    }

    private func start(branch: Bool) {
        Task { await service.review(sessionId, branch: branch, model: model) }
    }
}

/// Under the review's toolbar while Revund reviews and after: what it found,
/// sending it to the agent, and the findings that aren't on a changed line
/// (the rest sit under their lines in the diff).
struct RevundStrip: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    let review: DiffReview
    @State private var service = RevundService.shared
    @State private var showsOutside = true

    var body: some View {
        if let run = service.run(sessionId) {
            let findings = service.findings(sessionId)
            let outside = outside(findings)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Space.sm) {
                    RevundGlyph(size: 12).foregroundStyle(Color.btTextTertiary)
                    status(run, findings: findings)
                    Spacer(minLength: Space.sm)
                    if case .done = run.phase, !findings.isEmpty {
                        Button("Send to Agent") { service.send(findings, scope: run.scope, to: sessionId, model: model) }
                            .buttonStyle(.bt(.ghost, size: .small))
                            .help("Send every finding still here to this chat's agent to fix")
                    }
                    if service.isRunning(sessionId) {
                        Button("Stop") { service.cancel(sessionId) }.buttonStyle(.bt(.ghost, size: .small))
                    } else {
                        Button { service.clear(sessionId) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.icon(size: 22))
                            .help("Clear Revund's findings")
                    }
                }
                .padding(.leading, Space.md)
                .padding(.trailing, Space.sm)
                .frame(minHeight: 34)
                if !outside.isEmpty {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { showsOutside.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                                .rotationEffect(.degrees(showsOutside ? 90 : 0))
                            Text("\(outside.count) not on a changed line")
                        }
                        .font(.btCaption)
                        .foregroundStyle(Color.btTextTertiary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Space.md)
                    .padding(.bottom, showsOutside ? Space.xs : Space.sm)
                    if showsOutside {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(outside) { RevundFindingCard(finding: $0, sessionId: sessionId, showsLocation: true) }
                        }
                        .padding(.bottom, Space.sm)
                    }
                }
                Hairline()
            }
            .background(Color.btCanvas)
        }
    }

    @ViewBuilder
    private func status(_ run: RevundService.Run, findings: [RevundFinding]) -> some View {
        switch run.phase {
        case .running(let progress):
            ProgressView().controlSize(.mini)
            Text("Reviewing \(run.scope)…").font(.btCallout).foregroundStyle(Color.btTextSecondary)
            if let progress { Text(progress).font(.btCaption).foregroundStyle(Color.btTextTertiary).lineLimit(1) }
        case .done:
            if findings.isEmpty {
                Text("Nothing left to look at in \(run.scope)").font(.btCallout).foregroundStyle(Color.btTextSecondary)
            } else {
                SeverityCounts(findings: findings)
                Text("in \(run.scope)").font(.btCallout).foregroundStyle(Color.btTextTertiary)
            }
            Text(RelativeTime.short(run.at)).font(.btCaption).foregroundStyle(Color.btTextTertiary)
        case .nothing:
            Text("No changes to review in \(run.scope)").font(.btCallout).foregroundStyle(Color.btTextSecondary)
        case .failed(let message):
            Text(message).font(.btCallout).foregroundStyle(Color.btRemoved).lineLimit(2).textSelection(.enabled)
        }
    }

    /// Findings whose line isn't one the diff shows as it is now.
    private func outside(_ findings: [RevundFinding]) -> [RevundFinding] {
        guard !findings.isEmpty else { return [] }
        var shown = Set<String>()
        for file in review.files {
            for row in file.unified {
                if case .line(let line) = row.content, line.kind != .removed, let n = Int(line.new) { shown.insert("\(file.path):\(n)") }
            }
        }
        return findings.filter { !shown.contains($0.location) }
    }
}

/// "1 blocker · 2 warnings", each count in its severity's colour.
struct SeverityCounts: View {
    let findings: [RevundFinding]

    var body: some View {
        HStack(spacing: 4) {
            let present = RevundFinding.Severity.allCases.compactMap { s -> (RevundFinding.Severity, Int)? in
                let n = findings.count { $0.severity == s }
                return n == 0 ? nil : (s, n)
            }
            ForEach(Array(present.enumerated()), id: \.offset) { i, item in
                if i > 0 { Text("·").foregroundStyle(Color.btTextTertiary) }
                Text("\(item.1) \(item.0.rawValue)\(item.1 == 1 ? "" : "s")").foregroundStyle(item.0.color)
            }
        }
        .font(.btCallout.weight(.medium))
    }
}

/// The findings on one line of the diff, under it.
struct RevundInlineFindings: View {
    let sessionId: String
    let ref: LineRef
    @State private var service = RevundService.shared

    var body: some View {
        if ref.side == .new {
            let findings = service.findings(sessionId, path: ref.path, line: ref.line)
            if !findings.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(findings) { RevundFindingCard(finding: $0, sessionId: sessionId) }
                }
            }
        }
    }
}

/// One finding: how bad, which pass, what's wrong and why, Revund's fix, and
/// what to do with it.
struct RevundFindingCard: View {
    @Environment(AppModel.self) private var model
    let finding: RevundFinding
    let sessionId: String
    /// Show where it is (for findings listed away from their line).
    var showsLocation = false
    /// From the pull request: no local review to add it to.
    var local = true
    @State private var service = RevundService.shared
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                RevundGlyph(size: 11).foregroundStyle(Color.btTextTertiary)
                Text(finding.severity.title).font(.btCaption.weight(.semibold)).foregroundStyle(finding.severity.color)
                Text(finding.pass).font(.btCaption).foregroundStyle(Color.btTextTertiary)
                if showsLocation {
                    Button(finding.location) { model.openFile(finding.file, in: sessionId, line: finding.line) }
                        .buttonStyle(.plain)
                        .font(.btMonoSmall)
                        .foregroundStyle(Color.btTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help("Open \(finding.location)")
                }
                Spacer(minLength: Space.sm)
                if local {
                    HStack(spacing: 2) {
                        if finding.line != nil {
                            Button { service.addToReview(finding, sessionId: sessionId, model: model) } label: { Image(systemName: "text.bubble") }
                                .help("Add to your review, to send with your other comments")
                        }
                        Menu {
                            Button("Hide") { service.hide(finding, sessionId: sessionId) }
                            if finding.fingerprint != nil {
                                Button("Don't Flag Again in This Repository…") { askToDismiss() }
                            }
                        } label: {
                            Image(systemName: "xmark")
                        } primaryAction: {
                            service.hide(finding, sessionId: sessionId)
                        }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Hide (hold to tell Revund not to flag it again)")
                    }
                    .buttonStyle(.icon(size: 22))
                    .opacity(hovering ? 1 : 0.55)
                }
            }
            Text(finding.body)
                .font(.btBody)
                .foregroundStyle(Color.btText)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let why = finding.why {
                Text(why)
                    .font(.btCallout)
                    .foregroundStyle(Color.btTextSecondary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let suggest = finding.suggest {
                Text(suggest)
                    .font(.btMonoSmall)
                    .foregroundStyle(Color.btSyntaxPlain)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.btCode, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .help("Revund's suggested fix")
            }
        }
        .btLeadingRule(finding.severity.color)
        .padding(.vertical, Space.sm)
        .padding(.horizontal, Space.md)
        .frame(maxWidth: 620, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.btSurface)
        .onHover { hovering = $0 }
    }

    private func askToDismiss() {
        let alert = NSAlert()
        alert.messageText = "Don't flag this again?"
        alert.informativeText = "Revund keeps the reason with the dismissal for this repository."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Why it doesn't apply"
        alert.accessoryView = field
        alert.addButton(withTitle: "Dismiss")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let reason = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await service.dismiss(finding, reason: reason.isEmpty ? "Doesn't apply" : reason, sessionId: sessionId, model: model) }
    }
}

// MARK: - Composer

/// Above the reply box, beside the branch: Revund at work, or what it found.
struct RevundComposerStatus: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    @State private var service = RevundService.shared

    var body: some View {
        if let run = service.run(sessionId) {
            Button { model.openDiffTab(in: sessionId) } label: {
                HStack(spacing: 5) {
                    RevundGlyph(size: 11)
                    switch run.phase {
                    case .running: Text("Reviewing…")
                    case .done:
                        let findings = service.findings(sessionId)
                        if findings.isEmpty { Text("Revund: clear") } else { SeverityCounts(findings: findings).font(.btChatCaption) }
                    case .nothing, .failed: EmptyView()
                    }
                }
                .font(.btChatCaption)
                .foregroundStyle(Color.btTextTertiary)
            }
            .buttonStyle(.plain)
            .help("Revund reviewed \(run.scope). Open the review.")
            .opacity(run.phase == .nothing || { if case .failed = run.phase { true } else { false } }() ? 0 : 1)
        }
    }
}

// MARK: - Pull request

/// Revund's review of the pull request on GitHub: each pass's check, and the
/// findings its checks annotate. Shown when the repository has the Revund app.
struct RevundPullRequestSection: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let pr: PullRequest
    @State private var service = RevundService.shared
    @State private var showsAll = false

    var body: some View {
        Group {
            if let review = service.pullRequests[session.id] {
                let findings = review.report.findings
                VStack(alignment: .leading, spacing: 2) {
                    SectionHeading(title: "Revund", detail: detail(review)) {
                        if !findings.isEmpty, pr.state == .open {
                            Button("Ask Agent to Fix") {
                                service.send(findings, scope: "pull request #\(pr.number)", to: session.id, model: model)
                            }
                            .buttonStyle(.bt(.ghost, size: .small))
                            .help("Send Revund's findings on the pull request to this chat's agent")
                        }
                    }
                    FlowRow(spacing: Space.md, lineSpacing: 4) {
                        ForEach(review.checks) { check in
                            Button { if let url = check.url { NSWorkspace.shared.open(url) } } label: {
                                HStack(spacing: 4) {
                                    conclusion(check).frame(width: 12)
                                    Text(check.pass).font(.btCallout).foregroundStyle(Color.btTextSecondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(check.title ?? check.name)
                        }
                    }
                    .padding(.vertical, 4)
                    let shown = showsAll ? findings : Array(findings.prefix(5))
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(shown) { RevundFindingCard(finding: $0, sessionId: session.id, showsLocation: true, local: false) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    if findings.count > shown.count {
                        Button("Show all \(findings.count)") { withAnimation(.snappy(duration: 0.2)) { showsAll = true } }
                            .buttonStyle(.plain)
                            .font(.btCaption)
                            .foregroundStyle(Color.btTextTertiary)
                            .padding(.top, Space.xs)
                    }
                }
            }
        }
        .task(id: "\(pr.number)-\(pr.updatedAt?.timeIntervalSince1970 ?? 0)-\(pr.checksSummary.pending)") {
            guard !model.isDemo else { return }
            await service.loadPullRequest(session.id, number: pr.number, model: model)
        }
    }

    private func detail(_ review: RevundPullRequestReview) -> String {
        if review.checks.contains(where: \.isRunning) { return "Reviewing…" }
        return review.report.summary
    }

    @ViewBuilder
    private func conclusion(_ check: RevundCheck) -> some View {
        switch check.conclusion {
        case nil: ProgressView().controlSize(.mini)
        case "success": Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.btTextSecondary)
        case "failure": Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.btRemoved)
        default: Image(systemName: "minus").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.btTextTertiary)
        }
    }
}

// MARK: - Settings

/// Settings › Integrations › Revund: the CLI, its account, and the loop.
struct RevundSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var service = RevundService.shared
    @AppStorage(RevundService.afterTurnKey) private var afterTurn: RevundService.AfterTurn = .off
    @AppStorage(RevundService.sendAtKey) private var sendAt: RevundFinding.Severity = .warning
    @AppStorage(RevundService.keyStoredKey) private var hasKey = false
    @State private var key = ""

    var body: some View {
        Section {
            LabeledContent {
                if service.isInstalled {
                    Text(service.cliVersion ?? "").foregroundStyle(Color.btTextSecondary)
                } else if service.cliChecked {
                    Button("Copy Install Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Revund.install, forType: .string)
                    }
                }
            } label: {
                Text("Revund CLI")
                Text(service.isInstalled ? "Reviews a chat's changes from the Review pane, and after the agent's turns if you like."
                     : "Install it with `\(Revund.install)` to review changes here.")
            }
            if service.isInstalled {
                account
                Picker(selection: $afterTurn) {
                    ForEach(RevundService.AfterTurn.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("When an agent finishes a turn")
                    Text(afterTurn == .fix ? "Findings go back to the agent for up to \(RevundService.maxRounds) rounds, then it's up to you."
                         : "Revund reviews what the turn changed; findings show in the Review pane and above the reply box.")
                }
                if afterTurn == .fix {
                    Picker("Send back", selection: $sendAt) {
                        Text("Blockers").tag(RevundFinding.Severity.blocker)
                        Text("Blockers and warnings").tag(RevundFinding.Severity.warning)
                        Text("Everything").tag(RevundFinding.Severity.nitpick)
                    }
                }
            }
        } header: {
            HStack(spacing: 6) {
                RevundGlyph(size: 12)
                Text("Revund")
            }
        } footer: {
            Text("With the Revund app on a GitHub repository, its checks and findings also show on each chat's pull request.")
                .font(.btCaption)
                .foregroundStyle(Color.btTextTertiary)
        }
        .task { await service.refreshStatus(model.executor) }
    }

    @ViewBuilder
    private var account: some View {
        if hasKey {
            LabeledContent {
                Button("Remove") { service.saveKey(nil) }
            } label: {
                Text("API key")
                Text("Reviews run on your Revund account with the key kept in your keychain.")
            }
        } else if let account = service.account {
            LabeledContent {
                Text([account.email, account.org].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(Color.btTextSecondary)
            } label: {
                Text("Signed in")
                Text("As `revund login` left it. An API key from app.revund.dev/keys works too.")
            }
        } else {
            LabeledContent {
                Button(service.signingIn ? "Waiting for the Browser…" : "Sign In…") { service.signIn(model.executor) }
                    .disabled(service.signingIn)
            } label: {
                Text("Account")
                Text("Not signed in: Revund uses your own model key (ANTHROPIC_API_KEY and the like), if the CLI can see one.")
            }
            if !service.signInOutput.isEmpty {
                Text(service.signInOutput.suffix(4).joined(separator: "\n"))
                    .font(.btMonoSmall)
                    .foregroundStyle(Color.btTextSecondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 6) {
                SecureField("revund_…", text: $key)
                    .btField(compact: true)
                    .onSubmit(saveKey)
                Button("Use Key", action: saveKey)
                    .buttonStyle(.bt(.secondary, size: .small))
                    .disabled(!key.trimmingCharacters(in: .whitespaces).hasPrefix(Revund.keyPrefix))
            }
        }
    }

    private func saveKey() {
        guard key.trimmingCharacters(in: .whitespaces).hasPrefix(Revund.keyPrefix) else { return }
        service.saveKey(key)
        key = ""
    }
}
