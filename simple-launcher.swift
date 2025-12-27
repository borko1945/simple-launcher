import AppKit
import Combine

class AppModel: ObservableObject {
    let name: String
    let url: URL
    @Published var icon: NSImage
    var lastLaunched: Double

    init(name: String, url: URL, icon: NSImage, lastLaunched: Double) {
        self.name = name
        self.url = url
        self.icon = icon
        self.lastLaunched = lastLaunched
    }
}

final class LauncherViewModel: ObservableObject {
    @Published var allApps: [AppModel] = []
    @Published var searchText: String = ""
    private let historyKey = Config.historyKey

    var filteredApps: [AppModel] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return allApps }
        
        return allApps
            .filter { $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { 
                let p1 = $0.name.lowercased().hasPrefix(query)
                let p2 = $1.name.lowercased().hasPrefix(query)
                return p1 != p2 ? p1 : $0.lastLaunched > $1.lastLaunched
            }
    }

    func loadApplicationsSync() {
        PerfLog.mark("loadApplicationsSync() started")
        
        let history = UserDefaults.standard.dictionary(forKey: historyKey) as? [String: Double] ?? [:]
        var newApps: [AppModel] = []

        for path in Config.applicationPaths {
            newApps.append(contentsOf: scanFolder(path: path, history: history))
        }

        PerfLog.mark("Filesystem scan complete. Sorting...")
        newApps.sort { $0.lastLaunched > $1.lastLaunched }
        self.allApps = newApps
        PerfLog.mark("UI Updated with Text Data and Icons")
    }

    private func scanFolder(path: String, history: [String: Double]) -> [AppModel] {
        let folderURL = URL(fileURLWithPath: path)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return [] }

        return contents
            .filter { $0.pathExtension == "app" }
            .compactMap { url in
                let name = url.deletingPathExtension().lastPathComponent
                let lastLaunched = history[url.path] ?? 0
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = Config.iconSize
                return AppModel(name: name, url: url, icon: icon, lastLaunched: lastLaunched)
            }
    }

    func launch(_ app: AppModel) {
        PerfLog.mark("Launching \(app.name)")
        var history = UserDefaults.standard.dictionary(forKey: historyKey) as? [String: Double] ?? [:]
        history[app.url.path] = Date().timeIntervalSince1970
        UserDefaults.standard.set(history, forKey: historyKey)
        NSWorkspace.shared.open(app.url)
        NSApp.terminate(nil)
    }
}