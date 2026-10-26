import Foundation
import CryptoKit
import Compression

struct CloudBackupSnapshot: Codable {
    var format = 1
    var catalog: StoredCatalog
    var sourceDeviceID: String
    var capturedAt: Date
}

struct CloudBackupInfo: Identifiable {
    let id: UUID
    let catalogID: UUID
    let createdAt: Date
    let rawSize: Int
    let compressedSize: Int
    let chunkCount: Int
    let checksum: String
    let projectCount: Int
}

struct EncodedCloudBackup {
    let rawSize: Int
    let data: Data
    let checksum: String
    var chunks: [Data] {
        stride(from: 0, to: data.count, by: CloudBackupCodec.chunkSize).map { data.subdata(in: $0..<min($0 + CloudBackupCodec.chunkSize, data.count)) }
    }
}

enum CloudBackupCodec {
    static let retentionDays = 60
    static let retention: TimeInterval = 60 * 24 * 60 * 60
    static let chunkSize = 600_000
    static let maxRawSize = 64 * 1024 * 1024
    static let maxCompressedSize = 8 * 1024 * 1024

    static func encode(_ snapshot: CloudBackupSnapshot) throws -> EncodedCloudBackup {
        try snapshot.catalog.validate()
        let raw = try CatalogArchive.encodeValue(snapshot)
        guard !raw.isEmpty, raw.count <= maxRawSize else { throw CloudBackupError.tooLarge }
        var buffer = Data(count: raw.count + 1024)
        let capacity = buffer.count
        let count = buffer.withUnsafeMutableBytes { output in
            raw.withUnsafeBytes { input in
                compression_encode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          input.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard count > 0, count <= maxCompressedSize else { throw CloudBackupError.tooLarge }
        buffer.count = count
        return EncodedCloudBackup(rawSize: raw.count, data: buffer, checksum: hash(raw))
    }

    static func decode(_ chunks: [Data], info: CloudBackupInfo) throws -> CloudBackupSnapshot {
        guard (1...maxRawSize).contains(info.rawSize), (1...maxCompressedSize).contains(info.compressedSize),
              (1...16).contains(info.chunkCount), chunks.count == info.chunkCount,
              chunks.allSatisfy({ !$0.isEmpty && $0.count <= chunkSize }) else { throw CloudBackupError.invalid }
        let compressed = chunks.reduce(into: Data()) { $0.append($1) }
        guard compressed.count == info.compressedSize else { throw CloudBackupError.invalid }
        var raw = Data(count: info.rawSize + 1)
        let capacity = raw.count
        let count = raw.withUnsafeMutableBytes { output in
            compressed.withUnsafeBytes { input in
                compression_decode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          input.bindMemory(to: UInt8.self).baseAddress!, compressed.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard count == info.rawSize else { throw CloudBackupError.invalid }
        raw.count = count
        guard hash(raw) == info.checksum else { throw CloudBackupError.invalid }
        let snapshot = try CatalogArchive.decodeValue(CloudBackupSnapshot.self, raw)
        guard snapshot.format == 1, snapshot.catalog.id == info.catalogID, !snapshot.sourceDeviceID.isEmpty,
              snapshot.catalog.projects.count == info.projectCount else { throw CloudBackupError.invalid }
        try snapshot.catalog.validate()
        return snapshot
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

enum CloudBackupError: LocalizedError {
    case invalid, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalid: return "La copia di sicurezza non è completa o non è valida. Il catalogo attuale è conservato."
        case .tooLarge: return "Il catalogo supera la dimensione consentita per il backup online. Le copie locali restano disponibili."
        }
    }
}
