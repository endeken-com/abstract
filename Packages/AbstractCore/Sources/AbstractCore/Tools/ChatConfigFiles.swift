import Foundation

/// The files a chat's agent is started with, in a folder of the chat's own
/// under Abstract's data folder: `agent-config/<chat id>/`. Each launch
/// rewrites them, so they always say what the project says now. Only the
/// user can read them: an MCP server's headers and environment can hold keys.
public enum ChatConfigFiles {
    /// The folder for `chatId` under `root` (`…/Abstract/agent-config`).
    public static func directory(root: String, chatId: String) -> String {
        root + "/" + chatId
    }

    /// Writes `contents` as `name` in `directory` and returns its path, or
    /// nil if it can't, so the caller passes the contents inline instead.
    public static func write(_ contents: String, named name: String, in directory: String) -> String? {
        let path = directory + "/" + name
        let manager = FileManager.default
        do {
            try manager.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            guard manager.createFile(atPath: path, contents: Data(contents.utf8), attributes: [.posixPermissions: 0o600])
            else { return nil }
            // An earlier file keeps its own mode; make sure.
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return path
        } catch {
            return nil
        }
    }

    /// Removes a deleted chat's folder.
    public static func remove(root: String, chatId: String) {
        try? FileManager.default.removeItem(atPath: directory(root: root, chatId: chatId))
    }
}
