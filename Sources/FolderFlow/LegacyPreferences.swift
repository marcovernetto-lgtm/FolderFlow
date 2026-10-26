import Foundation

enum LegacyPreferences {
    static let oldDomain = "com.folderflow.app"
    static let marker = "FolderFlowLegacyPreferencesMigrated"
    static let keys = ["SavedProjects", "VolumeColors", "MonitoredPaths", "ExternalDataPath",
                       "ProjectNamingPattern", "LaunchAtLogin", "HideDockIcon", "FolderFlowDeviceID",
                       "UnreadableSavedProjects"]

    static func migrate(defaults: UserDefaults = .standard, domain: String, backupDirectory: URL, legacyDomain: String = oldDomain) throws {
        guard domain != legacyDomain else { return }
        var current = defaults.persistentDomain(forName: domain) ?? [:]
        guard current[marker] as? Bool != true else { return }
        let legacy = defaults.persistentDomain(forName: legacyDomain) ?? [:]
        let values = legacy.filter { keys.contains($0.key) }
        if !values.isEmpty {
            // Back up before copying; the previous app's domain is never changed.
            try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            let backup = backupDirectory.appendingPathComponent("legacy-preferences-\(UUID().uuidString).plist")
            let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            try data.write(to: backup, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            // An existing new catalog must not receive pieces of an unrelated old catalog.
            if current["SavedProjects"] == nil {
                for (key, value) in values where current[key] == nil { current[key] = value }
            }
        }
        current[marker] = true
        defaults.setPersistentDomain(current, forName: domain)
    }
}
