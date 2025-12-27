import SwiftUI
import AppKit

// MARK: - App Configuration
enum Config {
    static let historyKey = "launcher.usage.history"
    static let windowSize = CGSize(width: 700, height: 500)
    static let iconSize = NSSize(width: 64, height: 64)
}

// MARK: - Logic
final class LauncherViewModel: ObservableObject {
    @Published var allApps: [AppModel] = []
    @Published var searchText: String = ""
    private let historyKey = Config.historyKey

    var filteredApps: [AppModel] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let base = allApps.sorted { 
            $0.lastLaunched != $1.lastLaunched ? $0.lastLaunched > $1.lastLaunched : $0.name < $1.name 
        }
        if query.isEmpty { return base }
        return base.filter { $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { (a, b) -> Bool in
                let aPrefix = a.name.lowercased().hasPrefix(query)
                let bPrefix = b.name.lowercased().hasPrefix(query)
                return aPrefix != bPrefix ? aPrefix : a.lastLaunched > b.lastLaunched
            }
    }

    func loadApplications() {
        let history = UserDefaults.standard.dictionary(forKey: historyKey) as? [String: Double] ?? [:]
        let paths = ["/Applications", "/System/Applications", "\(NSHomeDirectory())/Applications"]
        var found: [AppModel] = []
        for path in paths {
            let folderURL = URL(fileURLWithPath: path)
            let contents = (try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            for url in contents where url.pathExtension == "app" {
                let name = url.deletingPathExtension().lastPathComponent
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = Config.iconSize
                found.append(AppModel(name: name, url: url, icon: icon, lastLaunched: history[url.path] ?? 0))
            }
        }
        DispatchQueue.main.async { self.allApps = found }
    }

    func launch(_ app: AppModel) {
        var history = UserDefaults.standard.dictionary(forKey: historyKey) as? [String: Double] ?? [:]
        history[app.url.path] = Date().timeIntervalSince1970
        UserDefaults.standard.set(history, forKey: historyKey)
        NSWorkspace.shared.open(app.url)
        NSApp.terminate(nil)
    }
}

// MARK: - UI Components
struct AppButton: View {
    let app: AppModel
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(nsImage: app.icon).resizable().aspectRatio(contentMode: .fit).frame(width: 64, height: 64)
                Text(app.name).font(.system(size: 12, weight: .regular)).lineLimit(1)
            }
            .padding(.vertical, 15).padding(.horizontal, 10).frame(maxWidth: .infinity)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1.5))
        }.buttonStyle(.plain)
    }
}

struct ContentView: View {
    @StateObject private var viewModel = LauncherViewModel()
    @FocusState private var isFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            TextField("Search Applications...", text: $viewModel.searchText)
                .textFieldStyle(.plain).font(.system(size: 24, weight: .light))
                .focused($isFocused).padding(25)
                .onSubmit { if let first = viewModel.filteredApps.first { viewModel.launch(first) } }
                .onExitCommand { NSApp.terminate(nil) }
            
            Divider().opacity(0.2)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 20) {
                    let results = viewModel.filteredApps
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, app in
                        AppButton(app: app, isSelected: index == 0) { viewModel.launch(app) }
                    }
                }.padding(20)
            }
        }
        // Material .windowBackground follows system Light/Dark mode automatically
        .background(VisualEffectView(material: .underWindowBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear {
            viewModel.loadApplications()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.mainWindow?.makeKey()
                isFocused = true
            }
        }
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Core Setup
struct AppModel: Identifiable, Equatable {
    let id = UUID(); let name: String; let url: URL; let icon: NSImage; var lastLaunched: Double
    static func == (lhs: AppModel, rhs: AppModel) -> Bool { lhs.url == rhs.url }
}

final class LauncherWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: LauncherWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = LauncherWindow(contentRect: NSRect(origin: .zero, size: Config.windowSize),
                                styleMask: [.borderless, .fullSizeContentView],
                                backing: .buffered, defer: false)
        window.center(); window.isOpaque = false; window.backgroundColor = .clear
        window.delegate = self; window.level = .floating; window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: ContentView())
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowDidResignKey(_ notification: Notification) { NSApp.terminate(nil) }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()