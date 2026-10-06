import SwiftUI
import ImageIO
import AbstractCore

/// The agent's reply, with the files it names in the chat's worktree as
/// links that open them in a Files preview tab. Paths are linked once the
/// reply has finished arriving, so the text doesn't shift while it streams.
struct ReplyProse: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    let text: String
    var streaming: Bool?
    @State private var linked: String?

    var body: some View {
        AgentProse(markdown: streaming == nil ? linked ?? text : text, streaming: streaming)
            .environment(\.openURL, OpenURLAction { url in
                guard let target = FilePathLinks.target(url) else { return .systemAction }
                model.openFile(target.path, in: sessionId, line: target.line, preview: true)
                return .handled
            })
            .task(id: streaming == nil ? text : nil) {
                guard streaming == nil, let root = model.session(sessionId)?.worktreePath, !root.isEmpty else { return }
                let candidates = FilePathLinks.candidates(in: text, root: root)
                guard !candidates.isEmpty else { return }
                let files = await FileExistence.shared.files(candidates, root: root, in: sessionId, executor: model.executor(for: sessionId))
                guard !Task.isCancelled else { return }
                linked = files.isEmpty ? nil : FilePathLinks.link(text, root: root, files: files)
            }
    }
}

/// Which paths in a worktree are files, remembered briefly: replies are
/// redrawn as they scroll by, and on a paired Mac each question is a round trip.
@MainActor
final class FileExistence {
    static let shared = FileExistence()
    private var known: [String: (isFile: Bool, at: Date)] = [:]
    private static let lifetime: TimeInterval = 20

    func files(_ paths: [String], root: String, in sessionId: String, executor: any Executor) async -> Set<String> {
        let now = Date()
        var result: Set<String> = []
        var unknown: [String] = []
        for path in paths {
            if let entry = known[Self.key(sessionId, path)], now.timeIntervalSince(entry.at) < Self.lifetime {
                if entry.isFile { result.insert(path) }
            } else {
                unknown.append(path)
            }
        }
        guard !unknown.isEmpty else { return result }
        let answers = await withTaskGroup(of: (String, Bool).self) { group in
            for path in unknown {
                let absolute = FileIndex.join(root, path)
                group.addTask { (path, await executor.fileInfo(absolute).map { !$0.isDirectory } ?? false) }
            }
            var answers: [(String, Bool)] = []
            for await answer in group { answers.append(answer) }
            return answers
        }
        for (path, isFile) in answers {
            known[Self.key(sessionId, path)] = (isFile, now)
            if isFile { result.insert(path) }
        }
        return result
    }

    private static func key(_ sessionId: String, _ path: String) -> String { sessionId + "\u{0}" + path }
}

// MARK: - Thumbnails

/// A small picture under a tool call that read, wrote or edited an image:
/// what Claude saw when its result carries the image, otherwise the file as
/// it is now. Clicking it opens the file in a Files preview tab.
struct ToolThumbnail: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    let call: ToolCall
    @State private var image: NSImage?

    private static let box = CGSize(width: 180, height: 110)

    var body: some View {
        Group {
            if let image {
                let scale = min(1, Self.box.width / image.size.width, Self.box.height / image.size.height)
                Button(action: open) {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: image.size.width * scale, height: image.size.height * scale)
                        .background(Color.btInset)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.btBorder))
                }
                .buttonStyle(.plain)
                .help(path == nil ? "" : "Open in Files")
                .padding(.top, 2)
                .padding(.bottom, Space.xs)
            } else {
                // Something to hang the task on while the picture loads.
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .task(id: "\(call.id) \(call.result != nil)") { image = await load() }
    }

    private var path: String? { ToolPresentation.path(call) }

    private func open() {
        guard let path else { return }
        model.openFile(ToolPresentation.relative(path, root: model.session(sessionId)?.worktreePath), in: sessionId, preview: true)
    }

    private func load() async -> NSImage? {
        if let picture = call.result?.images.first {
            return await Self.thumbnail(picture.data)
        }
        guard let path, ImageFacts.isImageName(path), let root = model.session(sessionId)?.worktreePath else { return nil }
        let absolute = path.hasPrefix("/") ? path : FileIndex.join(root, path)
        let executor = model.executor(for: sessionId)
        guard let info = await executor.fileInfo(absolute), !info.isDirectory, info.size <= EditorDocument.readLimit,
              let data = try? await executor.readData(absolute) else { return nil }
        return await Self.thumbnail(data)
    }

    /// Scaled down by ImageIO off the main thread; PDF and SVG through `NSImage`.
    @concurrent
    nonisolated private static func thumbnail(_ data: Data) async -> NSImage? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 360] as CFDictionary
        if let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetType(source) != nil,
           let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }

    /// Whether a call gets a thumbnail: it read, wrote or edited an image,
    /// or its result carried one.
    static func shows(_ call: ToolCall) -> Bool {
        let kind = ToolKind(call.name)
        guard kind == .explore || kind == .edit || kind == .other else { return false }
        if call.result?.images.isEmpty == false { return true }
        guard kind != .other, let path = ToolPresentation.path(call) else { return false }
        return ImageFacts.isImageName(path) && call.result?.isError != true
    }
}
