import SwiftUI
import AppKit

// MARK: - Models & Logic
struct AppModel: Identifiable, Codable {
    let id: UUID
    let name: String
    let urlPath: String
    let lastLaunched: Double
    
    var url: URL { URL(fileURLWithPath: urlPath) }
    
    // Icons are NOT cached - always load fresh (fast operation)
    var icon: NSImage {
        let icon = NSWorkspace.shared.icon(forFile: urlPath)
        icon.size = NSSize(width: 512, height: 512)
        return icon
    }
    
    init(id: UUID = UUID(), name: String, url: URL, lastLaunched: Double) {
        self.id = id
        self.name = name
        self.urlPath = url.path
        self.lastLaunched = lastLaunched
    }
}

class LauncherViewModel: ObservableObject {
    @Published var apps: [AppModel] = []
    @Published var searchText = ""
    @Published var isLoading = false
    
    private let historyKey = "launcher.history"
    private let cacheKey = "launcher.appCache"
    
    init() {
        loadFromCache()
        load()
    }
    
    var filtered: [AppModel] {
        searchText.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
    
    func loadFromCache() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode([AppModel].self, from: data) {
            self.apps = cached
        }
    }
    
    func load() {
        isLoading = true
        
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }
            
            let history = UserDefaults.standard.dictionary(forKey: self.historyKey) as? [String: Double] ?? [:]
            
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
            
            // Scan directories
            for path in paths {
                let url = URL(fileURLWithPath: path)
                guard let contents = try? FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: .skipsHiddenFiles
                ) else { continue }
                
                for itemURL in contents where itemURL.pathExtension == "app" {
                    let itemPath = itemURL.path
                    guard !seenPaths.contains(itemPath) else { continue }
                    seenPaths.insert(itemPath)
                    
                    if let app = self.createAppModel(from: itemURL, history: history) {
                        foundApps.append(app)
                    }
                }
            }
            
            // Query Launch Services for additional apps
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
            
            // Update UI and cache
            DispatchQueue.main.async {
                self.apps = sorted
                self.isLoading = false
                self.saveToCache(sorted)
            }
        }
    }
    
    private func saveToCache(_ apps: [AppModel]) {
        if let data = try? JSONEncoder().encode(apps) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }
    
    private func createAppModel(from url: URL, history: [String: Double]) -> AppModel? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        
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
            // Search Bar with Refresh Button
            HStack(spacing: 12) {
                TextField("Search...", text: $vm.searchText)
                    .textFieldStyle(.plain)
                    .font(.largeTitle.weight(.light))
                    .focused($focus)
                    .onSubmit { 
                        if !vm.filtered.isEmpty && selectedIndex < vm.filtered.count { 
                            vm.launch(vm.filtered[selectedIndex]) 
                        }
                    }
                    .onExitCommand { NSApp.terminate(nil) }
                
                Button(action: { vm.load() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.title2)
                        .foregroundColor(.primary.opacity(0.7))
                        .rotationEffect(.degrees(vm.isLoading ? 360 : 0))
                        .animation(vm.isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: vm.isLoading)
                }
                .buttonStyle(.plain)
                .disabled(vm.isLoading)
                .help("Refresh app list")
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 10)
            
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