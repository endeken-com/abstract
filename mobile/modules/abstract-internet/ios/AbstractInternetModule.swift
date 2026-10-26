import ExpoModulesCore
import AbstractInternetTransport
import Foundation
import UIKit

/// Native handles are owned by one actor; closing a handle interrupts pending reads.
private actor InternetHandles {
    var endpoint: InternetEndpoint?
    var starting: Task<InternetEndpoint, Error>?
    var streams: [String: InternetStream] = [:]
    var stopped = false

    func connect(key: String, host: String, handle: String) async throws -> String {
        guard !stopped, let secret = Data(base64Encoded: key), secret.count == 32 else { throw InternetError.closed }
        if endpoint == nil {
            if starting == nil { starting = Task { try await InternetEndpoint.bind(key: secret) } }
            defer { starting = nil }
            let bound = try await starting!.value
            guard !stopped else { await bound.close(); throw InternetError.closed }
            endpoint = bound
        }
        let ep = endpoint!
        let stream = try await ep.connect(to: host)
        guard !stopped else { stream.close(); throw InternetError.closed }
        streams[handle] = stream
        return ep.id
    }
    func read(handle: String, count: Int) async throws -> String {
        guard (1...(16 << 20)).contains(count), let stream = streams[handle] else { throw InternetError.closed }
        return try await stream.read(count).base64EncodedString()
    }
    func write(handle: String, data: String) async throws {
        guard let bytes = Data(base64Encoded: data), bytes.count <= (16 << 20) + 4,
              let stream = streams[handle] else { throw InternetError.closed }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.write(bytes) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    func close(handle: String) { streams.removeValue(forKey: handle)?.close() }
    func shutdown() async {
        stopped = true
        streams.values.forEach { $0.close() }; streams.removeAll()
        starting?.cancel(); starting = nil
        await endpoint?.close(); endpoint = nil
    }
}

/// The navigation controller showing the top screen, looking through presented and child controllers.
private func topStack(_ controller: UIViewController?) -> UINavigationController? {
    guard let controller else { return nil }
    if let presented = controller.presentedViewController, let stack = topStack(presented) { return stack }
    for child in controller.children.reversed() { if let stack = topStack(child) { return stack } }
    return controller as? UINavigationController
}

public final class AbstractInternetModule: Module {
    private let handles = InternetHandles()
    public func definition() -> ModuleDefinition {
        Name("AbstractInternet")
        Function("hostName") {
            var name = [CChar](repeating: 0, count: 256)
            guard gethostname(&name, name.count) == 0 else { return UIDevice.current.name }
            return String(cString: name)
        }
        // Screens closed from JavaScript slide away as a snapshot that lands slightly off;
        // popping natively, as a back swipe does, slides the live screen.
        AsyncFunction("popToRoot") { () -> Bool in
            let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first(where: \.isKeyWindow)
            guard let stack = topStack(window?.rootViewController) else { return false }
            if stack.transitionCoordinator != nil { return true }
            guard stack.viewControllers.count > 1 else { return false }
            stack.popToRootViewController(animated: true)
            return true
        }.runOnQueue(.main)
        AsyncFunction("connect") { (key: String, host: String, handle: String) in
            try await self.handles.connect(key: key, host: host, handle: handle)
        }
        AsyncFunction("read") { (handle: String, count: Int) in
            try await self.handles.read(handle: handle, count: count)
        }
        AsyncFunction("write") { (handle: String, data: String) in
            try await self.handles.write(handle: handle, data: data)
        }
        AsyncFunction("close") { (handle: String) in await self.handles.close(handle: handle) }
        OnDestroy { Task { await self.handles.shutdown() } }
    }
}
