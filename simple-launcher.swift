import SwiftUI
import AppKit

// MARK: - Performance Logger
enum PerfLog {
    private static let startTime = Date()
    private static let logFile = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-perf.log")
    
    static func mark(_ label: String) {
        let elapsed = Date().timeIntervalSince(startTime) * 1000
        let message = String(format: "⏱️  [%.2fms] %@\n", elapsed, label)
        FileHandle.standardError.write(message.data(using: .utf8)!)
        
        if let data = message.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }
    
    static func printLogPath() {
        let message = "📝 Performance log: \(logFile.path)\n"
        FileHandle.standardError.write(message.data(using: .utf8)!)
    }
}

// MARK: - Configuration
enum Config {
    static let historyKey = "launcher.usage.history"
    static let windowSize = CGSize(width: 700, height: 500)
    static let iconSize = NSSize(width: 64, height: 64)
    static let applicationPaths = [
        "/Applications",
        "/System/Applications",
        "\(NSHomeDirectory())/Applications"
    ]
}

// MARK: - Models
struct AppModel: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let url: URL
    let icon: NSImage
    var lastLaunched: Double
    
    static func == (lhs: AppModel, rhs: AppModel) -> Bool {
        lhs.url == rhs.url
    }
}

// MARK: - View Model
final class LauncherViewModel: ObservableObject {
    @Published var allApps: [AppModel] = []
    @Published var searchText: String = ""
    
    private let historyKey = Config.historyKey
    
    var filteredApps: [AppModel] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        
        // Sort by most recently used first, then alphabetically
        let sortedApps = allApps.sorted { app1, app2 in
            if app1.lastLaunched != app2.lastLaunched {
                return app1.lastLaunched > app2.lastLaunched
            }
            return app1.name < app2.name
        }
        
        // If no search query, return all sorted apps
        guard !query.isEmpty else { return sortedApps }
        
        // Filter and prioritize prefix matches
        return sortedApps
            .filter { $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { app1, app2 in
                let app1HasPrefix = app1.name.lowercased().hasPrefix(query)
                let app2HasPrefix = app2.name.lowercased().hasPrefix(query)
                
                if app1HasPrefix != app2HasPrefix {
                    return app1HasPrefix
                }
                return app1.lastLaunched > app2.lastLaunched
            }
    }
    
    func loadApplications() {
        PerfLog.mark("loadApplications() started (background)")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let loadStart = Date()
            let history = self.loadHistory()
            PerfLog.mark("Loaded history (\(history.count) entries)")
            
            let apps = self.scanApplications(history: history)
            
            let loadTime = Date().timeIntervalSince(loadStart) * 1000
            PerfLog.mark(String(format: "Total apps loaded: %d (%.2fms)", apps.count, loadTime))
            
            DispatchQueue.main.async {
                PerfLog.mark("Updating UI with loaded apps")
                self.allApps = apps
                PerfLog.mark("UI updated - apps visible")
            }
        }
    }
    
    func launch(_ app: AppModel) {
        PerfLog.mark("Launching \(app.name)")
        saveToHistory(app: app)
        NSWorkspace.shared.open(app.url)
        NSApp.terminate(nil)
    }
    
    // MARK: - Private Helpers
    
    private func loadHistory() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: historyKey) as? [String: Double] ?? [:]
    }
    
    private func saveToHistory(app: AppModel) {
        var history = loadHistory()
        history[app.url.path] = Date().timeIntervalSince1970
        UserDefaults.standard.set(history, forKey: historyKey)
    }
    
    private func scanApplications(history: [String: Double]) -> [AppModel] {
        var apps: [AppModel] = []
        
        for path in Config.applicationPaths {
            let pathStart = Date()
            let folderURL = URL(fileURLWithPath: path)
            
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            ) else { continue }
            
            let appURLs = contents.filter { $0.pathExtension == "app" }
            
            for url in appURLs {
                let name = url.deletingPathExtension().lastPathComponent
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = Config.iconSize
                
                let lastLaunched = history[url.path] ?? 0
                apps.append(AppModel(name: name, url: url, icon: icon, lastLaunched: lastLaunched))
            }
            
            let pathTime = Date().timeIntervalSince(pathStart) * 1000
            PerfLog.mark(String(format: "Scanned %@ (%d apps, %.2fms)", path, appURLs.count, pathTime))
        }
        
        return apps
    }
}

// MARK: - Views
struct AppButton: View {
    let app: AppModel
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(nsImage: app.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                
                Text(app.name)
                    .font(.system(size: 12, weight: .regular))
                    .lineLimit(1)
            }
            .padding(.vertical, 15)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

struct ContentView: View {
    @StateObject private var viewModel = LauncherViewModel()
    @FocusState private var isFocused: Bool
    
    init() {
        PerfLog.mark("ContentView init")
    }
    
    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().opacity(0.2)
            appGrid
        }
        .background(VisualEffectView(material: .underWindowBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear {
            PerfLog.mark("ContentView onAppear - WINDOW IS VISIBLE")
            isFocused = true
            PerfLog.mark("Search field focused")
            viewModel.loadApplications()
        }
    }
    
    private var searchField: some View {
        TextField("Search Applications...", text: $viewModel.searchText)
            .textFieldStyle(.plain)
            .font(.system(size: 24, weight: .light))
            .focused($isFocused)
            .padding(25)
            .onSubmit {
                if let first = viewModel.filteredApps.first {
                    viewModel.launch(first)
                }
            }
            .onExitCommand {
                NSApp.terminate(nil)
            }
    }
    
    private var appGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 20) {
                ForEach(Array(viewModel.filteredApps.enumerated()), id: \.element.id) { index, app in
                    AppButton(
                        app: app,
                        isSelected: index == 0,
                        action: { viewModel.launch(app) }
                    )
                }
            }
            .padding(20)
        }
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Window
final class LauncherWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - App Delegate
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: LauncherWindow!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        PerfLog.mark("applicationDidFinishLaunching started")
        
        NSApp.setActivationPolicy(.regular)
        PerfLog.mark("Activation policy set")
        
        setupWindow()
        showWindow()
        
        PerfLog.mark("App activated")
    }
    
    func windowDidResignKey(_ notification: Notification) {
        PerfLog.mark("Window lost focus - terminating")
        NSApp.terminate(nil)
    }
    
    // MARK: - Private Helpers
    
    private func setupWindow() {
        window = LauncherWindow(
            contentRect: NSRect(origin: .zero, size: Config.windowSize),
            styleMask: [.borderless, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        PerfLog.mark("Window created")
        
        window.center()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.delegate = self
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.setFrameAutosaveName("LauncherMainWindow")
        
        PerfLog.mark("Window configured")
    }
    
    private func showWindow() {
        window.contentView = NSHostingView(rootView: ContentView())
        PerfLog.mark("NSHostingView set")
        
        window.makeKeyAndOrderFront(nil)
        PerfLog.mark("Window shown - USER CAN SEE IT NOW")
        
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Entry Point
@main
struct LauncherApp {
    static func main() {
        PerfLog.printLogPath()
        PerfLog.mark("main() entry point")
        
        let delegate = AppDelegate()
        NSApplication.shared.delegate = delegate
        
        PerfLog.mark("Delegate assigned, calling run()")
        NSApplication.shared.run()
    }
}