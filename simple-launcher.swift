import AppKit
import Combine

class AppModel: Identifiable, ObservableObject {
    let id = UUID()
    let name: String
    let url: URL
    @Published var icon: NSImage

    init(name: String, url: URL, icon: NSImage, lastLaunched: Double) {
        self.name = name
        self.url = url
        self.icon = icon
        self.lastLaunched = lastLaunched
    }

    var lastLaunched: Double
}

final class LauncherViewModel: ObservableObject {
    @Published var allApps: [AppModel] = []
    @Published var searchText: String = ""

    private let historyKey = Config.historyKey

    init() {}

    var filteredApps: [AppModel] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()

        if query.isEmpty { return allApps }

        return allApps.filter { $0.name.localizedCaseInsensitiveContains(query) }
            .sorted {
                let p1 = $0.name.lowercased().hasPrefix(query)
                let p2 = $1.name.lowercased().hasPrefix(query)
                if p1 != p2 { return p1 }
                return $0.lastLaunched > $1.lastLaunched
            }
    }

    func loadApplicationsSync() {
        PerfLog.mark("loadApplicationsSync() started")

        let history = loadHistory()
        var newApps: [AppModel] = []

        // Scan folders
        for path in Config.applicationPaths {
            let folderApps = scanFolder(path: path, history: history)
            newApps.append(contentsOf: folderApps)
        }

        PerfLog.mark("Filesystem scan complete. Sorting...")

        // Sort once
        newApps.sort { $0.lastLaunched > $1.lastLaunched }

        // Set apps directly
        self.allApps = newApps
        PerfLog.mark("UI Updated with Text Data and Icons")
    }

    private func scanFolder(path: String, history: [String: Double]) -> [AppModel] {
        let folderURL = URL(fileURLWithPath: path)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        return contents.filter { $0.pathExtension == "app" }.map { url in
            let name = url.deletingPathExtension().lastPathComponent
            let lastLaunched = history[url.path] ?? 0
            // Load icon synchronously
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = Config.iconSize
            return AppModel(name: name, url: url, icon: icon, lastLaunched: lastLaunched)
        }
    }

    func launch(_ app: AppModel) {
        PerfLog.mark("Launching \(app.name)")
        saveToHistory(app: app)
        NSWorkspace.shared.open(app.url)
        NSApp.terminate(nil)
    }

    private func loadHistory() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: historyKey) as? [String: Double] ?? [:]
    }

    private func saveToHistory(app: AppModel) {
        var history = loadHistory()
        history[app.url.path] = Date().timeIntervalSince1970
        UserDefaults.standard.set(history, forKey: historyKey)
    }
}