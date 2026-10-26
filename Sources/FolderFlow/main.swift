import SwiftUI
import Foundation
import UniformTypeIdentifiers
import AppKit
import Charts
import GoogleSignIn

// Shared visual tokens for the dark studio interface.
enum StudioTheme {
    static let background = Color(red: 0.040, green: 0.063, blue: 0.070)
    static let sidebar = Color(red: 0.057, green: 0.086, blue: 0.094)
    static let surface = Color(red: 0.090, green: 0.127, blue: 0.138)
    static let raised = Color(red: 0.125, green: 0.180, blue: 0.195)
    static let text = Color(red: 0.91, green: 0.95, blue: 0.95)
    static let secondary = Color(red: 0.65, green: 0.73, blue: 0.75)
    static let line = Color.white.opacity(0.10)
    static let accent = Color(red: 0.38, green: 0.76, blue: 0.77)
    static let green = Color(red: 0.36, green: 0.79, blue: 0.56)
    static let amber = Color(red: 0.94, green: 0.70, blue: 0.33)
    static let red = Color(red: 0.93, green: 0.48, blue: 0.43)
    static let blue = Color(red: 0.36, green: 0.64, blue: 0.94)

    static func volumeColor(_ color: Color) -> Color {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return accent }
        let originalHue = Double(rgb.hueComponent)
        // Remap legacy violet/magenta disks without rewriting the stored catalog.
        let hue = (0.69...0.96).contains(originalHue) ? (originalHue < 0.82 ? 0.045 : 0.10) : originalHue
        return Color(hue: hue,
                     saturation: min(Double(rgb.saturationComponent), 0.66),
                     brightness: min(Double(rgb.brightnessComponent), 0.92),
                     opacity: Double(rgb.alphaComponent))
    }
}

// Enum per lo stato di fatturazione
enum BillingStatus: String, CaseIterable, Codable {
    case toBill = "Da fatturare"
    case billed = "Fatturato"
    
    var color: Color {
        switch self {
        case .toBill:
            return StudioTheme.amber
        case .billed:
            return StudioTheme.green
        }
    }
    
    var icon: String {
        switch self {
        case .toBill:
            return "exclamationmark.triangle.fill"
        case .billed:
            return "checkmark.circle.fill"
        }
    }
}

// Struttura per salvare i colori RGB
struct ColorRGB: Codable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double
    
    init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
    
    func toColor() -> Color {
        return Color(red: red, green: green, blue: blue, opacity: alpha)
    }
    
    static func fromColor(_ color: Color) -> ColorRGB {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.gray.usingColorSpace(.sRGB)!
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        
        nsColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        
        // SwiftUI/AppKit color conversion can introduce tiny floating point changes.
        // Stable components prevent unchanged disk colors from producing cloud conflicts.
        func component(_ value: CGFloat) -> Double { (Double(value) * 1_000_000).rounded() / 1_000_000 }
        return ColorRGB(red: component(red), green: component(green), blue: component(blue), alpha: component(alpha))
    }
}

// Informazioni sui volumi/hard disk attualmente collegati al Mac
struct MountedVolumeInfo: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let url: URL
    let totalCapacityGB: Double
    let usedCapacityGB: Double
    var availableCapacityGB: Double = 0.0
    var totalBytes: Int64 = 0
    var usedBytes: Int64 = 0
    var availableBytes: Int64 = 0
}

func formatStorageSize(_ gb: Double) -> String {
    if gb >= 1000.0 {
        let tb = gb / 1000.0
        let s = String(format: "%.2f TB", tb)
        if s.hasSuffix("0 TB") && !s.hasSuffix(".00 TB") {
            return String(format: "%.1f TB", tb)
        }
        return s
    } else if gb >= 10.0 {
        return String(format: "%.0f GB", gb)
    } else if gb > 0.01 {
        return String(format: "%.1f GB", gb)
    } else {
        return "0 GB"
    }
}


// Verifica se la cartella del progetto è online e vuota (pronta per offload post-shooting)
func isProjectFolderEmpty(_ project: VideoProject) -> Bool {
    guard project.isOnline && !project.isMissing else { return false }
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: project.path, isDirectory: &isDir), isDir.boolValue else {
        return false
    }
    if let items = try? fm.contentsOfDirectory(atPath: project.path) {
        let visibleItems = items.filter { !$0.hasPrefix(".") }
        return visibleItems.isEmpty
    }
    return project.folderSize == 0.0 && project.folderContents.isEmpty
}

// Calcola la dimensione effettiva occupata su disco da una cartella in GB con traversal ad alte prestazioni
func calculateFolderSizeInGB(atPath path: String) -> Double {
    var cleanPath = path
    while cleanPath.hasPrefix("//") { cleanPath.removeFirst() }
    let url = URL(fileURLWithPath: cleanPath).standardized
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: cleanPath, isDirectory: &isDir), isDir.boolValue else {
        return 0.0
    }
    
    guard let enumerator = fm.enumerator(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey],
        options: [.skipsPackageDescendants]
    ) else { return 0.0 }
    
    var totalBytes: Int64 = 0
    var fileCount = 0
    let maxFiles = 250_000
    
    for case let fileURL as URL in enumerator {
        if fileCount >= maxFiles { break }
        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]),
              values.isRegularFile == true else { continue }
        if let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize {
            totalBytes += Int64(size)
            fileCount += 1
        }
    }
    return Double(totalBytes) / (1024.0 * 1024.0 * 1024.0)
}

// Avvia l'app SecureCopy e copia il percorso della cartella progetto negli appunti
func launchSecureCopy(for projectPath: String, dataManager: DataManager? = nil) {
    // Copia il percorso di destinazione negli appunti per incollarlo rapidamente se necessario
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(projectPath, forType: .string)
    
    let workspace = NSWorkspace.shared
    let bundleID = "com.marcovernetto.securecopier"
    
    let candidatePaths = [
        "/Applications/SecureCopy.app",
        "/Applications/SicureCopy.app",
        (NSHomeDirectory() as NSString).appendingPathComponent("Applications/SecureCopy.app")
    ]
    
    let resolvedAppURL: URL? = workspace.urlForApplication(withBundleIdentifier: bundleID)
        ?? candidatePaths.map { URL(fileURLWithPath: $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    
    guard let appURL = resolvedAppURL else {
        dataManager?.showError("App SecureCopy non trovata in /Applications/SecureCopy.app")
        return
    }
    
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    config.arguments = ["--destination", projectPath]
    config.environment = ["SECURECOPY_DESTINATION": projectPath]
    
    workspace.openApplication(at: appURL, configuration: config) { _, error in
        if let error = error {
            DispatchQueue.main.async {
                dataManager?.showError("Impossibile avviare SecureCopy: \(error.localizedDescription)")
            }
        }
    }
}


// Struttura per salvare tutti i dati dell'app
struct AppData: Codable {
    let projects: [VideoProject]
    let volumeColors: [String: ColorRGB]
    let exportDate: Date
    let version: String
    var monitoredPaths: [String]?
    var catalog: StoredCatalog?
    var sourceDeviceID: String?
    
    init(projects: [VideoProject], volumeColors: [String: ColorRGB], exportDate: Date = Date(), version: String = "1.0", monitoredPaths: [String]? = nil, catalog: StoredCatalog? = nil, sourceDeviceID: String? = nil) {
        self.projects = projects
        self.volumeColors = volumeColors
        self.exportDate = exportDate
        self.version = version
        self.monitoredPaths = monitoredPaths
        self.catalog = catalog
        self.sourceDeviceID = sourceDeviceID
    }
}

// Modello per i progetti video
struct VideoProject: Identifiable, Hashable, Codable {
    let id: UUID
    let name: String
    var path: String
    let date: Date
    var isOnline: Bool
    var volumeIdentifier: String
    var folderSize: Double = 0.0
    var folderContents: [String] = []
    var isAnalyzed: Bool = false
    var billingStatus: BillingStatus = .toBill
    var isMissing: Bool = false
    var deadline: Date? = nil
    var isCompleted: Bool = false
    var comments: String = ""
    
    init(name: String, path: String, date: Date, isOnline: Bool = true, volumeIdentifier: String = "", folderSize: Double = 0.0, folderContents: [String] = [], isAnalyzed: Bool = false, billingStatus: BillingStatus = .toBill, isMissing: Bool = false, deadline: Date? = nil, isCompleted: Bool = false, comments: String = "") {
        self.id = UUID()
        self.name = name
        var cleanPath = path
        while cleanPath.hasPrefix("//") { cleanPath.removeFirst() }
        self.path = cleanPath
        self.date = date
        self.isOnline = isOnline
        self.volumeIdentifier = volumeIdentifier
        self.folderSize = folderSize
        self.folderContents = folderContents
        self.isAnalyzed = isAnalyzed
        self.billingStatus = billingStatus
        self.isMissing = isMissing
        self.deadline = deadline
        self.isCompleted = isCompleted
        self.comments = comments
    }
    
    init(id: UUID, name: String, path: String, date: Date, isOnline: Bool = true, volumeIdentifier: String = "", folderSize: Double = 0.0, folderContents: [String] = [], isAnalyzed: Bool = false, billingStatus: BillingStatus = .toBill, isMissing: Bool = false, deadline: Date? = nil, isCompleted: Bool = false, comments: String = "") {
        self.id = id
        self.name = name
        var cleanPath = path
        while cleanPath.hasPrefix("//") { cleanPath.removeFirst() }
        self.path = cleanPath
        self.date = date
        self.isOnline = isOnline
        self.volumeIdentifier = volumeIdentifier
        self.folderSize = folderSize
        self.folderContents = folderContents
        self.isAnalyzed = isAnalyzed
        self.billingStatus = billingStatus
        self.isMissing = isMissing
        self.deadline = deadline
        self.isCompleted = isCompleted
        self.comments = comments
    }

    static func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            var relative = path
            relative.removeFirst(home.count)
            return "~" + relative
        }
        return path
    }
    
    static func expandPath(_ path: String) -> String {
        if path.hasPrefix("~") {
            let home = NSHomeDirectory()
            var relative = path
            relative.removeFirst()
            return home + relative
        }
        return path
    }

    enum CodingKeys: String, CodingKey {
        case id, name, path, date, isOnline, volumeIdentifier, folderSize, folderContents, isAnalyzed, billingStatus, isMissing, deadline, isCompleted, comments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let rawPath = try container.decode(String.self, forKey: .path)
        var cleanPath = VideoProject.expandPath(rawPath)
        while cleanPath.hasPrefix("//") { cleanPath.removeFirst() }
        path = cleanPath
        date = try container.decode(Date.self, forKey: .date)
        isOnline = try container.decode(Bool.self, forKey: .isOnline)
        volumeIdentifier = try container.decode(String.self, forKey: .volumeIdentifier)
        folderSize = try container.decodeIfPresent(Double.self, forKey: .folderSize) ?? 0.0
        folderContents = try container.decodeIfPresent([String].self, forKey: .folderContents) ?? []
        isAnalyzed = try container.decodeIfPresent(Bool.self, forKey: .isAnalyzed) ?? false
        billingStatus = try container.decodeIfPresent(BillingStatus.self, forKey: .billingStatus) ?? .toBill
        isMissing = try container.decodeIfPresent(Bool.self, forKey: .isMissing) ?? false
        deadline = try container.decodeIfPresent(Date.self, forKey: .deadline)
        isCompleted = try container.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        comments = try container.decodeIfPresent(String.self, forKey: .comments) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(VideoProject.abbreviatePath(path), forKey: .path)
        try container.encode(date, forKey: .date)
        try container.encode(isOnline, forKey: .isOnline)
        try container.encode(volumeIdentifier, forKey: .volumeIdentifier)
        try container.encode(folderSize, forKey: .folderSize)
        try container.encode(folderContents, forKey: .folderContents)
        try container.encode(isAnalyzed, forKey: .isAnalyzed)
        try container.encode(billingStatus, forKey: .billingStatus)
        try container.encode(isMissing, forKey: .isMissing)
        try container.encodeIfPresent(deadline, forKey: .deadline)
        try container.encode(isCompleted, forKey: .isCompleted)
        try container.encode(comments, forKey: .comments)
    }
}

// Scanner per le cartelle
class FolderScanner: ObservableObject {
    @Published var isScanning = false
    @Published var scanProgress: Double = 0.0
    @Published var currentPath = ""
    @Published var currentHardDisk = ""
    @Published var completedHardDisks = 0
    @Published var totalHardDisks = 0
    @Published var errorMessage: String?
    @Published var hasError: Bool = false
    
    private weak var dataManager: DataManager?
    private let scanTimeout: TimeInterval = 300 // 5 minuti
    private let maxScanDepth: Int = 10
    @MainActor private var scanTask: Task<Void, Never>?
    @MainActor private var scanToken = UUID()
    
    init(dataManager: DataManager) {
        self.dataManager = dataManager
    }
    
    // MARK: - Error Management
    func showError(_ message: String) {
        DispatchQueue.main.async {
            self.errorMessage = message
            self.hasError = true
        }
    }
    
    func clearError() {
        DispatchQueue.main.async {
            self.errorMessage = nil
            self.hasError = false
        }
    }
    
    // MARK: - Scan Control
    @MainActor
    func cancelScan() {
        scanTask?.cancel()
        scanToken = UUID()
        isScanning = false; scanProgress = 0; currentPath = "Scansione annullata"; currentHardDisk = ""
    }

    @MainActor
    func scanFolders(_ urls: [URL], isSync: Bool = false) async {
        scanTask?.cancel()
        let token = UUID(); scanToken = token
        let catalogSession = dataManager?.catalogSession
        let pattern = dataManager?.projectNamingPattern ?? ProjectNaming.defaultPattern
        let known = Set(dataManager?.projects.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path } ?? [])
        isScanning = true; scanProgress = 0; completedHardDisks = 0; totalHardDisks = urls.count
        clearError()
        let operation = Task {
            var found: [VideoProject] = []
            var complete: [URL] = []
            for (index, root) in urls.enumerated() {
                guard !Task.isCancelled, scanToken == token else { return }
                currentHardDisk = root.lastPathComponent
                currentPath = "Scansione di \(root.lastPathComponent)…"
                if await scanDirectory(url: root, foundProjects: &found, depth: 0, naming: ProjectNaming(pattern: pattern), knownPaths: known) {
                    complete.append(root)
                }
                guard !Task.isCancelled, scanToken == token else { return }
                completedHardDisks = index + 1
                scanProgress = Double(index + 1) / Double(max(1, urls.count))
            }
            guard !Task.isCancelled, scanToken == token, let manager = dataManager, manager.catalogSession == catalogSession else { isScanning = false; return }
            if isSync { manager.syncProjects(foundProjects: found, scannedVolumes: [], scannedRoots: complete) }
            else {
                for project in found where !manager.projects.contains(where: { $0.path == project.path }) { manager.addProject(project) }
            }
            isScanning = false; scanProgress = 1; currentHardDisk = ""
            currentPath = complete.count == urls.count ? "Scansione completata" : "Scansione parziale: controlla gli errori di accesso"
        }
        scanTask = operation
        let timeout = Task {
            do { try await Task.sleep(nanoseconds: UInt64(scanTimeout * 1_000_000_000)) }
            catch { return }
            guard scanToken == token, isScanning else { return }
            operation.cancel()
            isScanning = false
            showError("Scansione interrotta dopo 5 minuti. I risultati parziali non hanno modificato il catalogo.")
        }
        await withTaskCancellationHandler(operation: { await operation.value }, onCancel: { operation.cancel() })
        timeout.cancel()
        if scanToken == token, operation.isCancelled { isScanning = false }
    }

    @MainActor
    func syncAllVolumes() async {
        let paths = dataManager?.monitoredPaths.filter { FileManager.default.fileExists(atPath: $0) } ?? []
        guard !paths.isEmpty else {
            showError("Seleziona almeno un disco collegato in Impostazioni → Dischi.")
            return
        }
        await scanFolders(paths.map { URL(fileURLWithPath: $0) }, isSync: true)
    }

    private func scanDirectory(url: URL, foundProjects: inout [VideoProject], depth: Int = 0, naming: ProjectNaming, knownPaths: Set<String>) async -> Bool {
        // Controlla limite di profondità
        guard depth < maxScanDepth else {
            showError("Limite di profondità raggiunto per: \(url.path)")
            return false
        }
        
        // Controlla se il task è stato cancellato
        if Task.isCancelled { return false }
        
        let fileManager = FileManager.default
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
            
            var complete = true
            for item in contents {
                // Controlla se il task è stato cancellato
                if Task.isCancelled { return false }
                
                // Controlla se è una cartella
                let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                
                if isDirectory {
                    let folderName = item.lastPathComponent
                    
                    // Keep known projects visible when the format changes; use the selected rule for discoveries.
                    if naming.matches(folderName) || knownPaths.contains(item.standardizedFileURL.path) {
                        // Calcola il peso della cartella in GB
                        let folderSize = await calculateFolderSize(url: item)
                        let volumeId = getVolumeIdentifier(for: item)
                        
                        let project = VideoProject(
                            name: folderName,
                            path: item.path,
                            date: getCreationDate(for: item),
                            isOnline: true,
                            volumeIdentifier: volumeId,
                            folderSize: folderSize,
                            folderContents: [],
                            isAnalyzed: true,
                            billingStatus: .toBill
                        )
                        foundProjects.append(project)
                    }
                    
                    // Continua la scansione ricorsiva solo se non è un pacchetto di sistema
                    if !item.path.contains(".app") && !item.path.contains(".bundle") {
                        if !(await scanDirectory(url: item, foundProjects: &foundProjects, depth: depth + 1, naming: naming, knownPaths: knownPaths)) { complete = false }
                    }
                }
            }
            return complete
        } catch {
            showError("Errore nella scansione di \(url.path): \(error.localizedDescription)")
            return false
        }
    }
    
    private func getCreationDate(for url: URL) -> Date {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.creationDate] as? Date ?? Date()
        } catch {
            return Date()
        }
    }
    
    private func getVolumeIdentifier(for url: URL) -> String {
        let pathComponents = url.pathComponents
        
        // Se il percorso inizia con /Volumes/, estrai il nome del volume
        if pathComponents.count > 2 && pathComponents[1] == "Volumes" {
            return pathComponents[2]
        }
        
        // Prova a ottenere il nome del volume usando resourceValues
        do {
            let resourceValues = try url.resourceValues(forKeys: [.volumeNameKey])
            if let volumeName = resourceValues.volumeName, !volumeName.isEmpty {
                return volumeName
            }
        } catch {
            // Fallback: usa il primo componente del percorso dopo la root
            if pathComponents.count > 1 {
                return pathComponents[1]
            }
        }
        
        // Ultimo fallback
        return "Macintosh HD"
    }
    
    private func calculateFolderSize(url: URL) async -> Double {
        return calculateFolderSizeInGB(atPath: url.path)
    }
}

// Manager per i dati
class DataManager: ObservableObject {
    @Published var projects: [VideoProject] = []
    @Published var volumeColors: [String: Color] = [:]
    @Published var errorMessage: String?
    @Published var hasError: Bool = false
    @Published var externalDataPath: String? = nil
    @Published var isSavingExternal: Bool = false
    @Published var lastSaveDate: Date? = nil
    @Published var monitoredPaths: [String] = []
    @Published var connectedVolumes: [MountedVolumeInfo] = []
    @Published private(set) var projectNamingPattern = ProjectNaming.defaultPattern
    
    var catalogSession = UUID()
    var catalogBackupDirectory: URL?
    var catalogExport: (() -> (StoredCatalog, String)?)?
    var catalogImport: ((StoredCatalog, String?) throws -> Void)?
    var onCatalogChange: (() -> Void)?
    private(set) var localProjectIDs: Set<UUID>?
    @Published private(set) var storageReadOnly = false
    private var initializing = true
    private let externalIO = DispatchQueue(label: "FolderFlow.legacy-file")
    private let defaults: UserDefaults
    private let backupDirectory: URL?
    private var fileWatchTimer: Timer?
    private var lastLoadedFileModificationDate: Date?
    private var workspaceObservers: [NSObjectProtocol] = []
    
    private let availableColors: [Color] = [
        Color(red: 0.22, green: 0.62, blue: 0.94), // Azzurro
        Color(red: 0.96, green: 0.72, blue: 0.23), // Oro
        Color(red: 0.24, green: 0.77, blue: 0.48), // Verde
        Color(red: 0.96, green: 0.45, blue: 0.25), // Arancio
        Color(red: 0.20, green: 0.78, blue: 0.84), // Ciano
        Color(red: 0.92, green: 0.38, blue: 0.40), // Corallo
        Color(red: 0.64, green: 0.79, blue: 0.25), // Lime
        Color(red: 0.31, green: 0.47, blue: 0.91), // Blu
        Color(red: 0.91, green: 0.60, blue: 0.34), // Rame
        Color(red: 0.27, green: 0.75, blue: 0.63), // Giada
        Color(red: 0.91, green: 0.82, blue: 0.42), // Sabbia
        Color(red: 0.50, green: 0.70, blue: 0.87), // Acciaio
        Color(red: 0.78, green: 0.44, blue: 0.29), // Terracotta
        Color(red: 0.62, green: 0.74, blue: 0.48)  // Salvia
    ]
    
    init(defaults: UserDefaults = .standard, backupDirectory: URL? = nil, startupError: String? = nil) {
        self.defaults = defaults
        self.backupDirectory = backupDirectory
        if let startupError {
            storageReadOnly = true
            showError(startupError)
            return
        }
        if let saved = defaults.string(forKey: ProjectNaming.preferenceKey),
           ProjectNaming(pattern: saved).validationError == nil {
            projectNamingPattern = saved
        }
        loadExternalDataPath()
        refreshConnectedVolumes(saveAfter: false)
        loadData()
        // Read both sources before enabling any write to the legacy JSON.
        loadExternalData()
        initializing = false
        if !storageReadOnly { assignVolumeColors() }
        setupVolumeMonitoring()
    }
    
    var appPreferences: SharedAppPreferences {
        SharedAppPreferences(launchAtLogin: defaults.bool(forKey: "LaunchAtLogin"),
                             hideDockIcon: defaults.bool(forKey: "HideDockIcon"))
    }

    func applyAppPreferences(_ preferences: SharedAppPreferences) {
        let previous = appPreferences
        defaults.set(preferences.launchAtLogin, forKey: "LaunchAtLogin")
        defaults.set(preferences.hideDockIcon, forKey: "HideDockIcon")
        // Test suites and previews must never change the Mac's login items or Dock.
        guard defaults === UserDefaults.standard else { return }
        if previous.launchAtLogin != preferences.launchAtLogin { setLaunchAtLogin(enabled: preferences.launchAtLogin) }
        if previous.hideDockIcon != preferences.hideDockIcon {
            NSApp.setActivationPolicy(preferences.hideDockIcon ? .accessory : .regular)
        }
    }

    func updateProjectNamingPattern(_ pattern: String) {
        guard ProjectNaming(pattern: pattern).validationError == nil else { return }
        projectNamingPattern = pattern
        if onCatalogChange != nil { saveData() }
        else { defaults.set(pattern, forKey: ProjectNaming.preferenceKey) }
    }

    func attachCatalogPersistence(_ handler: @escaping () -> Void) {
        fileWatchTimer?.invalidate()
        fileWatchTimer = nil
        externalDataPath = nil
        onCatalogChange = handler
    }

    func applyCatalog(info: CatalogInfo?, projects: [VideoProject], monitoredPaths: [String], localIDs: Set<UUID>) {
        self.projects = projects
        self.volumeColors = info?.colors.mapValues { $0.toColor() } ?? [:]
        self.monitoredPaths = monitoredPaths
        self.projectNamingPattern = info?.namingPattern ?? ProjectNaming.defaultPattern
        self.localProjectIDs = localIDs
        self.storageReadOnly = false
    }

    func displayPath(for project: VideoProject) -> String {
        if project.path.hasPrefix("/__folderflow_remote__/") { return "HD \(project.volumeIdentifier) · file non presenti su questo Mac" }
        return project.path
    }

    func projectYear(_ project: VideoProject) -> String {
        let year = ProjectNaming(pattern: projectNamingPattern).year(in: project.name)
            ?? ProjectNaming().year(in: project.name)
            ?? Calendar.current.component(.year, from: project.date)
        return String(year)
    }

    deinit {
        fileWatchTimer?.invalidate()
        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
    }
    
    private func setupVolumeMonitoring() {
        let nc = NSWorkspace.shared.notificationCenter
        let mountObs = nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshConnectedVolumes()
            self?.updateOnlineStatus()
        }
        let unmountObs = nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshConnectedVolumes()
            self?.updateOnlineStatus()
        }
        workspaceObservers = [mountObs, unmountObs]
    }
    
    func refreshConnectedVolumes(saveAfter: Bool = true) {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var infos: [MountedVolumeInfo] = []
        
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let rawName = values?.volumeName ?? (url.path == "/" ? "Macintosh HD" : url.lastPathComponent)
            guard !rawName.isEmpty else { continue }
            
            let tBytes = Int64(values?.volumeTotalCapacity ?? 0)
            let aBytes = Int64(values?.volumeAvailableCapacity ?? 0)
            let uBytes = max(0, tBytes - aBytes)
            
            // Standard macOS (decimale come Finder: 1 GB = 10^9 byte, 1 TB = 10^12 byte)
            let totalGB = Double(tBytes) / 1_000_000_000.0
            let usedGB = Double(uBytes) / 1_000_000_000.0
            let availGB = Double(aBytes) / 1_000_000_000.0
            
            infos.append(MountedVolumeInfo(
                name: rawName,
                url: url,
                totalCapacityGB: totalGB,
                usedCapacityGB: usedGB,
                availableCapacityGB: availGB,
                totalBytes: tBytes,
                usedBytes: uBytes,
                availableBytes: aBytes
            ))
        }
        
        // Ordina: disco di sistema sempre primo in alto, poi gli altri dischi in ordine numerico/alfabetico naturale (es. 4TB, 6TB, 6TB_B)
        infos.sort { a, b in
            let aSys = a.url.path == "/" || a.name == "Macintosh HD" || !a.url.path.hasPrefix("/Volumes/")
            let bSys = b.url.path == "/" || b.name == "Macintosh HD" || !b.url.path.hasPrefix("/Volumes/")
            if aSys != bSys {
                return aSys
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        
        self.connectedVolumes = infos
        if saveAfter {
            assignVolumeColors()
        }
    }
    
    // MARK: - Error Management
    func showError(_ message: String) {
        DispatchQueue.main.async {
            self.errorMessage = message
            self.hasError = true
        }
    }
    
    func clearError() {
        DispatchQueue.main.async {
            self.errorMessage = nil
            self.hasError = false
        }
    }
    
    // MARK: - Data Validation
    func validateProject(_ project: VideoProject) -> Bool {
        guard !project.name.isEmpty else {
            showError("Nome progetto non può essere vuoto")
            return false
        }
        
        guard !project.path.isEmpty else {
            showError("Percorso progetto non può essere vuoto")
            return false
        }
        
        guard !project.volumeIdentifier.isEmpty else {
            showError("Identificatore volume non può essere vuoto")
            return false
        }
        
        // Non verifica l'esistenza del percorso se il progetto è offline
        // (permette di mantenere progetti su dischi non collegati)
        if project.isOnline {
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: project.path) {
                // Se il progetto è marcato come online ma il percorso non esiste,
                // aggiorna lo stato a offline invece di fallire
                if let index = projects.firstIndex(where: { $0.id == project.id }) {
                    projects[index] = VideoProject(
                        name: project.name,
                        path: project.path,
                        date: project.date,
                        isOnline: false,
                        volumeIdentifier: project.volumeIdentifier,
                        folderSize: project.folderSize,
                        folderContents: project.folderContents,
                        isAnalyzed: project.isAnalyzed,
                        billingStatus: project.billingStatus,
                        deadline: project.deadline,
                        isCompleted: project.isCompleted,
                        comments: project.comments
                    )
                }
            }
        }
        
        return true
    }
    
    func addProject(_ project: VideoProject) {
        guard validateProject(project) else { return }
        
        // Verifica se esiste già un progetto con lo stesso path
        if let existingProjectIndex = projects.firstIndex(where: { $0.path == project.path }) {
            // Preserva lo stato di fatturazione esistente
            let existingBillingStatus = projects[existingProjectIndex].billingStatus
            
            // Aggiorna il progetto esistente mantenendo i metadati personalizzati
            projects[existingProjectIndex] = VideoProject(
                id: projects[existingProjectIndex].id,
                name: project.name,
                path: project.path,
                date: project.date,
                isOnline: project.isOnline,
                volumeIdentifier: project.volumeIdentifier,
                folderSize: project.folderSize,
                folderContents: project.folderContents,
                isAnalyzed: project.isAnalyzed,
                billingStatus: existingBillingStatus,
                deadline: projects[existingProjectIndex].deadline,
                isCompleted: projects[existingProjectIndex].isCompleted,
                comments: projects[existingProjectIndex].comments
            )
            
            assignVolumeColors()
            saveData()
            return
        }
        
        // Se non esiste, aggiungi il nuovo progetto
        projects.append(project)
        localProjectIDs?.insert(project.id)
        assignVolumeColors()
        saveData()
    }
    
    func clearAllProjects() {
        projects.removeAll()
        saveData()
    }
    
    func updateBillingStatus(for projectId: UUID, status: BillingStatus) {
        if let index = projects.firstIndex(where: { $0.id == projectId }) {
            projects[index].billingStatus = status
            saveData()
        }
    }
    
    func updateProjectCompletion(for projectId: UUID, isCompleted: Bool) {
        if let index = projects.firstIndex(where: { $0.id == projectId }) {
            projects[index].isCompleted = isCompleted
            saveData()
        }
    }
    
    func updateProjectInfo(for projectId: UUID, deadline: Date?, isCompleted: Bool, comments: String) {
        if let index = projects.firstIndex(where: { $0.id == projectId }) {
            projects[index].deadline = deadline
            projects[index].isCompleted = isCompleted
            projects[index].comments = comments
            saveData()
        }
    }
    
    // Metodi per aggiornamenti massivi
    func markAllProjectsCompleted() {
        for index in projects.indices {
            projects[index].isCompleted = true
        }
        saveData()
    }
    
    func markAllProjectsBilled() {
        for index in projects.indices {
            projects[index].billingStatus = .billed
        }
        saveData()
    }
    
    func markAllProjectsToBill() {
        for index in projects.indices {
            projects[index].billingStatus = .toBill
        }
        saveData()
    }
    
    func assignVolumeColors() {
        let projectVols = Set(projects.map { $0.volumeIdentifier })
        let mountedVols = Set(connectedVolumes.map { $0.name })
        let uniqueVolumes = projectVols.union(mountedVols).filter { !$0.isEmpty }
        // Keep saved choices, including disconnected disks; assign only newly discovered volumes.
        for (index, volume) in uniqueVolumes.sorted().enumerated() where volumeColors[volume] == nil {
            volumeColors[volume] = availableColors[index % availableColors.count]
        }

        saveData()
    }
    
    func setVolumeColor(_ color: Color, for volumeIdentifier: String) {
        guard !volumeIdentifier.isEmpty else { return }
        volumeColors[volumeIdentifier] = StudioTheme.volumeColor(color)
        saveData()
    }

    func getVolumeColor(for volumeIdentifier: String) -> Color {
        if let color = volumeColors[volumeIdentifier] {
            return StudioTheme.volumeColor(color)
        }
        let hash = abs(volumeIdentifier.hashValue)
        return StudioTheme.volumeColor(availableColors[hash % availableColors.count])
    }
    
    func diskUsage(for projects: [VideoProject]) -> [DiskUsageData] {
        var usageByVolume: [String: Double] = [:]
        for project in projects {
            usageByVolume[project.volumeIdentifier, default: 0] += project.folderSize
        }
        return usageByVolume.map { volume, size in
            let capacity = diskCapacityGiB(for: volume)
            let percent = capacity > 0 ? min(100, max(0, size / capacity * 100)) : nil
            return DiskUsageData(volume: volume, sizeGB: size, percent: percent, color: getVolumeColor(for: volume))
        }.sorted {
            if $0.percent != $1.percent { return ($0.percent ?? -1) > ($1.percent ?? -1) }
            return $0.volume.localizedStandardCompare($1.volume) == .orderedAscending
        }
    }

    private func diskCapacityGiB(for volumeName: String) -> Double {
        // Folder sizes are stored in GiB; use the same unit for the denominator.
        let gib = 1024.0 * 1024.0 * 1024.0
        if let volume = connectedVolumes.first(where: { $0.name == volumeName }) {
            if volume.totalBytes > 0 { return Double(volume.totalBytes) / gib }
            if volume.totalCapacityGB > 0 { return volume.totalCapacityGB * 1_000_000_000 / gib }
        }
        // Preserve capacity estimates for disconnected disks named with their size.
        if let range = volumeName.range(of: #"(?i)(?<![0-9])[0-9]+(?:[.,][0-9]+)?[ _]*TB(?=$|[^A-Za-z0-9])"#, options: .regularExpression) {
            let number = volumeName[range].prefix { $0.isNumber || $0 == "." || $0 == "," }
            if let terabytes = Double(number.replacingOccurrences(of: ",", with: ".")) {
                return terabytes * 1_000_000_000_000 / gib
            }
        }
        return 0
    }

    func isVolumeMounted(forPath path: String) -> Bool {
        let pathComponents = (path as NSString).pathComponents
        if pathComponents.count > 2 && pathComponents[1] == "Volumes" {
            let volumePath = "/Volumes/" + pathComponents[2]
            return FileManager.default.fileExists(atPath: volumePath)
        }
        return true
    }
    
    func updateOnlineStatus() {
        let fileManager = FileManager.default
        var hasChanges = false
        
        for index in projects.indices {
            let project = projects[index]
            if let localProjectIDs, !localProjectIDs.contains(project.id) { continue }
            let pathExists = fileManager.fileExists(atPath: project.path)
            let volMounted = isVolumeMounted(forPath: project.path)
            
            var newIsOnline = pathExists
            var newIsMissing = false
            
            if !pathExists {
                if volMounted {
                    newIsMissing = true
                    newIsOnline = false
                } else {
                    newIsMissing = false
                    newIsOnline = false
                }
            } else {
                newIsMissing = false
                newIsOnline = true
            }
            
            if newIsOnline != project.isOnline || newIsMissing != project.isMissing {
                projects[index] = VideoProject(
                    id: project.id,
                    name: project.name,
                    path: project.path,
                    date: project.date,
                    isOnline: newIsOnline,
                    volumeIdentifier: project.volumeIdentifier,
                    folderSize: project.folderSize,
                    folderContents: project.folderContents,
                    isAnalyzed: project.isAnalyzed,
                    billingStatus: project.billingStatus,
                    isMissing: newIsMissing,
                    deadline: project.deadline,
                    isCompleted: project.isCompleted,
                    comments: project.comments
                )
                hasChanges = true
            }
        }
        
        if hasChanges {
            saveData()
        }
    }
    
    func deleteProject(_ project: VideoProject) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects.remove(at: index)
            assignVolumeColors()
            saveData()
        }
    }
    
    // Aggiorna asincronamente il peso cartella su disco per un singolo progetto
    func updateProjectFolderSize(for projectId: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectId }) else { return }
        guard localProjectIDs?.contains(projectId) != false, projects[index].isOnline else { return }
        let path = projects[index].path
        let session = catalogSession
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let size = calculateFolderSizeInGB(atPath: path)
            DispatchQueue.main.async {
                guard let self = self, self.catalogSession == session, let idx = self.projects.firstIndex(where: { $0.id == projectId }) else { return }
                if abs(self.projects[idx].folderSize - size) > 0.001 || !self.projects[idx].isAnalyzed {
                    self.projects[idx].folderSize = size
                    self.projects[idx].isAnalyzed = true
                    self.saveData()
                }
            }
        }
    }
    
    // Pulisce percorsi non standard (es. //Volumes) e ricalcola in background lo spazio per i progetti a zero GB
    func sanitizePathsAndRefreshZeroSizes() {
        var hasChanges = false
        for i in 0..<projects.count {
            if projects[i].path.hasPrefix("//") {
                var cleanPath = projects[i].path
                while cleanPath.hasPrefix("//") {
                    cleanPath.removeFirst()
                }
                projects[i].path = cleanPath
                hasChanges = true
            }
        }
        if hasChanges {
            saveData()
        }
        
        let fm = FileManager.default
        let candidates = projects.filter {
            $0.folderSize <= 0.001 && ($0.isOnline || fm.fileExists(atPath: $0.path))
        }
        guard !candidates.isEmpty else { return }
        let session = catalogSession
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for candidate in candidates {
                let size = calculateFolderSizeInGB(atPath: candidate.path)
                if size > 0 {
                    DispatchQueue.main.async {
                        guard let self, self.catalogSession == session,
                              let idx = self.projects.firstIndex(where: { $0.id == candidate.id && $0.path == candidate.path }) else { return }
                        self.projects[idx].folderSize = size
                        self.projects[idx].isAnalyzed = true
                        self.projects[idx].isOnline = true
                        self.projects[idx].isMissing = false
                        self.saveData()
                    }
                }
            }
        }
    }
    
    func syncProjects(foundProjects: [VideoProject], scannedVolumes: [String], scannedRoots: [URL] = []) {
        var updated = projects
        let normalized: (String) -> String = { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let foundPaths = Set(foundProjects.map { normalized($0.path) })
        for found in foundProjects {
            if let i = updated.firstIndex(where: { normalized($0.path) == normalized(found.path) }) {
                let old = updated[i]
                updated[i] = VideoProject(id: old.id, name: found.name, path: found.path, date: old.date,
                    isOnline: true, volumeIdentifier: found.volumeIdentifier, folderSize: found.folderSize,
                    folderContents: found.folderContents, isAnalyzed: found.isAnalyzed, billingStatus: old.billingStatus,
                    isMissing: false, deadline: old.deadline, isCompleted: old.isCompleted, comments: old.comments)
                localProjectIDs?.insert(old.id)
            } else {
                updated.append(found)
                localProjectIDs?.insert(found.id)
            }
        }
        for i in updated.indices {
            let project = updated[i]
            if let localProjectIDs, !localProjectIDs.contains(project.id) { continue }
            let path = normalized(project.path)
            let covered = scannedRoots.contains { root in
                let base = normalized(root.path)
                return base == "/" || path == base || path.hasPrefix(base + "/")
            }
            if covered && !foundPaths.contains(path) && !FileManager.default.fileExists(atPath: path) {
                updated[i].isOnline = false
                updated[i].isMissing = true
            }
        }
        projects = updated
        assignVolumeColors()
    }

    func setLaunchAtLogin(enabled: Bool) {
        let appPath = Bundle.main.bundlePath
        let script: String
        if enabled {
            let removeScript = "tell application \"System Events\" to delete (every login item whose path is \"\(appPath)\")"
            let _ = NSAppleScript(source: removeScript)?.executeAndReturnError(nil)
            
            script = "tell application \"System Events\" to make new login item at end with properties {path:\"\(appPath)\", name:\"FolderFlow\", hidden:true}"
        } else {
            script = "tell application \"System Events\" to delete (every login item whose path is \"\(appPath)\")"
        }
        
        DispatchQueue.global(qos: .background).async {
            let appleScript = NSAppleScript(source: script)
            var error: NSDictionary?
            appleScript?.executeAndReturnError(&error)
            if let error = error {
                print("Errore Launch at Login: \(error)")
            }
        }
    }
    
    private func saveData() {
        guard !initializing, !storageReadOnly else { return }
        if let onCatalogChange { onCatalogChange(); return }
        // Salvataggio locale (UserDefaults)
        do {
            let projectsData = try JSONEncoder().encode(projects)
            defaults.set(projectsData, forKey: "SavedProjects")
        } catch {
            showError("Errore nel salvataggio progetti: \(error.localizedDescription)")
            return
        }
        
        do {
            let colorsData = try JSONEncoder().encode(volumeColors.mapValues { ColorRGB.fromColor($0) })
            defaults.set(colorsData, forKey: "VolumeColors")
        } catch {
            showError("Errore nel salvataggio colori: \(error.localizedDescription)")
        }

        // Salvataggio esterno (se configurato)
        saveExternalData()
        
        // Salvataggio percorsi monitorati
        do {
            let pathsData = try JSONEncoder().encode(monitoredPaths)
            defaults.set(pathsData, forKey: "MonitoredPaths")
        } catch {
            print("Errore nel salvataggio monitoredPaths: \(error.localizedDescription)")
        }
        
        // Backup locale di sicurezza
        createLocalBackup()
    }
    
    private func loadData() {
        // Carica progetti
        if let projectsData = defaults.data(forKey: "SavedProjects") {
            do {
                let projects = try JSONDecoder().decode([VideoProject].self, from: projectsData)
                // Valida e aggiorna lo stato online/offline senza filtrare
                self.projects = projects.map { project in
                    // Verifica se il percorso esiste e aggiorna lo stato
                    let fileManager = FileManager.default
                    let isOnline = fileManager.fileExists(atPath: project.path)
                    
                    if isOnline != project.isOnline {
                        // Aggiorna lo stato se è cambiato
                        return VideoProject(
                            id: project.id,
                            name: project.name,
                            path: project.path,
                            date: project.date,
                            isOnline: isOnline,
                            volumeIdentifier: project.volumeIdentifier,
                            folderSize: project.folderSize,
                            folderContents: project.folderContents,
                            isAnalyzed: project.isAnalyzed,
                            billingStatus: project.billingStatus,
                            deadline: project.deadline,
                            isCompleted: project.isCompleted,
                            comments: project.comments
                        )
                    }
                    return project
                }.filter { project in
                    // Filtra solo progetti con nome e path validi
                    !project.name.isEmpty && !project.path.isEmpty && !project.volumeIdentifier.isEmpty
                }
            } catch {
                showError("Errore nel caricamento progetti: \(error.localizedDescription)")
                defaults.set(projectsData, forKey: "UnreadableSavedProjects")
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                let recovery = getAvailableBackups().compactMap { url -> AppData? in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return try? decoder.decode(AppData.self, from: data)
                }.first
                if let recovery { self.projects = recovery.projects }
                else { self.storageReadOnly = true }
            }
        }

        // Older releases saved palette names and rebuilt the palette on every launch.
        // Regenerate that palette once; new RGB choices survive every refresh and restart.
        if let colorsData = defaults.data(forKey: "VolumeColors") {
            if let colors = try? JSONDecoder().decode([String: ColorRGB].self, from: colorsData) {
                volumeColors = colors.mapValues { $0.toColor() }
            } else if (try? JSONDecoder().decode([String: String].self, from: colorsData)) == nil {
                showError("Errore nel caricamento colori dei dischi.")
            }
        }

        // Carica percorsi monitorati
        if let pathsData = defaults.data(forKey: "MonitoredPaths") {
            do {
                self.monitoredPaths = try JSONDecoder().decode([String].self, from: pathsData)
            } catch {
                print("Errore nel caricamento monitoredPaths: \(error.localizedDescription)")
            }
        }
        
        // Assicurati che i colori siano assegnati anche al caricamento
        assignVolumeColors()
        
        // Pulisci percorsi anomali e calcola dimensioni se a 0 GB
        sanitizePathsAndRefreshZeroSizes()
    }
    
    // MARK: - External Data Management
    
    private func loadExternalDataPath() {
        externalDataPath = defaults.string(forKey: "ExternalDataPath")
    }
    
    func setExternalDataPath(_ path: String?) {
        externalDataPath = path
        if let path = path {
            defaults.set(path, forKey: "ExternalDataPath")
            // This path is a manual backup destination; automatic sync is managed by Firebase.
        } else {
            defaults.removeObject(forKey: "ExternalDataPath")
            fileWatchTimer?.invalidate()
            fileWatchTimer = nil
            lastLoadedFileModificationDate = nil
        }
    }
    
    func startMonitoringExternalFile() {
        fileWatchTimer?.invalidate()
        fileWatchTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.checkForExternalFileUpdates()
        }
    }
    
    func checkForExternalFileUpdates() {
        guard let path = externalDataPath, !path.isEmpty else { return }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else { return }
        
        do {
            let attributes = try fileManager.attributesOfItem(atPath: path)
            if let modDate = attributes[.modificationDate] as? Date {
                if lastLoadedFileModificationDate == nil || modDate > lastLoadedFileModificationDate! {
                    loadExternalData()
                }
            }
        } catch {
            // Ignora errori temporanei
        }
    }
    
    func saveExternalData() {
        guard !initializing, !storageReadOnly, onCatalogChange == nil,
              let path = externalDataPath, !path.isEmpty else { return }
        let snapshot = AppData(projects: projects, volumeColors: volumeColors.mapValues { ColorRGB.fromColor($0) },
                               monitoredPaths: monitoredPaths)
        externalIO.async { [weak self] in
            do {
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(snapshot)
                let file = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                DispatchQueue.main.async {
                    self?.lastSaveDate = Date()
                    self?.lastLoadedFileModificationDate = date
                    self?.isSavingExternal = false
                }
            } catch { self?.showError("Errore nel salvataggio file: \(error.localizedDescription)") }
        }
    }

    func loadExternalData() {
        guard onCatalogChange == nil, let path = externalDataPath, !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let incoming = try decoder.decode(AppData.self, from: data)
            for project in incoming.projects {
                if !projects.contains(where: { $0.id == project.id || $0.path == project.path }) { projects.append(project) }
            }
            volumeColors.merge(incoming.volumeColors.mapValues { $0.toColor() }) { local, _ in local }
            if monitoredPaths.isEmpty, let paths = incoming.monitoredPaths { monitoredPaths = paths }
            lastLoadedFileModificationDate = try URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        } catch { showError("Il file esterno non è leggibile. La copia locale è conservata: \(error.localizedDescription)") }
    }

    // MARK: - Gestione Backup Locali
    
    func getBackupDirectory() -> URL {
        let fileManager = FileManager.default
        if let backupDirectory = catalogBackupDirectory ?? backupDirectory {
            try? fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            return backupDirectory
        }
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            let homeDir = fileManager.homeDirectoryForCurrentUser
            let fallbackURL = homeDir.appendingPathComponent("Library/Application Support/FolderFlow/Backups")
            try? fileManager.createDirectory(at: fallbackURL, withIntermediateDirectories: true, attributes: nil)
            return fallbackURL
        }
        let backupDirURL = appSupportURL.appendingPathComponent("FolderFlow/Backups")
        try? fileManager.createDirectory(at: backupDirURL, withIntermediateDirectories: true, attributes: nil)
        return backupDirURL
    }
    
    // MARK: - Monitored Paths
    func addMonitoredPath(_ path: String) {
        if !monitoredPaths.contains(path) {
            monitoredPaths.append(path)
            saveData()
        }
    }
    
    func removeMonitoredPath(at indexSet: IndexSet) {
        monitoredPaths.remove(atOffsets: indexSet)
        saveData()
    }
    
    func removeMonitoredPath(_ path: String) {
        if let idx = monitoredPaths.firstIndex(of: path) {
            monitoredPaths.remove(at: idx)
            saveData()
        }
    }
    
    func clearMonitoredPaths() {
        monitoredPaths.removeAll()
        saveData()
    }
    
    func createLocalBackup(completion: ((Result<URL, Error>) -> Void)? = nil) {
        let catalogCopy = catalogExport?()
        guard !projects.isEmpty || catalogCopy != nil else {
            completion?(.failure(CatalogTransferError.noCatalog))
            return
        }
        let snapshot = AppData(projects: projects, volumeColors: volumeColors.mapValues { ColorRGB.fromColor($0) },
                               monitoredPaths: monitoredPaths, catalog: catalogCopy?.0, sourceDeviceID: catalogCopy?.1)
        let backupDir = getBackupDirectory()
        externalIO.async { [weak self] in
            do {
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
                let file = backupDir.appendingPathComponent("backup_\(formatter.string(from: Date()))_\(UUID().uuidString).json")
                try encoder.encode(snapshot).write(to: file, options: .atomic)
                self?.cleanupOldBackups(in: backupDir)
                DispatchQueue.main.async { completion?(.success(file)) }
            } catch {
                DispatchQueue.main.async {
                    if let completion { completion(.failure(error)) }
                    else { self?.showError("Impossibile creare la copia di sicurezza: \(error.localizedDescription)") }
                }
            }
        }
    }

    func createRecoveryBackup() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            createLocalBackup { continuation.resume(with: $0) }
        }
    }

    func catalogExportData() throws -> Data {
        let copy = catalogExport?()
        let data = AppData(projects: projects, volumeColors: volumeColors.mapValues { ColorRGB.fromColor($0) },
                           monitoredPaths: monitoredPaths, catalog: copy?.0, sourceDeviceID: copy?.1)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(data)
    }

    func cleanupOldBackups(in directory: URL) {
        let fileManager = FileManager.default
        do {
            let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey], options: [])
            let backupFiles = files.filter { $0.lastPathComponent.hasPrefix("backup_") && $0.pathExtension == "json" }
            let sortedBackupFiles = backupFiles.sorted { $0.lastPathComponent > $1.lastPathComponent }
            
            if sortedBackupFiles.count > 5 {
                for i in 5..<sortedBackupFiles.count {
                    let fileToDelete = sortedBackupFiles[i]
                    try fileManager.removeItem(at: fileToDelete)
                }
            }
        } catch {
            print("Errore nella pulizia dei vecchi backup: \(error.localizedDescription)")
        }
    }
    
    func getAvailableBackups() -> [URL] {
        let fileManager = FileManager.default
        let backupDir = getBackupDirectory()
        do {
            let files = try fileManager.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: [.creationDateKey], options: [])
            let backupFiles = files.filter { $0.lastPathComponent.hasPrefix("backup_") && $0.pathExtension == "json" }
            return backupFiles.sorted { $0.lastPathComponent > $1.lastPathComponent }
        } catch {
            return []
        }
    }
    
    @discardableResult
    func restoreFromBackup(at url: URL) -> Bool { importFromFile(at: url.path) }

    @discardableResult
    func restoreFromLastLocalBackup() -> Bool {
        let backups = getAvailableBackups()
        guard let lastBackup = backups.first else {
            return false
        }
        
        let success = restoreFromBackup(at: lastBackup)
        if success {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .medium
            formatter.locale = Locale(identifier: "it_IT")
            
            let dateStr: String
            if let date = creationDateOfFile(at: lastBackup) {
                dateStr = formatter.string(from: date)
            } else {
                dateStr = "ultimo disponibile"
            }
            showError("Attenzione: caricamento file esterno fallito o file mancante. Ripristinato backup locale del \(dateStr).")
        }
        return success
    }
    
    private func creationDateOfFile(at url: URL) -> Date? {
        let fileManager = FileManager.default
        if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
           let creationDate = attributes[.creationDate] as? Date {
            return creationDate
        }
        return nil
    }
    
    func exportToFile(at path: String) -> Bool {
        do {
            let file = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try catalogExportData().write(to: file, options: .atomic)
            return true
        } catch { showError("Errore nell’esportazione: \(error.localizedDescription)"); return false }
    }

    func importFromFile(at path: String) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            showError("File non trovato: \(path)")
            return false
        }
        
        do {
            let jsonData = try Data(contentsOf: URL(fileURLWithPath: path))
            
            if let catalogImport {
                let deviceID = catalogExport?()?.1 ?? "local"
                let transfer = try CatalogTransfer.decode(jsonData, name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, deviceID: deviceID)
                try catalogImport(transfer.catalog, transfer.sourceDeviceID)
                return true
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let appData = try decoder.decode(AppData.self, from: jsonData)
            
            // Sostituisci completamente i progetti e i colori
            projects = appData.projects
            volumeColors = appData.volumeColors.mapValues { $0.toColor() }
            if let paths = appData.monitoredPaths { monitoredPaths = paths }
            localProjectIDs = Set(projects.map(\.id))
            assignVolumeColors()
            saveData()
            
            return true
        } catch {
            showError("Errore nell'import: \(error.localizedDescription)")
            return false
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var dataManager: DataManager
    @EnvironmentObject var folderScanner: FolderScanner
    var onShowSettings: () -> Void = {}
    @State private var selectedProjectID: UUID?
    @State private var showingFolderSelection = false
    @State private var showingNewProject = false
    @State private var searchText = ""
    @State private var selectedVolumeFilter: String? = nil
    
    private var selectedProject: VideoProject? {
        dataManager.projects.first { $0.id == selectedProjectID }
    }
    
    // Computed property per filtrare i progetti in base alla ricerca e al filtro volume
    private var filteredProjects: [VideoProject] {
        var base = dataManager.projects
        if let volFilter = selectedVolumeFilter {
            base = base.filter { $0.volumeIdentifier == volFilter }
        }
        if !searchText.isEmpty {
            base = base.filter { project in
                project.name.localizedCaseInsensitiveContains(searchText) ||
                project.path.localizedCaseInsensitiveContains(searchText) ||
                project.volumeIdentifier.localizedCaseInsensitiveContains(searchText)
            }
        }
        return base.sorted { $0.name > $1.name }
    }
    
    var body: some View {
        let manager = dataManager
        return VStack(spacing: 0) {
            HStack(spacing: 18) {
                projectToolbar.frame(width: 480)
                Spacer(minLength: 24)
                AccountToolbarButton(action: onShowSettings)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(StudioTheme.sidebar)
            Divider().overlay(StudioTheme.line)
            HSplitView {
                // Sidebar sinistra
                VStack(spacing: 0) {
                    // Area centrale: Lista progetti o stato scansione
                    if folderScanner.isScanning {
                        VStack(spacing: 14) {
                            VStack(spacing: 10) {
                                ProgressView(value: folderScanner.scanProgress)
                                    .progressViewStyle(LinearProgressViewStyle(tint: StudioTheme.green))
                                    .scaleEffect(y: 1.5)

                                HStack {
                                    Text("Hard Disk \(folderScanner.completedHardDisks)/\(folderScanner.totalHardDisks)")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.white.opacity(0.8))
                                    Spacer()
                                    Text("\(Int(folderScanner.scanProgress * 100))%")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundColor(StudioTheme.green)
                                }
                            }

                            VStack(spacing: 6) {
                                if !folderScanner.currentHardDisk.isEmpty {
                                    HStack(spacing: 8) {
                                        Image(systemName: "externaldrive.fill")
                                            .foregroundColor(StudioTheme.accent)
                                            .font(.system(size: 16))
                                        Text(folderScanner.currentHardDisk)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(StudioTheme.text)
                                    }
                                }
                            
                                Text(folderScanner.currentPath)
                                    .font(.system(size: 12))
                                    .foregroundColor(StudioTheme.secondary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                            }
                        }
                        .padding(20)
                        .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(StudioTheme.line, lineWidth: 1)
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        Spacer()
                    } else if dataManager.projects.isEmpty {
                        HardDiskSelectionView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        if filteredProjects.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 32, weight: .light))
                                    .foregroundColor(.white.opacity(0.45))
                            
                                Text("Nessun progetto trovato")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(StudioTheme.text)
                            
                                Text("Prova a modificare la ricerca o il filtro del disco selezionato.")
                                    .font(.system(size: 12))
                                    .foregroundColor(StudioTheme.secondary)
                                    .multilineTextAlignment(.center)
                            
                                if selectedVolumeFilter != nil || !searchText.isEmpty {
                                    Button("Mostra tutti i progetti") {
                                        selectedVolumeFilter = nil
                                        searchText = ""
                                    }
                                    .buttonStyle(ModernButtonStyle(color: StudioTheme.accent))
                                    .padding(.top, 4)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(32)
                        } else {
                            Group {
                                if #available(macOS 14.5, *) {
                                Table(filteredProjects, selection: $selectedProjectID) {
                                    TableColumn("Progetti") { project in
                                        ProjectRow(project: project, isSelected: selectedProjectID == project.id,
                                                   volumeColor: manager.getVolumeColor(for: project.volumeIdentifier))
                                    }
                                    .width(min: 160, ideal: 260)
                                    TableColumn("In corso") { project in
                                        ProjectStatusDot(active: !project.isCompleted, color: StudioTheme.accent,
                                                         label: project.isCompleted ? "Concluso" : "In lavorazione")
                                    }
                                    .width(64).alignment(.center)
                                    TableColumn("Da fatt.") { project in
                                        ProjectStatusDot(active: project.billingStatus == .toBill, color: StudioTheme.amber,
                                                         label: project.billingStatus.rawValue)
                                    }
                                    .width(64).alignment(.center)
                                }
                                } else {
                                Table(filteredProjects, selection: $selectedProjectID) {
                                    TableColumn("Progetti") { project in
                                        ProjectRow(project: project, isSelected: selectedProjectID == project.id,
                                                   volumeColor: manager.getVolumeColor(for: project.volumeIdentifier))
                                    }
                                    .width(min: 160, ideal: 260)
                                    TableColumn("In corso") { project in
                                        ProjectStatusDot(active: !project.isCompleted, color: StudioTheme.accent,
                                                         label: project.isCompleted ? "Concluso" : "In lavorazione")
                                    }
                                    .width(64)
                                    TableColumn("Da fatt.") { project in
                                        ProjectStatusDot(active: project.billingStatus == .toBill, color: StudioTheme.amber,
                                                         label: project.billingStatus.rawValue)
                                    }
                                    .width(64)
                                }
                                }
                            }
                            .tableStyle(.inset(alternatesRowBackgrounds: false))
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .scrollContentBackground(.hidden)
                            .accessibilityLabel("Progetti: usa le frecce su e giù per navigare")
                        }
                    }
                
                    // Sezione Hard Disk Collegati in basso a sinistra (Proposta 2 - Lista Finder Compatta Dinamica)
                    ConnectedVolumesPanel(
                        selectedVolumeFilter: $selectedVolumeFilter
                    )
                }
                .frame(minWidth: 420, idealWidth: 460, maxWidth: 520)
                .background(StudioTheme.sidebar)
                .overlay(
                    // Bordo di separazione verticale a destra pulito e sottile
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 1),
                    alignment: .trailing
                )

                ZStack {
                    if let project = selectedProject {
                        ProjectDetailView(project: project, onDelete: {
                            selectedProjectID = nil
                        })
                    } else {
                        DashboardView(onSelectProject: { project in
                            selectedProjectID = project.id
                        })
                    }
                }
                .frame(minWidth: 660, maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.clear)
            }
        }
        .background(StudioTheme.background)
        .sheet(isPresented: $showingFolderSelection) {
            FolderSelectionView()
        }
        .alert("FolderFlow", isPresented: $dataManager.hasError) {
            Button("OK", role: .cancel) { dataManager.clearError() }
        } message: { Text(dataManager.errorMessage ?? "Si è verificato un errore.") }
        .alert("Scansione", isPresented: $folderScanner.hasError) {
            Button("OK", role: .cancel) { folderScanner.clearError() }
        } message: { Text(folderScanner.errorMessage ?? "Scansione non completata.") }
        .sheet(isPresented: $showingNewProject) {
            NewProjectView(onProjectCreated: { newProject in
                selectedProjectID = newProject.id
            })
        }
    }
    private var projectToolbar: some View {
        HStack(spacing: 8) {
            Button { selectedProjectID = nil } label: {
                Image(nsImage: NSImage(named: "app_icon") ?? NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .help("FolderFlow · Torna alla panoramica (⌘1)")
            .accessibilityLabel("Panoramica")
            .keyboardShortcut("1", modifiers: .command)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                TextField("Cerca progetti", text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Cerca per nome, percorso o disco")
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .accessibilityLabel("Cancella ricerca")
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 9)
            .frame(height: 34)
            .background(StudioTheme.background, in: RoundedRectangle(cornerRadius: 7))

            Button {
                Task { await folderScanner.syncAllVolumes() }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(StudioTheme.accent)
                    .frame(width: 42, height: 38)
                    .background(StudioTheme.accent.opacity(0.22), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(StudioTheme.accent.opacity(0.45), lineWidth: 1))
                    .opacity(folderScanner.isScanning ? 0.45 : 1)
            }
            .disabled(folderScanner.isScanning)
            .help("Aggiorna dai dischi collegati (⌘R)")
            .accessibilityLabel("Aggiorna dai dischi collegati")
            .keyboardShortcut("r", modifiers: .command)
            Button { showingNewProject = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(StudioTheme.background)
                    .frame(width: 42, height: 38)
                    .background(Color(red: 0.96, green: 0.57, blue: 0.26), in: RoundedRectangle(cornerRadius: 9))
            }
            .help("Nuovo progetto (⌘N)")
            .accessibilityLabel("Nuovo progetto")
            .keyboardShortcut("n", modifiers: .command)
        }
        .buttonStyle(.plain)
        .foregroundColor(StudioTheme.secondary)
    }

}

// MARK: - Pannello Dischi Collegati (In basso a sinistra - Dinamico, Ultra-Compatto ed Espandibile)
struct ConnectedVolumesPanel: View {
    @EnvironmentObject var dataManager: DataManager
    @Binding var selectedVolumeFilter: String?
    @State private var isExpanded: Bool = false
    
    // Verifica se un volume è il disco di sistema
    private func isSystemVolume(_ vol: MountedVolumeInfo) -> Bool {
        vol.url.path == "/" || vol.name == "Macintosh HD" || !vol.url.path.hasPrefix("/Volumes/")
    }
    
    // Show connected disks selected for use by FolderFlow.
    private var displayedVolumes: [MountedVolumeInfo] {
        let monitored = dataManager.monitoredPaths
        let selected = dataManager.connectedVolumes.filter { volume in
            monitored.contains(volume.url.path)
                || monitored.contains { URL(fileURLWithPath: $0).lastPathComponent == volume.name }
                || (isSystemVolume(volume) && (monitored.contains("/") || monitored.contains { $0.contains("Macintosh HD") }))
        }
        return orderedMonitoringDisks(selected, monitoredPaths: monitored)
    }

    // Calcola il peso massimo per proporzionare le barre
    private var maxVolumeReferenceGB: Double {
        var maxVal: Double = 100.0
        for vol in displayedVolumes {
            let projGB = projectsSizeGB(for: vol.name)
            let val = projGB > 0 ? projGB : vol.totalCapacityGB
            if val > maxVal { maxVal = val }
        }
        return maxVal
    }
    
    private func projectsCount(for volumeName: String) -> Int {
        dataManager.projects.filter { $0.volumeIdentifier == volumeName }.count
    }
    
    private func projectsSizeGB(for volumeName: String) -> Double {
        dataManager.projects
            .filter { $0.volumeIdentifier == volumeName }
            .reduce(0.0) { $0 + $1.folderSize }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Header compatto cliccabile per espandere/comprimere
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(StudioTheme.accent)
                    
                    Image(systemName: "externaldrive.connected.to.line.below.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(StudioTheme.accent)
                    
                    Text("Dischi (\(displayedVolumes.count))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                    
                    Text(isExpanded ? "Comprimi" : "Dettagli")
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                    
                    Spacer()
                    

                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            
            if displayedVolumes.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "externaldrive.badge.questionmark")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.45))
                    Text(dataManager.monitoredPaths.isEmpty ? "Nessun disco selezionato" : "Nessun disco selezionato collegato")
                        .font(.system(size: 10))
                        .foregroundColor(StudioTheme.secondary)
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            } else if !isExpanded {
                // Compact disk grid wraps to the available sidebar width.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                        // Pulsante All Disks per mostrare tutti i progetti contemporaneamente
                        let isAllActive = (selectedVolumeFilter == nil)
                        Button(action: {
                            selectedVolumeFilter = nil
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "square.grid.2x2.fill")
                                    .font(.system(size: 8))
                                Text("Tutti i dischi")
                                    .font(.system(size: 10, weight: isAllActive ? .bold : .medium))
                            }
                            .foregroundColor(isAllActive ? .white : .white.opacity(0.85))
                            .padding(.horizontal, 8)
                            .frame(height: 30)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isAllActive ? StudioTheme.accent.opacity(0.38) : Color.white.opacity(0.06))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(isAllActive ? StudioTheme.accent.opacity(0.85) : Color.white.opacity(0.09), lineWidth: 1)
                                    )
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Mostra tutti i progetti di tutti i dischi")
                        
                        ForEach(displayedVolumes) { vol in
                            let volColor = dataManager.getVolumeColor(for: vol.name)
                            let isSelected = (selectedVolumeFilter == vol.name)
                            let isSys = isSystemVolume(vol)
                            
                            Button(action: {
                                if selectedVolumeFilter == vol.name {
                                    selectedVolumeFilter = nil
                                } else {
                                    selectedVolumeFilter = vol.name
                                }
                            }) {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(volColor)
                                        .frame(width: 5.5, height: 5.5)
                                    
                                    if isSys {
                                        Image(systemName: "internaldrive")
                                            .font(.system(size: 8))
                                            .foregroundColor(StudioTheme.secondary)
                                    }
                                    
                                    Text(vol.name)
                                        .font(.system(size: 10, weight: isSelected ? .bold : .medium))
                                        .foregroundColor(isSelected ? .white : .white.opacity(0.85))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 7)
                                .frame(height: 30)
                                .frame(maxWidth: .infinity)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(isSelected ? volColor.opacity(0.32) : Color.white.opacity(0.06))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(isSelected ? volColor.opacity(0.85) : Color.white.opacity(0.09), lineWidth: 1)
                                        )
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help("Filtra progetti per \(vol.name)")
                        }
                }
                .padding(.top, 8)
            } else {
                // STATO ESPANSO: Lista Finder completa con pulsante All Disks in testa
                VStack(spacing: 3) {
                    let isAllActive = (selectedVolumeFilter == nil)
                    Button(action: {
                        selectedVolumeFilter = nil
                    }) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(StudioTheme.accent)
                                .frame(width: 5, height: 5)
                            
                            Image(systemName: "square.grid.2x2.fill")
                                .font(.system(size: 10.5))
                                .foregroundColor(StudioTheme.accent)
                                .frame(width: 13)
                            
                            Text("Tutti i dischi")
                                .font(.system(size: 10.5, weight: isAllActive ? .bold : .medium))
                                .foregroundColor(isAllActive ? .white : .white.opacity(0.85))
                            
                            Spacer()
                            
                            Text("Tutti")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(isAllActive ? StudioTheme.accent : .white.opacity(0.55))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.white.opacity(isAllActive ? 0.18 : 0.06)))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isAllActive ? StudioTheme.accent.opacity(0.28) : Color.white.opacity(0.035))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(isAllActive ? StudioTheme.accent.opacity(0.75) : Color.clear, lineWidth: 1)
                                )
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    ForEach(displayedVolumes) { vol in
                        let volColor = dataManager.getVolumeColor(for: vol.name)
                        let projCount = projectsCount(for: vol.name)
                        let projGB = projectsSizeGB(for: vol.name)
                        let isSelected = (selectedVolumeFilter == vol.name)
                        let isSys = isSystemVolume(vol)
                        
                        let diskTotal = vol.totalCapacityGB > 0 ? vol.totalCapacityGB : 1000.0
                        let diskUsed = vol.usedCapacityGB
                        let diskPercent: Double = min(100.0, max(0.0, (diskUsed / diskTotal) * 100.0))
                        let barFraction: Double = min(1.0, max(0.06, diskUsed / diskTotal))
                        let percentDisplay: String = {
                            if diskPercent >= 99.0 && diskPercent < 100.0 && vol.availableCapacityGB > 0.5 {
                                return "99%"
                            }
                            return "\(Int(round(diskPercent)))%"
                        }()
                        
                        Button(action: {
                            if selectedVolumeFilter == vol.name {
                                selectedVolumeFilter = nil
                            } else {
                                selectedVolumeFilter = vol.name
                            }
                        }) {
                            HStack(spacing: 8) {
                                // Pallino disco collegato (Online)
                                Circle()
                                    .fill(StudioTheme.green)
                                    .frame(width: 5, height: 5)
                                
                                // Icona HD (o interna per sistema)
                                Image(systemName: isSys ? "internaldrive.fill" : "externaldrive.fill")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(volColor)
                                    .frame(width: 13)
                                
                                // Nome volume
                                Text(vol.name)
                                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                                    .foregroundColor(.white.opacity(isSelected ? 1.0 : 0.9))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(width: 120, alignment: .leading)
                                
                                // Barra proporzionale (calcolata sulla reale capienza fisica del singolo disco)
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(Color.white.opacity(0.08))
                                            .frame(height: 3.5)
                                        Capsule()
                                            .fill(volColor.opacity(0.95))
                                            .frame(width: max(5, geo.size.width * barFraction), height: 3.5)
                                    }
                                    .frame(maxHeight: .infinity, alignment: .center)
                                }
                                .frame(height: 9)
                                
                                // Percentuale reale di riempimento del disco
                                Text(percentDisplay)
                                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                    .foregroundColor(volColor.opacity(0.95))
                                    .frame(width: 32, alignment: .trailing)
                                
                                // Spazio reale utilizzato sul disco in TB / GB
                                Text(formatStorageSize(diskUsed))
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.85))
                                    .frame(width: 48, alignment: .trailing)
                                
                                // Badge progetti tracciati da FolderFlow
                                Text("\(projCount)")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundColor(projCount > 0 ? .white : .white.opacity(0.5))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(
                                        Capsule()
                                            .fill(projCount > 0 ? volColor.opacity(0.28) : Color.white.opacity(0.07))
                                    )
                                    .frame(width: 28, alignment: .trailing)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isSelected ? volColor.opacity(0.18) : Color.white.opacity(0.035))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(isSelected ? volColor.opacity(0.75) : Color.clear, lineWidth: 1)
                                    )
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("\(vol.name): \(formatStorageSize(diskUsed)) usati su \(formatStorageSize(diskTotal)) (\(formatStorageSize(vol.availableCapacityGB)) disponibili)\nProgetti FolderFlow: \(projCount) (\(formatStorageSize(projGB)))")
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.35))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }
}

// Strutture dati per i grafici
struct DiskUsageData: Identifiable {
    var id: String { volume }
    let volume: String
    let sizeGB: Double
    let percent: Double?
    let color: Color
}

struct BillingChartData: Identifiable {
    let id = UUID()
    let status: String
    let count: Int
    let color: Color
}

enum DashboardFilterMode: Equatable {
    case overview
    case inCorso
    case daFatturare
    case conclusi
    case fatturati
}

// Nuova DashboardView per le statistiche con supporto Drill-Down
struct DashboardView: View {
    @EnvironmentObject var dataManager: DataManager
    @State private var selectedYear: String = "Tutti"
    @State private var activeFilterMode: DashboardFilterMode = .overview
    @State private var filterSearchText: String = ""
    var onSelectProject: ((VideoProject) -> Void)? = nil
    
    private var availableYears: [String] {
        ["Tutti"] + Set(dataManager.projects.map(dataManager.projectYear)).sorted(by: >)
    }

    private var filteredProjects: [VideoProject] {
        if selectedYear == "Tutti" { return dataManager.projects }
        return dataManager.projects.filter { dataManager.projectYear($0) == selectedYear }
    }

    private var diskUsageData: [DiskUsageData] {
        dataManager.diskUsage(for: filteredProjects)
    }

    // Calcola i dati di fatturazione usando solo i progetti filtrati
    private var billingData: [BillingChartData] {
        let daFatturare = filteredProjects.filter { $0.billingStatus == .toBill }
        let fatturati = filteredProjects.filter { $0.billingStatus == .billed }
        
        return [
            BillingChartData(status: "Da Fatturare", count: daFatturare.count, color: BillingStatus.toBill.color),
            BillingChartData(status: "Fatturati", count: fatturati.count, color: BillingStatus.billed.color)
        ]
    }
    
    // Titolo e stile per la vista drill-down
    private var currentFilterTitle: String {
        switch activeFilterMode {
        case .overview: return ""
        case .inCorso: return "Progetti in Corso"
        case .daFatturare: return "Progetti da Fatturare"
        case .conclusi: return "Progetti Conclusi"
        case .fatturati: return "Progetti Fatturati"
        }
    }
    
    private var currentFilterIcon: String {
        switch activeFilterMode {
        case .overview: return ""
        case .inCorso: return "play.circle.fill"
        case .daFatturare: return BillingStatus.toBill.icon
        case .conclusi: return "checkmark.circle.fill"
        case .fatturati: return BillingStatus.billed.icon
        }
    }
    
    private var currentFilterColor: Color {
        switch activeFilterMode {
        case .overview: return .white
        case .inCorso: return StudioTheme.amber
        case .daFatturare: return BillingStatus.toBill.color
        case .conclusi: return StudioTheme.green
        case .fatturati: return BillingStatus.billed.color
        }
    }
    
    private var currentFilteredProjects: [VideoProject] {
        let baseList: [VideoProject]
        switch activeFilterMode {
        case .overview: baseList = []
        case .inCorso: baseList = filteredProjects.filter { !$0.isCompleted }
        case .daFatturare: baseList = filteredProjects.filter { $0.billingStatus == .toBill }
        case .conclusi: baseList = filteredProjects.filter { $0.isCompleted }
        case .fatturati: baseList = filteredProjects.filter { $0.billingStatus == .billed }
        }
        
        let q = filterSearchText.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return baseList }
        return baseList.filter {
            $0.name.localizedCaseInsensitiveContains(q) ||
            $0.volumeIdentifier.localizedCaseInsensitiveContains(q)
        }
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if activeFilterMode != .overview {
                    // ==========================================
                    // VISTA DRILL-DOWN (SOLO I PROGETTI FILTRATI)
                    // ==========================================
                    VStack(alignment: .leading, spacing: 18) {
                        // Barra superiore: pulsante freccia indietro + ricerca
                        HStack(spacing: 20) {
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    activeFilterMode = .overview
                                    filterSearchText = ""
                                }
                            }) {
                                HStack(spacing: 7) {
                                    Image(systemName: "chevron.left")
                                        .font(.system(size: 13, weight: .bold))
                                    Text("Torna alla Dashboard")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                .foregroundColor(StudioTheme.accent)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 9)
                                        .fill(StudioTheme.accent.opacity(0.12))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 9)
                                                .stroke(StudioTheme.accent.opacity(0.35), lineWidth: 1)
                                        )
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                            
                            Spacer()
                            
                            // Campo di ricerca veloce
                            HStack(spacing: 8) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.45))
                                TextField("Filtra per nome o volume...", text: $filterSearchText)
                                    .textFieldStyle(PlainTextFieldStyle())
                                    .font(.system(size: 12))
                                    .foregroundColor(StudioTheme.text)
                                if !filterSearchText.isEmpty {
                                    Button(action: { filterSearchText = "" }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 11))
                                            .foregroundColor(StudioTheme.secondary)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6.5)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.white.opacity(0.06))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioTheme.line, lineWidth: 1))
                            )
                            .frame(width: 250)
                        }
                        
                        // Titolo e contatori
                        HStack(alignment: .center, spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 11)
                                    .fill(currentFilterColor.opacity(0.18))
                                    .frame(width: 44, height: 44)
                                Image(systemName: currentFilterIcon)
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundColor(currentFilterColor)
                            }
                            
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 9) {
                                    Text(currentFilterTitle)
                                        .font(.system(size: 26, weight: .bold))
                                        .foregroundColor(StudioTheme.text)
                                    
                                    Text("\(currentFilteredProjects.count)")
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                        .foregroundColor(currentFilterColor)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(currentFilterColor.opacity(0.2)))
                                }
                                
                                let totalGB = currentFilteredProjects.reduce(0.0) { $0 + $1.folderSize }
                                Text("\(currentFilteredProjects.count) progetti • Spazio occupato: \(formatStorageSize(totalGB)) • Clicca su un progetto per aprirne la scheda")
                                    .font(.system(size: 12))
                                    .foregroundColor(StudioTheme.secondary)
                            }
                            
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        
                        // Elenco progetti
                        if currentFilteredProjects.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "tray")
                                    .font(.system(size: 38))
                                    .foregroundColor(.white.opacity(0.3))
                                Text(filterSearchText.isEmpty ? "Nessun progetto in questa sezione" : "Nessun progetto corrisponde alla ricerca")
                                    .font(.system(size: 14))
                                    .foregroundColor(StudioTheme.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 60)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(StudioTheme.surface)
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
                            )
                        } else {
                            LazyVStack(spacing: 8) {
                                ForEach(currentFilteredProjects) { project in
                                    let volColor = dataManager.getVolumeColor(for: project.volumeIdentifier)
                                    
                                    Button(action: {
                                        onSelectProject?(project)
                                    }) {
                                        HStack(spacing: 12) {
                                            Circle()
                                                .fill(volColor)
                                                .frame(width: 8, height: 8)
                                            
                                            Text(project.name)
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundColor(StudioTheme.text)
                                                .lineLimit(1)
                                            
                                            Spacer()
                                            
                                            // Badge Volume
                                            Text(project.volumeIdentifier)
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundColor(volColor)
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 2.5)
                                                .background(Capsule().fill(volColor.opacity(0.18)))
                                            
                                            // Dimensione
                                            Text(formatStorageSize(project.folderSize))
                                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                                .foregroundColor(.white.opacity(0.75))
                                                .frame(width: 65, alignment: .trailing)
                                            
                                            // Badge Stato
                                            if project.isCompleted {
                                                Text("Concluso")
                                                    .font(.system(size: 10, weight: .semibold))
                                                    .foregroundColor(StudioTheme.green)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Capsule().fill(StudioTheme.green.opacity(0.16)))
                                            } else {
                                                Text("In Corso")
                                                    .font(.system(size: 10, weight: .semibold))
                                                    .foregroundColor(StudioTheme.amber)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Capsule().fill(StudioTheme.amber.opacity(0.16)))
                                            }
                                            
                                            // Badge Fatturazione
                                            Text(project.billingStatus.rawValue)
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundColor(project.billingStatus.color)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Capsule().fill(project.billingStatus.color.opacity(0.16)))
                                            
                                            // Pulsante Apri in Finder
                                            Button(action: {
                                                NSWorkspace.shared.open(URL(fileURLWithPath: project.path))
                                            }) {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "arrow.up.forward.app")
                                                        .font(.system(size: 10))
                                                    Text("Apri")
                                                        .font(.system(size: 10.5, weight: .medium))
                                                }
                                                .foregroundColor(StudioTheme.accent)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .fill(StudioTheme.accent.opacity(0.14))
                                                        .overlay(
                                                            RoundedRectangle(cornerRadius: 6)
                                                                .stroke(StudioTheme.accent.opacity(0.3), lineWidth: 0.8)
                                                        )
                                                )
                                            }
                                            .buttonStyle(PlainButtonStyle())
                                            .help("Apri cartella nel Finder")
                                            
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundColor(.white.opacity(0.35))
                                        }
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10)
                                                .fill(Color.black.opacity(0.18))
                                                .background(
                                                    RoundedRectangle(cornerRadius: 10)
                                                        .fill(StudioTheme.surface)
                                                        .opacity(0.7)
                                                )
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 10)
                                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                                )
                                        )
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                        }
                    }
                } else {
                    // ==========================================
                    // PANORAMICA DASHBOARD (OVERVIEW)
                    // ==========================================
                    
                    // Header con selettore anno e pulsante Impostazioni spostato a destra
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Panoramica")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundColor(StudioTheme.text)
                            Text("Progetti, consegne e archivio.")
                                .font(.system(size: 12.5))
                                .foregroundColor(StudioTheme.secondary)
                        }
                        
                        if availableYears.count > 1 {
                            Divider().frame(height: 32).padding(.horizontal, 12)
                            Image(systemName: "calendar").foregroundColor(StudioTheme.secondary)
                            InlineYearWheel(selection: $selectedYear, options: availableYears)
                                .frame(width: 104, height: 34)
                        }
                        Spacer()
                    }
                    .padding(.bottom, 4)
                    
                    // Generali e Stato (Cards interattive cliccabili)
                    HStack(spacing: 20) {
                        DashboardCard(
                            title: "Tutti i progetti",
                            value: "\(filteredProjects.count)",
                            icon: "folder.fill",
                            color: StudioTheme.accent,
                            isClickable: false,
                            action: nil
                        )
                        
                        let inCorso = filteredProjects.filter { !$0.isCompleted }
                        DashboardCard(
                            title: "In corso",
                            value: "\(inCorso.count)",
                            icon: "play.circle.fill",
                            color: StudioTheme.amber,
                            isClickable: true,
                            action: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    activeFilterMode = .inCorso
                                }
                            }
                        )
                        
                        let conclusi = filteredProjects.filter { $0.isCompleted }
                        DashboardCard(
                            title: "Conclusi",
                            value: "\(conclusi.count)",
                            icon: "checkmark.circle.fill",
                            color: StudioTheme.green,
                            isClickable: true,
                            action: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    activeFilterMode = .conclusi
                                }
                            }
                        )
                    }
                    
                    // Da Fatturare vs Fatturati (Cards interattive cliccabili)
                    HStack(spacing: 20) {
                        let bData = billingData
                        let toBill = bData.first(where: { $0.status == "Da Fatturare" })!
                        let billed = bData.first(where: { $0.status == "Fatturati" })!
                        
                        DashboardCard(
                            title: "Da Fatturare",
                            value: "\(toBill.count)",
                            icon: BillingStatus.toBill.icon,
                            color: BillingStatus.toBill.color,
                            isClickable: true,
                            action: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    activeFilterMode = .daFatturare
                                }
                            }
                        )
                        
                        DashboardCard(
                            title: "Fatturati",
                            value: "\(billed.count)",
                            icon: BillingStatus.billed.icon,
                            color: BillingStatus.billed.color,
                            isClickable: true,
                            action: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    activeFilterMode = .fatturati
                                }
                            }
                        )
                    }
                    
                    // Grafico Spazio su disco per HD
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            HStack(spacing: 8) {
                                Image(systemName: "chart.bar.fill")
                                    .foregroundColor(StudioTheme.accent)
                                Text("Spazio Occupato (%) per HD")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(StudioTheme.text)
                            }
                            Spacer()
                            let totalGB = diskUsageData.reduce(0.0) { $0 + $1.sizeGB }
                            if totalGB > 0 {
                                Text("Progetti Totali: \(formatStorageSize(totalGB))")
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.75))
                            }
                        }
                        
                        if diskUsageData.isEmpty {
                            Text("Nessun dato di spazio disponibile")
                                .font(.system(size: 13))
                                .foregroundColor(StudioTheme.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            Chart(diskUsageData) { item in
                                let percent = item.percent ?? 0
                                BarMark(
                                    x: .value("Percent", percent),
                                    y: .value("Volume", item.volume)
                                )
                                .foregroundStyle(item.color)
                                .cornerRadius(5)
                                .annotation(position: .trailing) {
                                    Text("\(formatStorageSize(item.sizeGB)) (\(item.percent.map { String(format: "%.1f%%", $0) } ?? "capacità n/d"))")
                                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.85))
                                        .padding(.leading, 4)
                                }
                            }
                            .chartYScale(domain: diskUsageData.map(\.volume))
                            .chartXScale(domain: 0...120)
                            .chartXAxis {
                                AxisMarks(position: .bottom, values: [0, 25, 50, 75, 100]) { value in
                                    AxisValueLabel {
                                        if let intVal = value.as(Int.self) {
                                            Text("\(intVal)%")
                                                .font(.system(size: 10))
                                                .foregroundColor(StudioTheme.secondary)
                                        }
                                    }
                                    AxisGridLine().foregroundStyle(.white.opacity(0.12))
                                }
                            }
                            .chartYAxis {
                                AxisMarks(position: .leading) {
                                    AxisValueLabel().foregroundStyle(.white.opacity(0.85))
                                }
                            }
                        }
                    }
                    .padding(20)
                    .frame(height: max(220, CGFloat(diskUsageData.count * 38 + 80)))
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(StudioTheme.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(StudioTheme.line, lineWidth: 1)
                            )
                    )
                    
                    // Scadenze Imminenti (Prossimi 7 giorni o scaduti) se presenti
                    let imminenti = filteredProjects.filter {
                        guard let deadline = $0.deadline else { return false }
                        let days = Calendar.current.dateComponents([.day], from: Date(), to: deadline).day ?? 0
                        return days <= 7 || deadline < Date()
                    }.sorted(by: { ($0.deadline ?? Date()) < ($1.deadline ?? Date()) })
                    
                    if !imminenti.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Image(systemName: "bell.badge.fill")
                                    .foregroundColor(StudioTheme.amber)
                                Text("Consegne in scadenza")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(StudioTheme.text)
                            }
                            
                            ForEach(imminenti) { project in
                                if let deadline = project.deadline {
                                    let isLate = deadline < Date() && !Calendar.current.isDateInToday(deadline)
                                    
                                    Button(action: {
                                        onSelectProject?(project)
                                    }) {
                                        HStack(spacing: 10) {
                                            Image(systemName: isLate ? "exclamationmark.circle.fill" : "clock.fill")
                                                .foregroundColor(isLate ? StudioTheme.red : StudioTheme.amber)
                                            Text(project.name)
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundColor(StudioTheme.text)
                                            Spacer()
                                            
                                            Text(project.isCompleted ? "Concluso" : "In Corso")
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundColor(project.isCompleted ? StudioTheme.green : StudioTheme.amber)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 3)
                                                .background(Capsule().fill((project.isCompleted ? StudioTheme.green : StudioTheme.amber).opacity(0.15)))
                                            
                                            Text(deadline, style: .date)
                                                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                                .foregroundColor(isLate ? StudioTheme.red : StudioTheme.amber)
                                        }
                                        .padding(11)
                                        .background(Color.black.opacity(0.22))
                                        .cornerRadius(8)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                        }
                        .padding(18)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(StudioTheme.surface)
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(StudioTheme.amber.opacity(0.35), lineWidth: 1))
                        )
                    }
                }
                
                Spacer()
            }
            .frame(maxWidth: 1320)
            .padding(36)
            .frame(maxWidth: .infinity)
        }
    }
}

struct DashboardCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    var isClickable: Bool = true
    var action: (() -> Void)? = nil
    @State private var isHovered = false

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .foregroundColor(color)
                Text(title)
                    .foregroundColor(StudioTheme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: .medium))
            HStack(alignment: .firstTextBaseline) {
                Text(value)
                    .font(.system(size: 25, weight: .semibold).monospacedDigit())
                    .foregroundColor(StudioTheme.text)
                Spacer(minLength: 0)
                if isClickable && action != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(StudioTheme.secondary)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(isHovered ? StudioTheme.raised : StudioTheme.surface))
    }

    var body: some View {
        if isClickable, let action = action {
            Button(action: action) { summary }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .help("Mostra \(title.lowercased())")
        } else {
            summary
        }
    }
}

// Vista per la selezione delle cartelle
struct FolderSelectionView: View {
    @EnvironmentObject var folderScanner: FolderScanner
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFolders: [URL] = []
    
    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 60))
                    .foregroundColor(StudioTheme.accent)
                
                Text("Seleziona Hard Disk da Scansionare")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(StudioTheme.text)
            
                Text("FolderFlow scansionerà ricorsivamente gli hard disk selezionati per trovare progetti video con nomenclatura AA_MM_NN_NomeProgetto. Puoi selezionare più hard disk contemporaneamente.")
                    .font(.body)
                    .foregroundColor(StudioTheme.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            
            VStack(spacing: 16) {
                if selectedFolders.isEmpty {
                    Button("Seleziona Hard Disk") {
                        selectFolders()
                    }
                    .buttonStyle(ModernButtonStyle(color: StudioTheme.accent, isPrimary: true))
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            Text("Hard Disk Selezionati:")
                                .font(.headline)
                                .foregroundColor(StudioTheme.text)
                            
                            ForEach(selectedFolders, id: \.self) { folder in
                                HStack {
                                    Image(systemName: "externaldrive.fill")
                                        .foregroundColor(StudioTheme.accent)
                                    Text(folder.lastPathComponent)
                                        .foregroundColor(StudioTheme.text)
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.gray.opacity(0.2))
                                .cornerRadius(8)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .frame(maxHeight: 200)
            
                    HStack(spacing: 12) {
                        Button("Aggiungi Altri") {
                            selectFolders()
                        }
                        .buttonStyle(ModernButtonStyle(color: StudioTheme.accent))
                        
                        Button("Avvia Scansione Sequenziale") {
                            Task {
                                await folderScanner.scanFolders(selectedFolders)
                            }
                            dismiss()
                        }
                        .buttonStyle(ModernButtonStyle(color: StudioTheme.background, isPrimary: true))
                    }
                }
                
                Button("Annulla") {
                    dismiss()
                }
                .buttonStyle(ModernButtonStyle(color: Color(red: 0.5, green: 0.5, blue: 0.5)))
            }
        }
        .frame(width: 500, height: 500)
        .background(
            StudioTheme.background
        )
    }
    
    private func selectFolders() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.title = "Seleziona Hard Disk da Scansionare"
        panel.message = "Seleziona tutti gli hard disk contenenti progetti video (puoi selezionarne più di uno)"
        
        let volumesURL = URL(fileURLWithPath: "/Volumes")
        panel.directoryURL = volumesURL
        panel.showsHiddenFiles = false
        panel.treatsFilePackagesAsDirectories = false
        panel.showsResizeIndicator = true
        panel.canSelectHiddenExtension = false
        
        if let window = NSApplication.shared.windows.first {
            panel.beginSheetModal(for: window) { response in
                if response == .OK {
                    DispatchQueue.main.async {
                        self.selectedFolders.append(contentsOf: panel.urls)
                    }
                }
            }
        } else {
            if panel.runModal() == .OK {
                selectedFolders.append(contentsOf: panel.urls)
            }
        }
    }
}

struct ProjectRow: View {
    let project: VideoProject
    var isSelected: Bool = false
    let volumeColor: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 15))
                .foregroundColor(volumeColor)
                .frame(width: 20)
            Text(project.name)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundColor(StudioTheme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 60)
        .contentShape(Rectangle())
        .help(project.name)
        .accessibilityLabel(project.name)
    }
}

struct ProjectStatusDot: View {
    let active: Bool
    let color: Color
    let label: String

    var body: some View {
        Circle()
            .fill(active ? color : Color.clear)
            .overlay(Circle().stroke(active ? Color.clear : StudioTheme.secondary.opacity(0.45), lineWidth: 1))
            .frame(width: 6, height: 6)
            .frame(maxWidth: .infinity, minHeight: 60)
                .help(label)
            .accessibilityLabel(label)
    }
}

// Vista dettagli progetto
struct ProjectDetailView: View {
    let project: VideoProject
    @EnvironmentObject var dataManager: DataManager
    var onDelete: (() -> Void)? = nil
    @State private var secureCopyFeedback = false
    
    var body: some View {
        let isEmptyFolder = isProjectFolderEmpty(project)
        
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Barra superiore con pulsante Impostazioni a destra
                HStack {
                    Text("Dettaglio Progetto")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(StudioTheme.secondary)
                    Spacer()
                }
                
                // Header del progetto
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(project.name)
                                .font(.system(size: 26, weight: .bold))
                                .foregroundColor(project.isMissing ? StudioTheme.red : .white)
                            
                            HStack(spacing: 10) {
                                if project.isMissing {
                                    HStack(spacing: 6) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundColor(StudioTheme.red)
                                            .font(.system(size: 13))
                                        Text("Posizione Non Trovata")
                                            .font(.system(size: 12.5, weight: .semibold))
                                            .foregroundColor(StudioTheme.red)
                                    }
                                } else {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(project.isOnline ? StudioTheme.green : StudioTheme.amber)
                                            .frame(width: 9, height: 9)
                                        Text(project.isOnline ? "Online" : "Offline")
                                            .font(.system(size: 12.5, weight: .semibold))
                                            .foregroundColor(project.isOnline ? StudioTheme.green : StudioTheme.amber)
                                    }
                                }
                                
                                Text("•")
                                    .foregroundColor(.white.opacity(0.3))
                                
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(dataManager.getVolumeColor(for: project.volumeIdentifier))
                                        .frame(width: 7, height: 7)
                                    Text(project.volumeIdentifier)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundColor(.white.opacity(0.85))
                                }
                            }
                        }

                        Spacer()

                        if project.isMissing {
                            Button(action: {
                                onDelete?()
                                dataManager.deleteProject(project)
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "trash.fill")
                                    Text("Elimina dal Catalogo")
                                }
                            }
                            .buttonStyle(ModernButtonStyle(color: StudioTheme.red, isPrimary: true))
                        } else if project.isOnline {
                            HStack(spacing: 10) {
                                if isEmptyFolder {
                                    Button(action: {
                                        triggerSecureCopy()
                                    }) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "externaldrive.badge.checkmark")
                                            Text("Avvia Copia Sicura")
                                        }
                                    }
                                    .buttonStyle(ModernButtonStyle(color: StudioTheme.green, isPrimary: true))
                                }
                                
                                Button(action: {
                                    openProjectFolder(project: project)
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "folder.fill")
                                        Text("Apri nel Finder")
                                    }
                                }
                                .buttonStyle(ModernButtonStyle(color: StudioTheme.accent, isPrimary: true))
                            }
                        }
                    }
                }
                .padding(22)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(StudioTheme.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(project.isMissing ? StudioTheme.red.opacity(0.35) : StudioTheme.line, lineWidth: 1)
                        )
                )
                
                // Banner dedicato quando la cartella progetto è vuota (appena creata / pronta per offload post-shooting)
                if isEmptyFolder {
                    HStack(spacing: 16) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(StudioTheme.green.opacity(0.22))
                                .frame(width: 46, height: 46)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(StudioTheme.green.opacity(0.5), lineWidth: 1)
                                )
                            Image(systemName: "sdcard.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(StudioTheme.green)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text("Pronto per importare le riprese")
                                    .font(.system(size: 14.5, weight: .bold))
                                    .foregroundColor(StudioTheme.text)
                                
                                if secureCopyFeedback {
                                    Text("✓ Percorso copiato • SecureCopy avviata")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundColor(StudioTheme.green)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(StudioTheme.green.opacity(0.22)))
                                }
                            }
                            
                            Text("La cartella è vuota. Avvia SecureCopy per copiare le schede: il percorso di destinazione verrà copiato negli appunti.")
                                .font(.system(size: 11.5))
                                .foregroundColor(.white.opacity(0.75))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        
                        Spacer(minLength: 10)
                        
                        Button(action: {
                            triggerSecureCopy()
                        }) {
                            HStack(spacing: 7) {
                                Image(systemName: "externaldrive.badge.checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Avvia Copia Sicura")
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .foregroundColor(StudioTheme.text)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(
                                        StudioTheme.green.opacity(0.22)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(Color.white.opacity(0.35), lineWidth: 1)
                                    )
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding(18)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(StudioTheme.background.opacity(0.55))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(StudioTheme.green.opacity(0.45), lineWidth: 1)
                            )
                    )
                }

                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(project.isMissing ? "Ultimo percorso noto" : "Percorso")
                            .font(.system(size: 12))
                            .foregroundColor(StudioTheme.secondary)
                        Text(dataManager.displayPath(for: project))
                            .font(.system(size: 13))
                            .foregroundColor(StudioTheme.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider().overlay(StudioTheme.line)
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 8) {
                                Text("Dimensione")
                                if project.isOnline && !project.isMissing {
                                    Button {
                                        dataManager.updateProjectFolderSize(for: project.id)
                                    } label: {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                    }
                                    .buttonStyle(.plain)
                                    .help("Ricalcola dimensione")
                                    .accessibilityLabel("Ricalcola dimensione")
                                }
                            }
                            .font(.system(size: 12))
                            .foregroundColor(StudioTheme.secondary)
                            Text(project.folderSize > 0.001 ? formatStorageSize(project.folderSize) : (isEmptyFolder ? "Cartella vuota" : "Calcolo in corso…"))
                                .font(.system(size: 14, weight: .medium))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        fact("Data creazione", project.date.formatted(date: .abbreviated, time: .omitted))
                        fact("Disco", project.volumeIdentifier)
                    }
                }
                .padding(22)
                .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 14))

                // Metadati (Scadenza, Stato, Commenti, Fatturazione)
                ProjectMetadataSection(project: project)
                    .id(project.id)
            }
            .frame(maxWidth: 1040)
            .padding(36)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudioTheme.background)
        .task(id: project.id) {
            if project.isOnline && !project.isMissing {
                dataManager.updateProjectFolderSize(for: project.id)
            }
        }
    }
    
    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12)).foregroundColor(StudioTheme.secondary)
            Text(value).font(.system(size: 14, weight: .medium)).foregroundColor(StudioTheme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openProjectFolder(project: VideoProject) {
        let url = URL(fileURLWithPath: project.path)
        NSWorkspace.shared.open(url)
    }
    
    private func triggerSecureCopy() {
        launchSecureCopy(for: project.path, dataManager: dataManager)
        secureCopyFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            secureCopyFeedback = false
        }
    }
}

// Sezione Metadati per il Dettaglio Progetto
struct ProjectMetadataSection: View {
    let project: VideoProject
    @EnvironmentObject var dataManager: DataManager
    private var current: VideoProject { dataManager.projects.first { $0.id == project.id } ?? project }
    private var hasDeadline: Binding<Bool> {
        Binding(get: { current.deadline != nil }, set: { value in update { $0.deadline = value ? ($0.deadline ?? Date()) : nil } })
    }
    private var deadline: Binding<Date> {
        Binding(get: { current.deadline ?? Date() }, set: { value in update { $0.deadline = value } })
    }
    private var isCompleted: Binding<Bool> {
        Binding(get: { current.isCompleted }, set: { value in update { $0.isCompleted = value } })
    }
    private var commentsText: Binding<String> {
        Binding(get: { current.comments }, set: { value in update { $0.comments = value } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Gestione progetto")
                .font(.system(size: 17, weight: .semibold))
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Scadenza", systemImage: "calendar")
                            .foregroundColor(StudioTheme.secondary)
                        Toggle("Imposta scadenza", isOn: hasDeadline)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    }
                    Group {
                        if current.deadline != nil {
                            DatePicker("Data di consegna", selection: deadline, displayedComponents: .date)
                                .labelsHidden()
                        } else {
                            Text("Nessuna scadenza").foregroundColor(StudioTheme.secondary)
                        }
                    }
                    .frame(height: 22, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 12) {
                    Label("Lavorazione", systemImage: "checkmark.circle")
                        .foregroundColor(StudioTheme.secondary)
                    Picker("Stato progetto", selection: isCompleted) {
                        Text("In corso").tag(false)
                        Text("Concluso").tag(true)
                    }
                    .labelsHidden()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 12) {
                    Label("Fatturazione", systemImage: "doc.text")
                        .foregroundColor(StudioTheme.secondary)
                    Picker("Fatturazione", selection: Binding(
                        get: { current.billingStatus },
                        set: { dataManager.updateBillingStatus(for: project.id, status: $0) }
                    )) {
                        ForEach(BillingStatus.allCases, id: \.self) { status in
                            Text(status.rawValue).tag(status)
                        }
                    }
                    .labelsHidden()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 13))

            Divider().overlay(StudioTheme.line)
            VStack(alignment: .leading, spacing: 10) {
                Text("Note").font(.system(size: 13)).foregroundColor(StudioTheme.secondary)
                TextEditor(text: commentsText)
                    .font(.system(size: 13))
                    .padding(8)
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .background(StudioTheme.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioTheme.line, lineWidth: 1))
                    .accessibilityLabel("Note del progetto")
            }
        }
        .foregroundColor(StudioTheme.text)
        .padding(22)
        .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func update(_ edit: (inout VideoProject) -> Void) {
        var value = current
        edit(&value)
        dataManager.updateProjectInfo(for: value.id, deadline: value.deadline,
                                      isCompleted: value.isCompleted, comments: value.comments)
    }
}

// Vista pulsante Settings (posizionato a destra nell'header principale)
// Componente per sezioni Settings
struct SettingsSection<Content: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
    let content: Content
    
    init(icon: String, iconColor: Color, title: String, description: String, @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.description = description
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header sezione
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(iconColor)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(iconColor.opacity(0.15))
                    )
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(StudioTheme.text)
                    
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundColor(StudioTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Spacer()
            }
            
            // Contenuto
            content
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(StudioTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
        )
    }
}

// Vista Settings
// Tab per la finestra Impostazioni
enum SettingsTab: String, CaseIterable, Identifiable {
    case hardDisks = "Dischi"
    case projects = "Progetti"
    case account = "Cataloghi"
    case macOS = "Sistema"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .hardDisks: return "externaldrive.fill"
        case .projects: return "folder.badge.gearshape"
        case .account: return "person.crop.circle"
        case .macOS: return "laptopcomputer"
        }
    }
}

// Vista Settings Moderna, Compatta e a Schede (Tab-Based)
private func orderedMonitoringDisks(_ disks: [MountedVolumeInfo], monitoredPaths: [String]) -> [MountedVolumeInfo] {
    let monitored = Set(monitoredPaths)
    func priority(_ disk: MountedVolumeInfo) -> Int {
        if disk.url.path == "/" || disk.name == "Macintosh HD" || !disk.url.path.hasPrefix("/Volumes/") { return 0 }
        return monitored.contains(disk.url.path) ? 1 : 2
    }
    return disks.sorted {
        let lhs = priority($0), rhs = priority($1)
        if lhs != rhs { return lhs < rhs }
        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
}

struct SettingsView: View {
    @EnvironmentObject var workspace: CatalogWorkspace
    @EnvironmentObject var dataManager: DataManager
    @EnvironmentObject var folderScanner: FolderScanner
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedTab: SettingsTab

    init(initialTab: SettingsTab = .hardDisks) {
        _selectedTab = State(initialValue: initialTab)
    }
    
    // Verifica se un volume è il disco di sistema
    private func isSystemVolume(_ vol: MountedVolumeInfo) -> Bool {
        vol.url.path == "/" || vol.name == "Macintosh HD" || !vol.url.path.hasPrefix("/Volumes/")
    }
    
    // Tutti i dischi attualmente connessi, con Macintosh HD sempre primo in alto, poi ordinati in ordine numerico naturale
    private var allConnectedDisks: [MountedVolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var infos: [MountedVolumeInfo] = []
        
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let rawName = values?.volumeName ?? (url.path == "/" ? "Macintosh HD" : url.lastPathComponent)
            guard !rawName.isEmpty else { continue }
            
            let totalBytes = Double(values?.volumeTotalCapacity ?? 0)
            let availBytes = Double(values?.volumeAvailableCapacity ?? 0)
            let totalGB = totalBytes / (1024 * 1024 * 1024)
            let usedGB = max(0, (totalBytes - availBytes) / (1024 * 1024 * 1024))
            
            infos.append(MountedVolumeInfo(
                name: rawName,
                url: url,
                totalCapacityGB: totalGB,
                usedCapacityGB: usedGB
            ))
        }
        
        // Include any additional disk from dataManager.connectedVolumes
        for dmVol in dataManager.connectedVolumes {
            if !infos.contains(where: { $0.url.path == dmVol.url.path }) {
                infos.append(dmVol)
            }
        }
        
        return orderedMonitoringDisks(infos, monitoredPaths: dataManager.monitoredPaths)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header con Tab Bar Segmentata
            VStack(spacing: 14) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(StudioTheme.accent)
                        Text("Impostazioni")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(StudioTheme.text)
                    }
                    
                    Spacer()
                    
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundColor(StudioTheme.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                
                // Segmented Tab Picker
                HStack(spacing: 6) {
                    ForEach(SettingsTab.allCases) { tab in
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedTab = tab
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: tab.icon)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(tab.rawValue)
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundColor(selectedTab == tab ? .white : .white.opacity(0.65))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 6.5)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selectedTab == tab ? StudioTheme.raised : Color.clear)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.clear, lineWidth: 1)
                                    )
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.35))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)
            .background(Color.black.opacity(0.2))
            
            Divider()
                .background(Color.white.opacity(0.12))
            
            // Contenuto a schede con altezza ottimizzata
            VStack(alignment: .leading, spacing: 0) {
                switch selectedTab {
                case .hardDisks:
                    tabHardDisksView
                case .projects:
                    ProjectNamingSettingsView()
                case .account:
                    CatalogManagementView()
                case .macOS:
                    tabMacOSView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(22)
            
            Divider()
                .background(Color.white.opacity(0.1))
            
            // Barra inferiore con attribuzione e pulsante Chiudi
            HStack {
                Link("powered by unshapedstudio.com", destination: URL(string: "https://unshapedstudio.com/")!)
                    .font(.system(size: 11))
                    .foregroundColor(StudioTheme.secondary)
                    .help("Apri il sito di Unshaped Studio")
                Spacer()
                Button("Chiudi") {
                    dismiss()
                }
                .buttonStyle(ModernButtonStyle(color: Color.gray.opacity(0.6)))
                .frame(width: 90)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.25))
        }
        .frame(width: 760, height: min(700, (NSScreen.main?.visibleFrame.height ?? 800) - 80))
        .background(
            StudioTheme.background
        )
        .onAppear { dataManager.refreshConnectedVolumes() }
    }

    // MARK: - Tab 1: Hard Disks (Griglia 2 Colonne per mostrare tutti i dischi contemporaneamente)
    private var tabHardDisksView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hard Disk Connessi")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(StudioTheme.text)
                    Text("Attiva i dischi da monitorare. Clicca sul colore per personalizzarlo.")
                        .font(.system(size: 11.5))
                        .foregroundColor(StudioTheme.secondary)
                }
                Spacer()
                
                // Azioni rapide Seleziona / Deseleziona
                HStack(spacing: 8) {
                    Button("Tutti") {
                        for vol in allConnectedDisks {
                            dataManager.addMonitoredPath(vol.url.path)
                            if isSystemVolume(vol) {
                                dataManager.addMonitoredPath("/")
                            }
                        }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(StudioTheme.accent)
                    
                    Text("•").foregroundColor(.white.opacity(0.3)).font(.system(size: 10))
                    
                    Button("Nessuno") {
                        dataManager.clearMonitoredPaths()
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(StudioTheme.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.07)))
            }
            
            if allConnectedDisks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "externaldrive.badge.questionmark")
                        .font(.system(size: 28))
                        .foregroundColor(.white.opacity(0.35))
                    Text("Nessun hard disk rilevato dal sistema.")
                        .font(.system(size: 12))
                        .foregroundColor(StudioTheme.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 12) {
                        ForEach(allConnectedDisks) { vol in
                            let path = vol.url.path
                            let isSys = isSystemVolume(vol)
                            let isSelected = dataManager.monitoredPaths.contains(path)
                                || (isSys && (dataManager.monitoredPaths.contains("/") || dataManager.monitoredPaths.contains(where: { $0.contains("Macintosh HD") })))
                            let volColor = dataManager.getVolumeColor(for: vol.name)
                            let capFormatted: String = {
                                if vol.totalCapacityGB >= 1000 {
                                    return String(format: "%.1f TB", vol.totalCapacityGB / 1000).replacingOccurrences(of: ".0", with: "")
                                } else if vol.totalCapacityGB > 0 {
                                    return String(format: "%.0f GB", vol.totalCapacityGB)
                                }
                                return ""
                            }()
                            
                            HStack(spacing: 8) {
                                ColorPicker("Colore di \(vol.name)", selection: Binding(
                                    get: { dataManager.getVolumeColor(for: vol.name) },
                                    set: { dataManager.setVolumeColor($0, for: vol.name) }
                                ), supportsOpacity: false)
                                .labelsHidden()
                                .frame(width: 44)
                                .help("Personalizza il colore di \(vol.name)")

                                Image(systemName: isSys ? "internaldrive.fill" : "externaldrive.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(volColor)
                                    .frame(width: 16)
                                
                                VStack(alignment: .leading, spacing: 1.5) {
                                    HStack(spacing: 5) {
                                        Text(vol.name)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(StudioTheme.text)
                                            .lineLimit(1)
                                        
                                        if isSys {
                                            Text("SISTEMA")
                                                .font(.system(size: 8, weight: .bold))
                                                .foregroundColor(StudioTheme.accent)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Capsule().fill(StudioTheme.accent.opacity(0.18)))
                                        }
                                    }
                                    
                                    HStack(spacing: 4) {
                                        if !capFormatted.isEmpty {
                                            Text(capFormatted)
                                                .font(.system(size: 9.5, weight: .medium))
                                                .foregroundColor(StudioTheme.secondary)
                                            Text("•")
                                                .font(.system(size: 8))
                                                .foregroundColor(.white.opacity(0.3))
                                        }
                                        Text(path)
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundColor(.white.opacity(0.4))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                
                                Spacer(minLength: 4)
                                
                                Toggle("", isOn: Binding(
                                    get: { isSelected },
                                    set: { newValue in
                                        if newValue {
                                            dataManager.addMonitoredPath(path)
                                            if isSys {
                                                dataManager.addMonitoredPath("/")
                                            }
                                        } else {
                                            dataManager.removeMonitoredPath(path)
                                            if isSys {
                                                dataManager.removeMonitoredPath("/")
                                            }
                                        }
                                    }
                                ))
                                .toggleStyle(SwitchToggleStyle(tint: StudioTheme.accent))
                                .labelsHidden()
                                .controlSize(.small)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isSelected ? Color.white.opacity(0.08) : Color.white.opacity(0.03))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(isSelected ? volColor.opacity(0.4) : Color.white.opacity(0.06), lineWidth: 1)
                                    )
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
    
    // MARK: - Tab 2: Sync & Backup
    // MARK: - Tab 3: Sistema macOS
    private func preferenceBinding(_ keyPath: WritableKeyPath<SharedAppPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { workspace.preferences[keyPath: keyPath] }, set: { value in
            var preferences = workspace.preferences
            preferences[keyPath: keyPath] = value
            workspace.updatePreferences(preferences)
        })
    }

    private var tabMacOSView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Integrazione macOS")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(StudioTheme.text)

            VStack(spacing: 0) {
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Avvia FolderFlow all'accesso (in background)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(StudioTheme.text)
                        Text("Avvia FolderFlow automaticamente al login del Mac per mantenere l'archivio sempre sincronizzato.")
                            .font(.system(size: 11))
                            .foregroundColor(StudioTheme.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Toggle("Avvia FolderFlow all'accesso (in background)", isOn: preferenceBinding(\.launchAtLogin))
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: StudioTheme.accent))
                        .frame(width: 48)
                        .accessibilityHint("Avvia automaticamente FolderFlow al login del Mac.")
                        .disabled(workspace.readOnly)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)

                Divider().overlay(StudioTheme.line).padding(.horizontal, 20)

                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Solo barra dei menu (nascondi dal Dock)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(StudioTheme.text)
                        Text("Rimuove l'icona dal Dock; FolderFlow risiederà nella barra dei menu.")
                            .font(.system(size: 11))
                            .foregroundColor(StudioTheme.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Toggle("Solo barra dei menu (nascondi dal Dock)", isOn: preferenceBinding(\.hideDockIcon))
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: StudioTheme.accent))
                        .frame(width: 48)
                        .accessibilityHint("Rimuove l'icona dal Dock e mantiene FolderFlow nella barra dei menu.")
                        .disabled(workspace.readOnly)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1))
            )

            Spacer()
        }
    }

    // MARK: - Tab 4: Database & Manutenzione

}

// Vista selezione Hard Disk
struct HardDiskSelectionView: View {
    @EnvironmentObject var folderScanner: FolderScanner
    @State private var availableVolumes: [String] = []
    @State private var selectedVolumes: Set<String> = []
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 40))
                    .foregroundColor(StudioTheme.accent)
                
                Text("Seleziona Hard Disk")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(StudioTheme.text)
                
                Text("Scegli gli hard disk da scansionare per trovare i progetti video")
                    .font(.body)
                    .foregroundColor(StudioTheme.secondary)
                    .multilineTextAlignment(.center)
            }
            
            // Lista HD disponibili
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(availableVolumes, id: \.self) { volume in
                        VolumeRow(
                            volumeName: volume,
                            isSelected: selectedVolumes.contains(volume),
                            onToggle: { toggleVolume(volume) }
                        )
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(maxHeight: 200)
            
            // Pulsanti azione
            VStack(spacing: 12) {
                Button("Scansiona HD Selezionati") {
                    scanSelectedVolumes()
                }
                .buttonStyle(ModernButtonStyle(color: StudioTheme.accent))
                .disabled(selectedVolumes.isEmpty || folderScanner.isScanning)
                
                if folderScanner.isScanning {
                    VStack(spacing: 8) {
                        ProgressView(value: folderScanner.scanProgress)
                            .progressViewStyle(LinearProgressViewStyle())
                        
                        Text(folderScanner.currentPath)
                            .font(.caption)
                            .foregroundColor(StudioTheme.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(20)
        .onAppear {
            loadAvailableVolumes()
        }
    }
    
    private func loadAvailableVolumes() {
        let fileManager = FileManager.default
        let volumes = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes])
        
        var volumeNames: [String] = []
        
        for volumeURL in volumes ?? [] {
            do {
                let resourceValues = try volumeURL.resourceValues(forKeys: [.volumeNameKey])
                if let volumeName = resourceValues.volumeName {
                    volumeNames.append(volumeName)
                }
            } catch {
                continue
            }
        }
        
        availableVolumes = volumeNames.sorted()
    }
    
    private func toggleVolume(_ volume: String) {
        if selectedVolumes.contains(volume) {
            selectedVolumes.remove(volume)
        } else {
            selectedVolumes.insert(volume)
        }
    }
    
    private func scanSelectedVolumes() {
        let volumeURLs = selectedVolumes.compactMap { volumeName in
            URL(fileURLWithPath: "/Volumes/\(volumeName)")
        }
        
        Task {
            await folderScanner.scanFolders(volumeURLs)
        }
    }
}

// Riga per ogni volume
struct VolumeRow: View {
    let volumeName: String
    let isSelected: Bool
    let onToggle: () -> Void
    
    var body: some View {
        HStack {
            Image(systemName: "externaldrive.fill")
                .foregroundColor(StudioTheme.accent)
                .frame(width: 20)
            
            Text(volumeName)
                .foregroundColor(StudioTheme.text)
                .font(.body)
            
            Spacer()
            
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? StudioTheme.accent : .white.opacity(0.5))
                    .font(.title3)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? StudioTheme.accent.opacity(0.2) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? StudioTheme.accent : Color.white.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

// Stile pulsante moderno
struct ModernButtonStyle: ButtonStyle {
    let color: Color
    let isPrimary: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    init(color: Color, isPrimary: Bool = false) {
        self.color = color
        self.isPrimary = isPrimary
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(isPrimary ? StudioTheme.background : StudioTheme.text)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(isPrimary ? color : (isHovered ? StudioTheme.raised : StudioTheme.surface)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(isPrimary ? Color.clear : StudioTheme.line, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .onHover { isHovered = $0 }
    }
}

// Vista per creare un nuovo progetto
// Grafico a torta (pie/donut chart) per il livello di riempimento del disco
struct DiskPieChart: View {
    let percent: Double // 0 to 100
    let color: Color
    var size: CGFloat = 46
    
    var body: some View {
        let fraction = min(1.0, max(0.0, percent / 100.0))
        let isCritical = percent >= 95.0
        let ringColor = isCritical ? StudioTheme.amber : (percent >= 85 ? StudioTheme.amber : color)
        
        ZStack {
            // Sfondo disco/torta
            Circle()
                .fill(Color.black.opacity(0.35))
                .frame(width: size, height: size)
            
            // Settore torta interno semitrasparente
            Circle()
                .trim(from: 0.0, to: CGFloat(fraction))
                .stroke(ringColor.opacity(0.22), lineWidth: size / 2)
                .rotationEffect(.degrees(-90))
                .frame(width: size / 2, height: size / 2)
            
            // Traccia anello di base
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 4)
                .frame(width: size, height: size)
            
            // Fetta/Arco pieno circolare
            Circle()
                .trim(from: 0.0, to: CGFloat(fraction))
                .stroke(
                    ringColor,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: size, height: size)
            
            // Percentuale al centro
            Text("\(Int(round(percent)))%")
                .font(.system(size: size * 0.25, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundColor(isCritical ? StudioTheme.amber : .white)
        }
        .frame(width: size, height: size)
    }
}

// Card quadrata a griglia per selezionare l'Hard Disk
struct DiskSelectionCard: View {
    let volume: MountedVolumeInfo
    let isSelected: Bool
    let volumeColor: Color
    let isSystem: Bool
    let onSelect: () -> Void
    
    @State private var isHovered: Bool = false
    
    var body: some View {
        let diskTotal = volume.totalCapacityGB > 0 ? volume.totalCapacityGB : 1000.0
        let diskUsed = volume.usedCapacityGB
        let diskFree = volume.availableCapacityGB
        let percent = min(100.0, max(0.0, (diskUsed / diskTotal) * 100.0))
        let isLowSpace = diskFree < 30.0 // Meno di 30 GB liberi
        
        Button(action: onSelect) {
            VStack(spacing: 7) {
                // Barra superiore: indicatore sistema o pallino volume + stato selezione
                HStack(alignment: .center) {
                    if isSystem {
                        HStack(spacing: 3) {
                            Image(systemName: "internaldrive.fill")
                                .font(.system(size: 8.5))
                            Text("SISTEMA")
                                .font(.system(size: 7.5, weight: .bold))
                        }
                        .foregroundColor(StudioTheme.accent)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(StudioTheme.accent.opacity(0.18)))
                    } else {
                        Circle()
                            .fill(volumeColor)
                            .frame(width: 6, height: 6)
                    }
                    
                    Spacer()
                    
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(StudioTheme.accent)
                    } else if isLowSpace {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(StudioTheme.amber)
                    }
                }
                .frame(height: 14)
                
                // Icona a torta con percentuale
                DiskPieChart(percent: percent, color: volumeColor, size: 52)
                    .padding(.vertical, 1)
                
                // Nome Disco
                Text(volume.name)
                    .font(.system(size: 14, weight: isSelected ? .bold : .semibold))
                    .foregroundColor(isSelected ? .white : .white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                // Spazio libero rimanente scritto chiaramente sotto
                VStack(spacing: 1) {
                    Text(freeSpaceText(diskFree))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(isLowSpace ? StudioTheme.amber : StudioTheme.green)
                    
                    Text("su \(totalSpaceText(diskTotal))")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(StudioTheme.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? volumeColor.opacity(0.24) : (isHovered ? Color.white.opacity(0.08) : Color.white.opacity(0.04)))
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(StudioTheme.surface)
                            .opacity(0.5)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                isSelected ? StudioTheme.accent : (isHovered ? Color.white.opacity(0.25) : Color.white.opacity(0.1)),
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
            )
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .animation(.easeInOut(duration: 0.15), value: isSelected)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { h in isHovered = h }
        .help("\(volume.name): \(freeSpaceText(diskFree)) su \(totalSpaceText(diskTotal)) (\(Int(round(percent)))% occupato)")
    }
    
    private func freeSpaceText(_ gb: Double) -> String {
        if gb >= 1000.0 {
            return String(format: "%.1f TB liberi", gb / 1000.0)
        } else if gb >= 1.0 {
            return String(format: "%.0f GB liberi", gb)
        } else if gb > 0.01 {
            return String(format: "%.1f GB liberi", gb)
        } else {
            return "Pieno (0 GB)"
        }
    }
    
    private func totalSpaceText(_ gb: Double) -> String {
        if gb >= 1000.0 {
            let tb = gb / 1000.0
            let s = String(format: "%.1f TB", tb)
            return s.replacingOccurrences(of: ".0 TB", with: " TB")
        } else {
            return String(format: "%.0f GB", gb)
        }
    }
}

// Vista per creare un nuovo progetto
struct NewProjectView: View {
    @EnvironmentObject var dataManager: DataManager
    @Environment(\.dismiss) private var dismiss
    var onProjectCreated: ((VideoProject) -> Void)? = nil
    @State private var projectName = ""
    @State private var selectedVolume = ""
    @State private var namingDate = Date()

    private var naming: ProjectNaming { ProjectNaming(pattern: dataManager.projectNamingPattern) }
    private var trimmedTitle: String { projectName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var folderPreview: String? {
        naming.name(title: trimmedTitle.isEmpty ? "NomeProgetto" : trimmedTitle,
                    date: namingDate, existingNames: dataManager.projects.map(\.name))
    }
    private var nameError: String? {
        guard !trimmedTitle.isEmpty else { return nil }
        return ProjectNaming.componentError(trimmedTitle) ?? (folderPreview == nil ? "Il nome non è compatibile con il formato scelto o è troppo lungo." : nil)
    }

    
    private func isSystemVolume(_ vol: MountedVolumeInfo) -> Bool {
        vol.url.path == "/" || vol.name == "Macintosh HD" || !vol.url.path.hasPrefix("/Volumes/")
    }
    
    private var availableDisks: [MountedVolumeInfo] {
        if !dataManager.connectedVolumes.isEmpty {
            return dataManager.connectedVolumes
        }
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var infos: [MountedVolumeInfo] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let rawName = values?.volumeName ?? (url.path == "/" ? "Macintosh HD" : url.lastPathComponent)
            guard !rawName.isEmpty else { continue }
            let tBytes = Int64(values?.volumeTotalCapacity ?? 0)
            let aBytes = Int64(values?.volumeAvailableCapacity ?? 0)
            let uBytes = max(0, tBytes - aBytes)
            infos.append(MountedVolumeInfo(
                name: rawName,
                url: url,
                totalCapacityGB: Double(tBytes) / 1e9,
                usedCapacityGB: Double(uBytes) / 1e9,
                availableCapacityGB: Double(aBytes) / 1e9,
                totalBytes: tBytes,
                usedBytes: uBytes,
                availableBytes: aBytes
            ))
        }
        return infos.sorted { a, b in
            let aSys = isSystemVolume(a)
            let bSys = isSystemVolume(b)
            if aSys != bSys { return aSys }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
    
    private func freeSpaceText(_ gb: Double) -> String {
        if gb >= 1000.0 {
            return String(format: "%.1f TB liberi", gb / 1000.0)
        } else if gb >= 1.0 {
            return String(format: "%.0f GB liberi", gb)
        } else if gb > 0.01 {
            return String(format: "%.1f GB liberi", gb)
        } else {
            return "0 GB liberi"
        }
    }
    
    var body: some View {
        VStack(spacing: 20) {
            // Header modale
            VStack(alignment: .leading, spacing: 6) {
                Text("Nuovo progetto")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(StudioTheme.text)
                Text("Configura il nome e seleziona l'hard disk di destinazione")
                    .font(.system(size: 12))
                    .foregroundColor(StudioTheme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            VStack(alignment: .leading, spacing: 20) {
                // Campo Nome Progetto
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nome del lavoro")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(StudioTheme.text)
                    
                    TextField("Es. Campagna Autunno", text: $projectName)
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(StudioTheme.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 9)
                                .fill(Color.white.opacity(0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9)
                                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                                )
                        )
                }
                
                VStack(alignment: .leading, spacing: 5) {
                    Text("Nome cartella")
                        .font(.system(size: 11)).foregroundColor(StudioTheme.secondary)
                    Text(folderPreview ?? "Controlla il nome del lavoro")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(nameError == nil ? StudioTheme.text : StudioTheme.red)
                        .lineLimit(2).textSelection(.enabled)
                    if let nameError = nameError {
                        Text(nameError).font(.system(size: 11)).foregroundColor(StudioTheme.red)
                    }
                }

                // Selezione Hard Disk in griglia a quadrati
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Hard Disk di Destinazione")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(StudioTheme.text)
                        
                        Spacer()
                        
                        if let selVol = availableDisks.first(where: { $0.name == selectedVolume }) {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(dataManager.getVolumeColor(for: selVol.name))
                                    .frame(width: 6, height: 6)
                                Text(selVol.name)
                                    .font(.system(size: 11.5, weight: .bold))
                                    .foregroundColor(StudioTheme.text)
                                Text("• \(freeSpaceText(selVol.availableCapacityGB))")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(selVol.availableCapacityGB < 30 ? StudioTheme.amber : StudioTheme.green)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                        }
                    }
                    
                    // Griglia a quadrati tipo cartelle
                    ScrollView(showsIndicators: true) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                            ForEach(availableDisks) { vol in
                                DiskSelectionCard(
                                    volume: vol,
                                    isSelected: selectedVolume == vol.name,
                                    volumeColor: dataManager.getVolumeColor(for: vol.name),
                                    isSystem: isSystemVolume(vol),
                                    onSelect: {
                                        selectedVolume = vol.name
                                    }
                                )
                            }
                        }
                        .padding(5)
                    }
                    .frame(maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.black.opacity(0.2))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                    )
                }
            }
            
            Divider().overlay(StudioTheme.line)
            // Barra pulsanti
            HStack(spacing: 12) {
                Button("Annulla") {
                    dismiss()
                }
                .buttonStyle(ModernButtonStyle(color: Color.gray))
                
                Spacer()
                
                Button("Crea Progetto") {
                    createProject(launchSecureCopyAfter: false)
                }
                .buttonStyle(ModernButtonStyle(color: StudioTheme.accent))
                .disabled(trimmedTitle.isEmpty || selectedVolume.isEmpty || nameError != nil || folderPreview == nil)
                
                Button(action: {
                    createProject(launchSecureCopyAfter: true)
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "externaldrive.badge.checkmark")
                        Text("Crea e Avvia Copia Sicura")
                    }
                }
                .buttonStyle(ModernButtonStyle(color: StudioTheme.green, isPrimary: true))
                .disabled(trimmedTitle.isEmpty || selectedVolume.isEmpty || nameError != nil || folderPreview == nil)
            }
        }
        .padding(26)
        .frame(width: min(1100, (NSScreen.main?.visibleFrame.width ?? 1200) - 80),
               height: min(800, (NSScreen.main?.visibleFrame.height ?? 900) - 80))
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(StudioTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
        )
        .onAppear {
            namingDate = Date()
            dataManager.refreshConnectedVolumes(saveAfter: false)
            if selectedVolume.isEmpty {
                // Seleziona preferibilmente il primo disco esterno con spazio libero sufficiente
                if let bestDisk = availableDisks.first(where: { !isSystemVolume($0) && $0.availableCapacityGB > 50.0 }) {
                    selectedVolume = bestDisk.name
                } else {
                    selectedVolume = availableDisks.first?.name ?? ""
                }
            }
        }
    }
    
    private func createProject(launchSecureCopyAfter: Bool) {
        guard !trimmedTitle.isEmpty, !selectedVolume.isEmpty,
              let folderName = naming.name(title: trimmedTitle, date: Date(), existingNames: dataManager.projects.map(\.name)) else {
            dataManager.showError(nameError ?? "Inserisci un nome valido e seleziona il disco.")
            return
        }

        guard let mountedVolume = dataManager.connectedVolumes.first(where: { $0.name == selectedVolume }),
              FileManager.default.fileExists(atPath: mountedVolume.url.path) else {
            dataManager.showError("Il disco selezionato è stato scollegato. Ricollegalo prima di creare il progetto.")
            return
        }
        // Trova un percorso valido per il volume selezionato
        let volumePath: String
        let volumeProjects = dataManager.projects.filter {
            $0.volumeIdentifier == selectedVolume && (dataManager.localProjectIDs?.contains($0.id) ?? true)
        }
        if let firstProject = volumeProjects.first {
            let parentPath = URL(fileURLWithPath: firstProject.path).deletingLastPathComponent().path
            volumePath = parentPath
        } else if let mounted = dataManager.connectedVolumes.first(where: { $0.name == selectedVolume }) {
            volumePath = mounted.url.path
        } else {
            volumePath = "/Volumes/\(selectedVolume)"
        }
        
        var cleanVolumePath = volumePath
        while cleanVolumePath.hasPrefix("//") { cleanVolumePath.removeFirst() }
        let projectPath = URL(fileURLWithPath: cleanVolumePath).standardized.appendingPathComponent(folderName).path
        
        // Verifica che il percorso non esista già
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: projectPath) else {
            dataManager.showError("Cartella progetto già esistente: \(folderName)")
            return
        }
        
        // Crea la cartella fisica
        do {
            try fileManager.createDirectory(atPath: projectPath, withIntermediateDirectories: true)
            
            // Crea il progetto nel database
            let project = VideoProject(
                name: folderName,
                path: projectPath,
                date: Date(),
                isOnline: true,
                volumeIdentifier: selectedVolume,
                folderSize: 0.0,
                folderContents: [],
                isAnalyzed: true,
                billingStatus: .toBill
            )
            
            dataManager.addProject(project)
            dataManager.updateProjectFolderSize(for: project.id)
            onProjectCreated?(project)
            
            if launchSecureCopyAfter {
                launchSecureCopy(for: projectPath, dataManager: dataManager)
            }
            
            dismiss()
            
        } catch {
            dataManager.showError("Errore nella creazione del progetto: \(error.localizedDescription)")
        }
    }
}

// Vista per inserire il percorso manualmente


class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupActivationPolicy()
    }
    
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            let image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "FolderFlow")
            image?.size = NSSize(width: 18, height: 18)
            image?.isTemplate = true
            button.image = image
        }
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Mostra FolderFlow", action: #selector(showApp), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "Sincronizza Ora", action: #selector(syncNow), keyEquivalent: "s"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Esci", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem?.menu = menu
    }
    
    func setupActivationPolicy() {
        let hideDock = UserDefaults.standard.bool(forKey: "HideDockIcon")
        if hideDock {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }
    
    @objc func showApp() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where !window.className.contains("NSStatusBarWindow") {
            // Garantisci che la finestra sia sempre all'interno dello schermo visibile
            if let screen = NSScreen.main {
                let screenRect = screen.visibleFrame
                let windowRect = window.frame
                let isOffscreen = !NSScreen.screens.contains(where: { $0.frame.intersects(windowRect) })
                    || windowRect.minY > screenRect.maxY
                    || windowRect.maxY < screenRect.minY
                    || windowRect.maxX < screenRect.minX
                    || windowRect.minX > screenRect.maxX
                
                if isOffscreen {
                    let newWidth: CGFloat = min(1500, screenRect.width * 0.85)
                    let newHeight: CGFloat = min(900, screenRect.height * 0.85)
                    let newX = screenRect.midX - (newWidth / 2)
                    let newY = screenRect.midY - (newHeight / 2)
                    window.setFrame(NSRect(x: newX, y: newY, width: newWidth, height: newHeight), display: true, animate: false)
                }
            }
            window.makeKeyAndOrderFront(nil)
            window.deminiaturize(nil)
            window.setIsVisible(true)
        }
    }
    
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { _ = GIDSignIn.sharedInstance.handle(url) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showApp()
        return true
    }
    
    @objc func syncNow() {
        NotificationCenter.default.post(name: NSNotification.Name("TriggerSyncNotification"), object: nil)
    }
    
    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

@main
@MainActor
struct FolderFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var dataManager: DataManager
    @StateObject private var folderScanner: FolderScanner
    @StateObject private var cloud: CloudService
    @StateObject private var workspace: CatalogWorkspace

    init() {
        var startupError: String?
        if let domain = Bundle.main.bundleIdentifier {
            do {
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                try LegacyPreferences.migrate(domain: domain, backupDirectory: support.appendingPathComponent("FolderFlow/PreferencesMigration"))
            } catch { startupError = "Impossibile recuperare le preferenze precedenti: \(error.localizedDescription). I dati originali sono conservati." }
        }
        let manager = DataManager(startupError: startupError)
        let service = CloudService()
        _dataManager = StateObject(wrappedValue: manager)
        _folderScanner = StateObject(wrappedValue: FolderScanner(dataManager: manager))
        _cloud = StateObject(wrappedValue: service)
        _workspace = StateObject(wrappedValue: CatalogWorkspace(manager: manager, cloud: service))
    }

    var body: some Scene {
        WindowGroup {
            CatalogAppView()
                .environmentObject(dataManager)
                .environmentObject(folderScanner)
                .environmentObject(cloud)
                .environmentObject(workspace)
                .frame(minWidth: 1200, minHeight: 800)
                .preferredColorScheme(.dark)
                .tint(StudioTheme.accent)
                .onAppear {
                    dataManager.refreshConnectedVolumes()
                    dataManager.updateOnlineStatus()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { appDelegate.showApp() }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TriggerSyncNotification"))) { _ in
                    Task { await folderScanner.syncAllVolumes() }
                }
        }
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}
