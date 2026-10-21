import Foundation

/// The files a chat's agent is started with, in a folder of the chat's own
/// under Abstract's data folder: `agent-config/<chat id>/`. Each launch
/// rewrites them, so they always say what the project says now.
public enum ChatConfigFiles {
    /// The folder for `chatId` under `root` (`…/Abstract/agent-config`).
    public static func directory(root: String, chatId: String) -> String {
        root + "/" + chatId
    }

    /// Removes a deleted chat's folder.
    public static func remove(root: String, chatId: String) {
        try? FileManager.default.removeItem(atPath: directory(root: root, chatId: chatId))
    }
}
