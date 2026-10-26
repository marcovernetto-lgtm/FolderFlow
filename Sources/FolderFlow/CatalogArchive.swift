import Foundation
import CryptoKit

struct CatalogInfo: Codable, Identifiable {
    let id: UUID
    var name: String
    let createdAt: Date
    var namingPattern: String
    var colors: [String: ColorRGB]

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100,
              ProjectNaming(pattern: namingPattern).validationError == nil,
              colors.values.allSatisfy({ color in [color.red, color.green, color.blue, color.alpha].allSatisfy { $0.isFinite && (0...1).contains($0) } }) else { throw CatalogArchiveError.invalidIdentity }
    }
}

struct CatalogProject: Codable, Identifiable {
    let id: UUID
    var name: String
    var date: Date
    var volumeName: String
    var volumeUUID: String?
    var sourceDeviceID: String
    var sourcePath: String
    var relativePath: String?
    var folderSize: Double
    var folderContents: [String]
    var isAnalyzed: Bool
    var billingStatus: BillingStatus
    var deadline: Date?
    var isCompleted: Bool
    var comments: String
}

extension CatalogProject {
    func validate() throws {
        guard !name.isEmpty, name.count <= 1024, !volumeName.isEmpty, !sourceDeviceID.isEmpty,
              sourcePath.hasPrefix("/"), folderSize.isFinite, folderSize >= 0,
              relativePath.map({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }) ?? true else { throw CatalogArchiveError.invalidIdentity }
    }
}

struct DeviceCatalogState: Codable {
    var monitoredPaths: [String] = []
    var projectPaths: [String: String] = [:]
}

struct StoredCatalog: Codable, Identifiable {
    var info: CatalogInfo
    var id: UUID { info.id }
    var projects: [CatalogProject] = []
    var device = DeviceCatalogState()
    func validate() throws {
        try info.validate()
        guard Set(projects.map(\.id)).count == projects.count else { throw CatalogArchiveError.invalidIdentity }
        try projects.forEach { try $0.validate() }
    }
}

struct SharedAppPreferences: Codable, Equatable {
    var launchAtLogin = false
    var hideDockIcon = false
}

// Keep the legacy catalog/project JSON shape so existing offline queues stay readable.
enum CatalogObject: Codable, Hashable {
    case catalog(UUID)
    case project(catalogID: UUID, projectID: UUID)
    case preferences

    init(catalogID: UUID, projectID: UUID? = nil) {
        self = projectID.map { .project(catalogID: catalogID, projectID: $0) } ?? .catalog(catalogID)
    }
    var catalogID: UUID? {
        switch self {
        case .catalog(let id), .project(let id, _): return id
        case .preferences: return nil
        }
    }
    var projectID: UUID? { if case .project(_, let id) = self { return id }; return nil }
    var key: String {
        guard let catalogID else { return "preferences" }
        return catalogID.uuidString + "/" + (projectID?.uuidString ?? "catalog")
    }
    private enum CodingKeys: String, CodingKey { case catalogID, projectID, kind }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let kind = try values.decodeIfPresent(String.self, forKey: .kind) {
            guard kind == "preferences" else { throw CatalogArchiveError.unsupportedVersion }
            self = .preferences
        } else { self.init(catalogID: try values.decode(UUID.self, forKey: .catalogID), projectID: try values.decodeIfPresent(UUID.self, forKey: .projectID)) }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if self == .preferences { try values.encode("preferences", forKey: .kind) }
        else {
            try values.encode(catalogID, forKey: .catalogID)
            try values.encodeIfPresent(projectID, forKey: .projectID)
        }
    }
}

struct CatalogMutation: Codable, Identifiable {
    var id = UUID()
    var object: CatalogObject
    var baseRevision: Int
    var payload: Data?
}

struct CatalogRemoteValue: Codable {
    var object: CatalogObject
    var revision: Int
    var mutationID: UUID
    var payload: Data?
}

struct CatalogConflict: Codable, Identifiable {
    var id: String { remote.object.key }
    var remote: CatalogRemoteValue
}

struct CatalogArchive: Codable {
    var schemaVersion = 1
    var catalogs: [StoredCatalog] = []
    var activeCatalogID: UUID?
    var preferences: SharedAppPreferences?
    var revisions: [String: Int] = [:]
    var pending: [String: CatalogMutation] = [:]
    var conflicts: [String: CatalogConflict] = [:]

    mutating func enqueue(_ object: CatalogObject, payload: Data?) {
        let base = pending[object.key]?.baseRevision ?? revisions[object.key] ?? 0
        pending[object.key] = CatalogMutation(object: object, baseRevision: base, payload: payload)
    }

    mutating func apply(_ value: CatalogRemoteValue) throws {
        if value.object == .preferences {
            guard let data = value.payload else { throw CatalogArchiveError.invalidIdentity }
            preferences = try Self.decodeValue(SharedAppPreferences.self, data)
        } else if value.object.projectID == nil {
            guard let data = value.payload else { return }
            let info = try Self.decodeValue(CatalogInfo.self, data)
            try info.validate()
            guard info.id == value.object.catalogID else { throw CatalogArchiveError.invalidIdentity }
            if let index = catalogs.firstIndex(where: { $0.id == info.id }) { catalogs[index].info = info }
            else { catalogs.append(StoredCatalog(info: info)) }
        } else {
            guard let index = catalogs.firstIndex(where: { $0.id == value.object.catalogID }) else { return }
            if let data = value.payload {
                let project = try Self.decodeValue(CatalogProject.self, data)
                try project.validate()
                guard project.id == value.object.projectID else { throw CatalogArchiveError.invalidIdentity }
                if let i = catalogs[index].projects.firstIndex(where: { $0.id == project.id }) { catalogs[index].projects[i] = project }
                else { catalogs[index].projects.append(project) }
            } else {
                catalogs[index].projects.removeAll { $0.id == value.object.projectID }
            }
        }
        revisions[value.object.key] = value.revision
        if activeCatalogID == nil { activeCatalogID = catalogs.first?.id }
    }

    mutating func receive(_ value: CatalogRemoteValue) throws {
        guard value.revision >= (revisions[value.object.key] ?? 0) else { return }
        if let local = pending[value.object.key] {
            if value.mutationID == local.id { try acknowledge(value, mutationID: local.id) }
            return // Keep optimistic local edits until the server transaction acknowledges or reports a conflict.
        }
        try apply(value)
    }

    mutating func acknowledge(_ value: CatalogRemoteValue, mutationID: UUID) throws {
        revisions[value.object.key] = value.revision
        if pending[value.object.key]?.id == mutationID {
            pending.removeValue(forKey: value.object.key)
            conflicts.removeValue(forKey: value.object.key)
        } else if pending[value.object.key] != nil {
            pending[value.object.key]?.baseRevision = value.revision
        }
    }

    mutating func resolve(_ key: String, keepLocal: Bool) throws {
        guard let conflict = conflicts[key] else { return }
        if keepLocal {
            pending[key]?.baseRevision = conflict.remote.revision
            pending[key]?.id = UUID()
        } else {
            pending.removeValue(forKey: key)
            try apply(conflict.remote)
        }
        conflicts.removeValue(forKey: key)
    }

    static func encodeValue<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func decodeValue<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T { try JSONDecoder().decode(type, from: data) }
}

enum CatalogArchiveError: LocalizedError {
    case unreadable, invalidIdentity, unsupportedVersion, unableToSave
    var errorDescription: String? {
        switch self {
        case .unableToSave: return "Il catalogo non è stato salvato. La copia precedente è conservata; controlla lo spazio disponibile e riprova."
        case .unreadable: return "Il catalogo locale non è leggibile. I file sono stati conservati; ripristina un backup prima di continuare."
        case .invalidIdentity: return "Il catalogo ricevuto contiene un identificativo non valido."
        case .unsupportedVersion: return "Questo catalogo richiede una versione più recente di FolderFlow."
        }
    }
}

struct CatalogArchiveFile {
    let root: URL
    func url(for owner: String?) -> URL {
        let name = owner.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() } ?? "local"
        return root.appendingPathComponent(name + ".json")
    }
    func load(owner: String?) throws -> CatalogArchive? {
        let file = url(for: owner)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        for candidate in [file, file.appendingPathExtension("previous")] {
            if let data = try? Data(contentsOf: candidate), let archive = try? CatalogArchive.decodeValue(CatalogArchive.self, data) {
                guard archive.schemaVersion == 1 else { throw CatalogArchiveError.unsupportedVersion }
                try archive.catalogs.forEach { try $0.validate() }
                guard Set(archive.catalogs.map(\.id)).count == archive.catalogs.count else { throw CatalogArchiveError.invalidIdentity }
                return archive
            }
        }
        throw CatalogArchiveError.unreadable
    }
    func save(_ archive: CatalogArchive, owner: String?) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = url(for: owner)
        let data = try CatalogArchive.encodeValue(archive)
        if let old = try? Data(contentsOf: file), (try? CatalogArchive.decodeValue(CatalogArchive.self, old)) != nil {
            try old.write(to: file.appendingPathExtension("previous"), options: .atomic)
        }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
