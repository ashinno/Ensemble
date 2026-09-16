import SwiftUI
import AppKit

enum AppMode: String, CaseIterable, Identifiable {
    case host, receiver
    var id: String { rawValue }
    var label: String { self == .host ? "Host" : "Receiver" }
}

/// Root state: which mode the window is in, plus the two controllers.
///
/// Launch arguments (handy for testing from a terminal):
///   -mode host|receiver   -autostart YES   -source tone   -tcpPort N -udpPort N
///   -connect host:port    -pairing 1234   -name "Display name"   -verbose
@MainActor
final class AppState: ObservableObject {
    static private(set) weak var shared: AppState?

    @Published var mode: AppMode
    let host = HostController()
    let receiver = ReceiverController()

    init() {
        let defaults = UserDefaults.standard
        mode = AppMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .host
        AppState.shared = self
        if defaults.bool(forKey: "autostart") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                switch mode {
                case .host:
                    host.startBroadcasting()
                case .receiver:
                    if let target = defaults.string(forKey: "connect") {
                        let parts = target.split(separator: ":")
                        if parts.count == 2 {
                            receiver.manualHost = String(parts[0])
                            receiver.manualPort = String(parts[1])
                            receiver.connectManual()
                        }
                    }
                }
            }
        }
    }

    func shutdown() {
        host.shutdown()
        receiver.shutdown()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Application finished launching")
        // Developer aid: `-snapshot /path/file.png -snapshotDelay 6` writes a PNG of the window.
        if let path = UserDefaults.standard.string(forKey: "snapshot"), !path.isEmpty {
            let delay = max(1, UserDefaults.standard.double(forKey: "snapshotDelay"))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Self.snapshotMainWindow(to: path) }
        }
    }

    static func snapshotMainWindow(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible }), let view = window.contentView, let layer = view.layer else {
            Log.error("snapshot: no window"); return
        }
        let scale = window.backingScaleFactor
        let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.translateBy(x: 0, y: CGFloat(h))
        ctx.cgContext.scaleBy(x: scale, y: -scale)   // layers are top-left; the bitmap context is bottom-left
        layer.render(in: ctx.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do { try png.write(to: URL(fileURLWithPath: path)); Log.info("snapshot written to \(path) (\(w)×\(h))") }
        catch { Log.error("snapshot: \(error)") }
    }
}

@main
struct EnsembleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState: AppState

    init() {
        Log.info("Ensemble \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") starting (pid \(getpid()))")
        let state = AppState()   // created eagerly so launch-argument automation works even before the window exists
        _appState = StateObject(wrappedValue: state)
    }

    var body: some Scene {
        WindowGroup("Ensemble") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 960, minHeight: 660)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}
