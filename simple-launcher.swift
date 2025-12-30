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
        load()
    }
    
    var filtered: [AppModel] {
        searchText.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
    
    func load() {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }
            
            let history = UserDefaults.standard.dictionary(forKey: self.historyKey) as? [String: Double] ?? [:]
            
            // Expanded search paths to find more system apps
            let paths = [
                "/Applications",
                "/System/Applications",
                "/System/Applications/Utilities",
                "/System/Library/CoreServices",
                "/System/Library/CoreServices/Applications",
                NSHomeDirectory() + "/Applications"
            ]
            
            var foundApps: [AppModel] = []
            var seenPaths = Set<String>()
            
            // 1. Scan directories for .app bundles
            for path in paths {
                let url = URL(fileURLWithPath: path)
                guard let contents = try? FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: .skipsHiddenFiles
                ) else { continue }
                
                for itemURL in contents {
                    let itemPath = itemURL.path
                    guard !seenPaths.contains(itemPath) else { continue }
                    seenPaths.insert(itemPath)
                    
                    // Check if it's an app bundle
                    if itemURL.pathExtension == "app" {
                        if let app = self.createAppModel(from: itemURL, history: history) {
                            foundApps.append(app)
                        }
                    }
                }
            }
            
            // 2. Get URLs of all registered applications
            if let appURLs = LSCopyApplicationURLsForURL(
                URL(fileURLWithPath: "/Applications") as CFURL,
                .all
            )?.takeRetainedValue() as? [URL] {
                for url in appURLs {
                    let path = url.path
                    guard !seenPaths.contains(path) else { continue }
                    seenPaths.insert(path)
                    
                    if let app = self.createAppModel(from: url, history: history) {
                        foundApps.append(app)
                    }
                }
            }
            
            // Sort by MRU, then alphabetically
            let sorted = foundApps.sorted {
                if $0.lastLaunched != $1.lastLaunched { return $0.lastLaunched > $1.lastLaunched }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            
            DispatchQueue.main.async { self.apps = sorted }
        }
    }
    
    private func createAppModel(from url: URL, history: [String: Double]) -> AppModel? {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 512, height: 512)
        
        // Try to get proper display name
        var displayName = url.deletingPathExtension().lastPathComponent
        if let bundle = Bundle(url: url),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? 
                      bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
            displayName = name
        }
        
        return AppModel(
            name: displayName,
            url: url,
            icon: icon,
            lastLaunched: history[url.path] ?? 0
        )
    }
    
    func launch(_ app: AppModel) {
        var history = UserDefaults.standard.dictionary(forKey: historyKey) as? [String: Double] ?? [:]
        history[app.url.path] = Date().timeIntervalSince1970
        UserDefaults.standard.set(history, forKey: historyKey)
        
        NSWorkspace.shared.open(app.url)
        NSApp.terminate(nil)
    }
}

// MARK: - Views
struct ContentView: View {
    @StateObject var vm = LauncherViewModel()
    @FocusState var focus: Bool
    @State private var selectedIndex: Int = 0
    @State private var previousSearchText: String = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // Search Bar
            TextField("Search...", text: $vm.searchText)
                .textFieldStyle(.plain)
                .font(.largeTitle.weight(.light))
                .focused($focus)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 10)
                .onSubmit { 
                    if !vm.filtered.isEmpty && selectedIndex < vm.filtered.count { 
                        vm.launch(vm.filtered[selectedIndex]) 
                    }
                }
                .onExitCommand { NSApp.terminate(nil) }
            
            // App Grid
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 3)], spacing: 3) {
                    ForEach(Array(vm.filtered.enumerated()), id: \.element.id) { index, app in
                        Button(action: { vm.launch(app) }) {
                            VStack(spacing: 0) {
                                Image(nsImage: app.icon)
                                    .resizable()
                                    .frame(width: 80, height: 80)
                                Text(app.name)
                                    .font(.title3)
                                    .lineLimit(1)
                                    .foregroundColor(.primary.opacity(0.9))
                            }
                            .padding(3)
                            .frame(maxWidth: .infinity)
                            .background(selectedIndex == index ? Color.accentColor.opacity(0.2) : .clear)
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
        .background(EffectView(material: .underWindowBackground).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .onAppear { 
            focus = true
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                handleKeyDown(event)
            }
        }
        .onReceive(vm.$searchText) { newText in
            if newText != previousSearchText {
                selectedIndex = 0
                previousSearchText = newText
            }
        }
    }
    
    func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let cols = max(1, Int((700 - 40) / 113))
        
        switch Int(event.keyCode) {
        case 125: // Down
            selectedIndex = min(selectedIndex + cols, vm.filtered.count - 1)
            return nil
        case 126: // Up
            selectedIndex = max(selectedIndex - cols, 0)
            return nil
        case 124: // Right
            selectedIndex = min(selectedIndex + 1, vm.filtered.count - 1)
            return nil
        case 123: // Left
            selectedIndex = max(selectedIndex - 1, 0)
            return nil
        default:
            return event
        }
    }
}

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
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: LauncherWindow!
    
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        
        window = LauncherWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.borderless, .fullSizeContentView, .resizable],
            backing: .buffered, defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.setFrameAutosaveName("LauncherMainWindow")
        window.contentView = NSHostingView(rootView: ContentView())
        
        if !window.setFrameUsingName("LauncherMainWindow") {
            window.center()
        }
        
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
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