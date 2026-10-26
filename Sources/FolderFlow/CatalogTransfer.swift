import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct CatalogTransfer: Identifiable {
    let id = UUID()
    let catalog: StoredCatalog
    let sourceDeviceID: String?
    let exportDate: Date

    static func read(_ url: URL, deviceID: String) throws -> CatalogTransfer {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return try decode(Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent, deviceID: deviceID)
    }

    static func decode(_ data: Data, name: String, deviceID: String) throws -> CatalogTransfer {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let appData: AppData
        do { appData = try decoder.decode(AppData.self, from: data) }
        catch {
            // Some older JSON exports use Foundation's numeric date encoding.
            do { appData = try JSONDecoder().decode(AppData.self, from: data) }
            catch { throw CatalogTransferError.unsupportedFile }
        }
        if let catalog = appData.catalog {
            try catalog.validate()
            return CatalogTransfer(catalog: catalog, sourceDeviceID: appData.sourceDeviceID, exportDate: appData.exportDate)
        }
        let info = CatalogInfo(id: UUID(), name: String(name.prefix(100)), createdAt: appData.exportDate,
                               namingPattern: ProjectNaming.defaultPattern, colors: appData.volumeColors)
        let projects = appData.projects.map { project in
            CatalogProject(id: project.id, name: project.name, date: project.date, volumeName: project.volumeIdentifier,
                           volumeUUID: nil, sourceDeviceID: deviceID, sourcePath: project.path, relativePath: nil,
                           folderSize: project.folderSize, folderContents: project.folderContents, isAnalyzed: project.isAnalyzed,
                           billingStatus: project.billingStatus, deadline: project.deadline, isCompleted: project.isCompleted, comments: project.comments)
        }
        let device = DeviceCatalogState(monitoredPaths: (appData.monitoredPaths ?? []).filter { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) },
                                       projectPaths: Dictionary(projects.map { ($0.id.uuidString, $0.sourcePath) }, uniquingKeysWith: { first, _ in first }))
        let catalog = StoredCatalog(info: info, projects: projects, device: device)
        try catalog.validate()
        return CatalogTransfer(catalog: catalog, sourceDeviceID: deviceID, exportDate: appData.exportDate)
    }
}

enum CatalogTransferError: LocalizedError {
    case unsupportedFile, contextChanged, noCatalog
    var errorDescription: String? {
        switch self {
        case .unsupportedFile: return "Questo file non è un catalogo FolderFlow valido. Scegli un’esportazione JSON o una copia di sicurezza dell’app."
        case .contextChanged: return "L’account o il catalogo selezionato è cambiato. Chiudi l’anteprima e riprova."
        case .noCatalog: return "Seleziona un catalogo prima di creare una copia."
        }
    }
}

struct CatalogBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
