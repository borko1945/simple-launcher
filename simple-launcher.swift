import SwiftUI
import AppKit

// MARK: - Models & Logic
struct AppModel: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
    let icon: NSImage
    let lastLaunched: Double
}

class LauncherViewModel: ObservableObject {
    @Published var apps: [AppModel] = []
    @Published var searchText = ""
    private let historyKey = "launcher.history"
    
    init() {
        // Start loading immediately upon initialization
        load()
    }
    
    var filtered: [AppModel] {
        searchText.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
    
    func load() {
        // Run heavy I/O (scanning & icon generation) on background thread
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }
            
            // Load History
            let history = UserDefaults.standard.dictionary(forKey: self.historyKey) as? [String: Double] ?? [:]
            let paths = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
            
            // Scan & Map
            let found = paths.map { URL(fileURLWithPath: $0) }
                .flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] }
                .filter { $0.pathExtension == "app" }
                .compactMap { url -> AppModel? in
                    let icon = NSWorkspace.shared.icon(forFile: url.path)
                    // Request high-res icon (512pt) so it scales down sharply on Retina displays
                    icon.size = NSSize(width: 512, height: 512)
                    
                    return AppModel(
                        name: url.deletingPathExtension().lastPathComponent,
                        url: url,
                        icon: icon,
                        lastLaunched: history[url.path] ?? 0
                    )
                }
                .sorted {
                    // Sort by MRU (Most Recently Used), then Alphabetical
                    if $0.lastLaunched != $1.lastLaunched { return $0.lastLaunched > $1.lastLaunched }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            
            // Update UI on Main Thread
            DispatchQueue.main.async { self.apps = found }
        }
    }
    
    func launch(_ app: AppModel) {
        // Update history
        var history = UserDefaults.standard.dictionary(forKey: historyKey) as? [String: Double] ?? [:]
        history[app.url.path] = Date().timeIntervalSince1970
        UserDefaults.standard.set(history, forKey: historyKey)
        
        // Open App & Terminate Launcher
        NSWorkspace.shared.open(app.url)
        NSApp.terminate(nil)
    }
}

// MARK: - Views
struct ContentView: View {
    @StateObject var vm = LauncherViewModel()
    @FocusState var focus: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Search Bar
            TextField("Search...", text: $vm.searchText)
                .textFieldStyle(.plain)
                .font(.largeTitle.weight(.light)) // Large, distinct input font
                .focused($focus)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 10)
                .onSubmit { if let first = vm.filtered.first { vm.launch(first) } }
                .onExitCommand { NSApp.terminate(nil) } // ESC to quit
            
            // App Grid
            ScrollView {
                // Layout: Ultra-tight grid (spacing: 3)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 3)], spacing: 3) {
                    ForEach(vm.filtered) { app in
                        Button(action: { vm.launch(app) }) {
                            VStack(spacing: 0) {
                                Image(nsImage: app.icon)
                                    .resizable()
                                    .frame(width: 80, height: 80)
                                Text(app.name)
                                    .font(.title3) // Dynamic system font, readable but compact
                                    .lineLimit(1)
                                    .foregroundColor(.primary.opacity(0.9))
                            }
                            .padding(3)
                            .frame(maxWidth: .infinity)
                            // Selection Highlight
                            .background(vm.filtered.first?.id == app.id ? Color.accentColor.opacity(0.2) : .clear)
                            .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                        .controlSize(.large)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        // Window Background & Shape
        .background(EffectView(material: .underWindowBackground).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .onAppear { focus = true }
    }
}

// Helper for Visual Effect (Blur)
struct EffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.state = .active
        v.blendingMode = .behindWindow
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - App Delegate & Window Setup
class LauncherWindow: NSWindow {
    // Allow borderless window to accept key input
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: LauncherWindow!
    
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        
        // Window Configuration
        window = LauncherWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.borderless, .fullSizeContentView, .resizable],
            backing: .buffered, defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating // Keep above other windows
        window.isMovableByWindowBackground = true
        
        // Persistence: Remember window size/position
        window.setFrameAutosaveName("LauncherMainWindow")
        
        window.contentView = NSHostingView(rootView: ContentView())
        
        // Center only if no saved position exists
        if !window.setFrameUsingName("LauncherMainWindow") {
            window.center()
        }
        
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // Quit when user clicks away
    func applicationDidResignActive(_ n: Notification) {
        NSApp.terminate(nil)
    }
}

// MARK: - Entry Point
@main
struct LauncherApp {
    static func main() {
        let delegate = AppDelegate()
        NSApplication.shared.delegate = delegate
        NSApplication.shared.run()
    }
}