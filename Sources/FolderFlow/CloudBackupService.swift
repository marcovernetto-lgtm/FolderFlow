import Foundation
import FirebaseFirestore

@MainActor
final class CloudBackupService: ObservableObject {
    @Published private(set) var items: [CloudBackupInfo] = []
    @Published private(set) var running = false
    @Published private(set) var loading = false
    @Published private(set) var hasMore = false
    @Published private var backupError: String?
    @Published private var historyError: String?
    var errorMessage: String? { backupError ?? historyError }
    private var retryAfter: [String: Date] = [:]
    private var failures: [String: Int] = [:]
    private var nextCleanup: [String: Date] = [:]
    private let cloud: CloudService
    private let launchID = UUID()
    private var completedOwners = Set<String>()
    private var selectedOwner: String?
    private var selectedCatalog: UUID?
    private var lastDocument: DocumentSnapshot?
    private var selectionSession = UUID()

    init(cloud: CloudService) { self.cloud = cloud }

    func reset() {
        selectionSession = UUID(); selectedOwner = nil; selectedCatalog = nil
        items = []; lastDocument = nil; hasMore = false; loading = false; backupError = nil; historyError = nil
    }

    func runIfNeeded(owner: String, deviceID: String) async {
        guard cloud.configured, cloud.online, cloud.user?.id == owner, !running, (!completedOwners.contains(owner) || (nextCleanup[owner] ?? .distantPast) <= Date()), (retryAfter[owner] ?? .distantPast) <= Date() else { return }
        running = true
        defer { running = false }
        do {
            if completedOwners.contains(owner) {
                try await removeExpiredCopies(owner: owner)
                try ensureOwner(owner)
                nextCleanup[owner] = Date().addingTimeInterval(24 * 60 * 60)
                backupError = nil; failures[owner] = nil; retryAfter[owner] = nil
                if selectedOwner == owner, let selectedCatalog { await refresh(owner: owner, catalogID: selectedCatalog) }
                return
            }
            let source = try await Firestore.firestore().collection("users").document(owner).collection("catalogs").getDocuments(source: .server)
            guard !source.documents.isEmpty else { return }
            for document in source.documents {
                try ensureOwner(owner)
                guard let catalogID = UUID(uuidString: document.documentID), let bytes = document.data()["payload"] as? Data else { throw CloudBackupError.invalid }
                let info = try CatalogArchive.decodeValue(CatalogInfo.self, bytes)
                guard info.id == catalogID else { throw CloudBackupError.invalid }
                let records = try await document.reference.collection("projects").getDocuments(source: .server)
                let projects = try records.documents.filter { ($0.data()["deleted"] as? Bool) != true }.map { record -> CatalogProject in
                    guard let bytes = record.data()["payload"] as? Data else { throw CloudBackupError.invalid }
                    let project = try CatalogArchive.decodeValue(CatalogProject.self, bytes)
                    guard project.id == UUID(uuidString: record.documentID) else { throw CloudBackupError.invalid }
                    return project
                }
                let snapshot = CloudBackupSnapshot(catalog: StoredCatalog(info: info, projects: projects), sourceDeviceID: deviceID, capturedAt: Date())
                let encoded = try await Task.detached(priority: .utility) { try CloudBackupCodec.encode(snapshot) }.value
                try ensureOwner(owner)
                try await upload(encoded, catalogID: catalogID, projectCount: projects.count, owner: owner)
            }
            try await removeExpiredCopies(owner: owner)
            try ensureOwner(owner)
            completedOwners.insert(owner); nextCleanup[owner] = Date().addingTimeInterval(24 * 60 * 60); backupError = nil; failures[owner] = nil; retryAfter[owner] = nil
            if selectedOwner == owner, let selectedCatalog { await refresh(owner: owner, catalogID: selectedCatalog) }
        } catch {
            if cloud.user?.id == owner {
                backupError = error.localizedDescription
                let count = min((failures[owner] ?? 0) + 1, 7); failures[owner] = count
                retryAfter[owner] = Date().addingTimeInterval(min(3600, pow(2, Double(count)) * 30))
            }
        }
    }

    func refresh(owner: String?, catalogID: UUID?) async {
        selectionSession = UUID(); let session = selectionSession
        selectedOwner = owner; selectedCatalog = catalogID; items = []; lastDocument = nil; hasMore = false
        guard let owner, let catalogID, cloud.configured, cloud.online, cloud.user?.id == owner else { return }
        loading = true
        defer { if session == selectionSession { loading = false } }
        do {
            let result = try await versions(owner: owner, catalogID: catalogID).order(by: "createdAt", descending: true).limit(to: 5).getDocuments(source: .server)
            guard session == selectionSession, cloud.user?.id == owner else { return }
            items = try result.documents.map { try decodeInfo($0, catalogID: catalogID) }
            lastDocument = result.documents.last; hasMore = result.documents.count == 5; historyError = nil
        } catch { if session == selectionSession { historyError = error.localizedDescription } }
    }

    func loadMore() async {
        guard !loading, let owner = selectedOwner, let catalogID = selectedCatalog, let lastDocument, cloud.online else { return }
        let session = selectionSession; loading = true
        defer { if session == selectionSession { loading = false } }
        do {
            try ensureOwner(owner)
            let result = try await versions(owner: owner, catalogID: catalogID).order(by: "createdAt", descending: true).start(afterDocument: lastDocument).limit(to: 5).getDocuments(source: .server)
            guard session == selectionSession, cloud.user?.id == owner else { return }
            items += try result.documents.map { try decodeInfo($0, catalogID: catalogID) }
            self.lastDocument = result.documents.last; hasMore = result.documents.count == 5; historyError = nil
        } catch { if session == selectionSession { historyError = error.localizedDescription } }
    }

    func read(_ info: CloudBackupInfo, owner: String) async throws -> CloudBackupSnapshot {
        try ensureOwner(owner)
        let result = try await versions(owner: owner, catalogID: info.catalogID).document(info.id.uuidString).collection("chunks").getDocuments(source: .server)
        try ensureOwner(owner)
        let chunks = try (0..<info.chunkCount).map { index -> Data in
            guard let document = result.documents.first(where: { $0.documentID == String(index) }), let data = document.data()["payload"] as? Data else { throw CloudBackupError.invalid }
            return data
        }
        return try await Task.detached(priority: .utility) { try CloudBackupCodec.decode(chunks, info: info) }.value
    }

    private func upload(_ encoded: EncodedCloudBackup, catalogID: UUID, projectCount: Int, owner: String) async throws {
        let root = backupRoots(owner).document(catalogID.uuidString)
        let version = root.collection("versions").document(launchID.uuidString)
        if try await version.getDocument(source: .server).exists { return } // Retry the same launch without duplicating a completed copy.
        try ensureOwner(owner)
        let batch = Firestore.firestore().batch()
        batch.setData(["updatedAt": FieldValue.serverTimestamp()], forDocument: root)
        batch.setData(["createdAt": FieldValue.serverTimestamp(), "format": 1, "rawSize": encoded.rawSize,
                       "compressedSize": encoded.data.count, "chunkCount": encoded.chunks.count,
                       "checksum": encoded.checksum, "projectCount": projectCount], forDocument: version)
        for (index, chunk) in encoded.chunks.enumerated() {
            batch.setData(["index": index, "payload": chunk], forDocument: version.collection("chunks").document(String(index)))
        }
        try await batch.commit()
    }

    // This function can only build references inside the backups namespace.
    private func removeExpiredCopies(owner: String) async throws {
        let cutoff = Date().addingTimeInterval(-CloudBackupCodec.retention)
        let roots = try await backupRoots(owner).getDocuments(source: .server)
        for root in roots.documents {
            let expired = try await root.reference.collection("versions").whereField("createdAt", isLessThan: Timestamp(date: cutoff)).getDocuments(source: .server)
            for version in expired.documents {
                try ensureOwner(owner)
                let chunks = try await version.reference.collection("chunks").getDocuments(source: .server)
                guard chunks.documents.count <= 16 else { throw CloudBackupError.invalid }
                let batch = Firestore.firestore().batch()
                for chunk in chunks.documents { batch.deleteDocument(chunk.reference) }
                batch.deleteDocument(version.reference)
                try await batch.commit()
            }
        }
    }

    private func backupRoots(_ owner: String) -> CollectionReference { Firestore.firestore().collection("users").document(owner).collection("backups") }
    private func versions(owner: String, catalogID: UUID) -> CollectionReference { backupRoots(owner).document(catalogID.uuidString).collection("versions") }
    private func ensureOwner(_ owner: String) throws { guard cloud.online, cloud.user?.id == owner else { throw CloudServiceError.offline } }
    private func decodeInfo(_ document: QueryDocumentSnapshot, catalogID: UUID) throws -> CloudBackupInfo {
        let data = document.data()
        guard let id = UUID(uuidString: document.documentID), let date = (data["createdAt"] as? Timestamp)?.dateValue(),
              data["format"] as? Int == 1, let rawSize = data["rawSize"] as? Int, (1...CloudBackupCodec.maxRawSize).contains(rawSize),
              let size = data["compressedSize"] as? Int, (1...CloudBackupCodec.maxCompressedSize).contains(size),
              let count = data["chunkCount"] as? Int, (1...16).contains(count), let checksum = data["checksum"] as? String, checksum.count == 64,
              let projectCount = data["projectCount"] as? Int, projectCount >= 0 else { throw CloudBackupError.invalid }
        return CloudBackupInfo(id: id, catalogID: catalogID, createdAt: date, rawSize: rawSize, compressedSize: size, chunkCount: count, checksum: checksum, projectCount: projectCount)
    }
}
