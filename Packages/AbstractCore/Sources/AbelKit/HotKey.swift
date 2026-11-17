import Carbon.HIToolbox
import Foundation

/// Push-to-talk: a system-wide shortcut, held down. A Carbon hot key tells
/// press from release and needs no permission at all (ABS-202 §1), unlike
/// watching the keyboard, which needs Input Monitoring.
@MainActor
public final class HotKey {
    public struct Shortcut: Sendable, Equatable {
        public var keyCode: UInt32
        public var modifiers: UInt32
        public var title: String

        public init(keyCode: UInt32, modifiers: UInt32, title: String) {
            self.keyCode = keyCode; self.modifiers = modifiers; self.title = title
        }

        /// Escape, alone: taken only while ABEL listens or speaks.
        public static let escape = Shortcut(keyCode: UInt32(kVK_Escape), modifiers: 0, title: "Esc")

        /// ⌥Space.
        public static let optionSpace = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), title: "⌥Space")
    }

    public var onPress: (() -> Void)?
    public var onRelease: (() -> Void)?
    public let shortcut: Shortcut
    private var ref: EventHotKeyRef?
    private static var live: [UInt32: HotKey] = [:]
    private static var nextId: UInt32 = 1
    private let id: UInt32

    public init(_ shortcut: Shortcut = .optionSpace) {
        self.shortcut = shortcut
        id = Self.nextId
        Self.nextId += 1
    }

    /// Registers the shortcut; false when another app already holds it.
    @discardableResult
    public func register() -> Bool {
        guard ref == nil else { return true }
        Self.installHandlerOnce()
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                         EventHotKeyID(signature: OSType(0x4142_454C), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { ref = nil; return false }
        Self.live[id] = self
        return true
    }

    public func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.live[id] = nil
    }

    private static var installed = false

    private static func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            let kind = GetEventKind(event)
            let id = hotKey.id
            MainActor.assumeIsolated {
                guard let key = HotKey.live[id] else { return }
                if kind == UInt32(kEventHotKeyPressed) { key.onPress?() } else { key.onRelease?() }
            }
            return noErr
        }, types.count, &types, nil, nil)
    }
}
