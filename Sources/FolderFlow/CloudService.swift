import Foundation
import AppKit
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
import GoogleSignIn
import Network

struct CloudUser: Equatable {
    let id: String
    let email: String
    let displayName: String
}

enum CatalogCommitResult {
    case accepted(CatalogRemoteValue)
    case conflict(CatalogRemoteValue)
}

@MainActor
protocol CatalogTransport: AnyObject {
    func commit(owner: String, mutation: CatalogMutation) async throws -> CatalogCommitResult
}

@MainActor
final class CloudService: ObservableObject, CatalogTransport {
    @Published private(set) var user: CloudUser?
    @Published private(set) var configured = false
    @Published private(set) var online = true
    @Published private(set) var authenticating = false
    @Published var errorMessage: String?
    @Published var information: String?
    private var authListener: AuthStateDidChangeListenerHandle?
    private var listeners: [ListenerRegistration] = []
    private var projectListeners: [String: ListenerRegistration] = [:]
    private let network = NWPathMonitor()
    private var receive: ((CatalogRemoteValue) -> Void)?
    private var listenerSession = UUID()

    init(configure: Bool = true) {
        guard configure else { return }
        #if SWIFT_PACKAGE
        let resourceBundle = Bundle.module
        #else
        let resourceBundle = Bundle.main
        #endif
        let file = resourceBundle.url(forResource: "GoogleService-Info", withExtension: "plist")
        if let file, let options = FirebaseOptions(contentsOfFile: file.path), options.projectID != nil {
            if FirebaseApp.app() == nil { FirebaseApp.configure(options: options) }
            configured = true
            user = Self.profile(Auth.auth().currentUser)
            authListener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
                Task { @MainActor in self?.user = Self.profile(user) }
            }
        }
        network.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.online = path.status == .satisfied }
        }
        network.start(queue: DispatchQueue(label: "FolderFlow.network"))
    }

    deinit {
        network.cancel()
        if let authListener { Auth.auth().removeStateDidChangeListener(authListener) }
        listeners.forEach { $0.remove() }
        projectListeners.values.forEach { $0.remove() }
    }

    private static func profile(_ user: User?) -> CloudUser? {
        user.map { CloudUser(id: $0.uid, email: $0.email ?? "", displayName: $0.displayName ?? $0.email ?? "Il mio account") }
    }

    func signInWithGoogle() async {
        guard !authenticating else { return }
        guard configured, let clientID = FirebaseApp.app()?.options.clientID else {
            errorMessage = "Il servizio cloud non è ancora attivato per questa versione di FolderFlow. Puoi usare i cataloghi sul Mac."
            return
        }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        authenticating = true; errorMessage = nil
        defer { authenticating = false }
        do {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: window)
            guard let token = result.user.idToken?.tokenString else { throw CloudServiceError.invalidResponse }
            let credential = GoogleAuthProvider.credential(withIDToken: token, accessToken: result.user.accessToken.tokenString)
            _ = try await Auth.auth().signIn(with: credential)
        } catch { errorMessage = error.localizedDescription }
    }

    func signIn(email: String, password: String, create: Bool) async {
        guard !authenticating else { return }
        guard configured else { errorMessage = "Il servizio cloud non è ancora attivato per questa copia."; return }
        authenticating = true; errorMessage = nil
        defer { authenticating = false }
        do {
            let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
            if create { _ = try await Auth.auth().createUser(withEmail: email, password: password) }
            else { _ = try await Auth.auth().signIn(withEmail: email, password: password) }
        } catch { errorMessage = error.localizedDescription }
    }

    func resetPassword(email: String) async {
        guard configured else { return }
        do {
            try await Auth.auth().sendPasswordReset(withEmail: email.trimmingCharacters(in: .whitespacesAndNewlines))
            information = "Se l'indirizzo è associato a un account, riceverai le istruzioni per cambiare password."
        } catch { errorMessage = error.localizedDescription }
    }

    func signOut() {
        guard configured else { return }
        do {
            try Auth.auth().signOut()
            stopListening()
            GIDSignIn.sharedInstance.signOut()
            user = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func stopListening() {
        listenerSession = UUID()
        listeners.forEach { $0.remove() }; listeners = []
        projectListeners.values.forEach { $0.remove() }; projectListeners = [:]
        receive = nil
    }

    func startListening(owner: String, preferencesMissing: @escaping () -> Void = {}, receive: @escaping (CatalogRemoteValue) -> Void) {
        stopListening()
        guard configured else { return }
        self.receive = receive
        let session = listenerSession
        let preferences = Firestore.firestore().collection("users").document(owner).collection("settings").document("preferences")
        listeners.append(preferences.addSnapshotListener(includeMetadataChanges: true) { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self, self.user?.id == owner, self.listenerSession == session else { return }
                if let error { self.errorMessage = error.localizedDescription; return }
                guard let snapshot else { return }
                if let data = snapshot.data() {
                    do { self.receive?(try Self.remote(data, object: .preferences)) }
                    catch { self.errorMessage = error.localizedDescription }
                } else if !snapshot.metadata.isFromCache { preferencesMissing() }
            }
        })
        let collection = Firestore.firestore().collection("users").document(owner).collection("catalogs")
        listeners.append(collection.addSnapshotListener { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self, self.user?.id == owner, self.listenerSession == session else { return }
                if let error { self.errorMessage = error.localizedDescription; return }
                for change in snapshot?.documentChanges ?? [] {
                    let document = change.document
                    guard let catalogID = UUID(uuidString: document.documentID) else { continue }
                    if let value = try? Self.remote(document.data(), object: CatalogObject(catalogID: catalogID)) { self.receive?(value) }
                    if self.projectListeners[document.documentID] == nil {
                        self.projectListeners[document.documentID] = document.reference.collection("projects").addSnapshotListener { [weak self] projects, error in
                            Task { @MainActor in
                                guard let self, self.user?.id == owner, self.listenerSession == session else { return }
                                if let error { self.errorMessage = error.localizedDescription; return }
                                for change in projects?.documentChanges ?? [] {
                                    let project = change.document
                                    guard let projectID = UUID(uuidString: project.documentID),
                                          let value = try? Self.remote(project.data(), object: CatalogObject(catalogID: catalogID, projectID: projectID)) else { continue }
                                    self.receive?(value)
                                }
                            }
                        }
                    }
                }
            }
        })
    }

    nonisolated private static func remote(_ data: [String: Any], object: CatalogObject) throws -> CatalogRemoteValue {
        guard let revision = data["revision"] as? Int, revision > 0,
              let mutation = data["mutationID"] as? String, let mutationID = UUID(uuidString: mutation),
              let deleted = data["deleted"] as? Bool else { throw CloudServiceError.invalidResponse }
        let payload = data["payload"] as? Data
        guard deleted || payload != nil else { throw CloudServiceError.invalidResponse }
        return CatalogRemoteValue(object: object, revision: revision, mutationID: mutationID, payload: deleted ? nil : payload)
    }

    func commit(owner: String, mutation: CatalogMutation) async throws -> CatalogCommitResult {
        guard configured, online, user?.id == owner else { throw CloudServiceError.offline }
        guard (mutation.payload?.count ?? 0) < 700_000 else { throw CloudServiceError.tooLarge }
        let object = mutation.object
        let account = Firestore.firestore().collection("users").document(owner)
        let document: DocumentReference
        if let catalogID = object.catalogID {
            let catalog = account.collection("catalogs").document(catalogID.uuidString)
            document = object.projectID.map { catalog.collection("projects").document($0.uuidString) } ?? catalog
        } else {
            document = account.collection("settings").document("preferences")
        }
        return try await withCheckedThrowingContinuation { continuation in
            Firestore.firestore().runTransaction({ transaction, errorPointer -> Any? in
                do {
                    let snapshot = try transaction.getDocument(document)
                    let old = try snapshot.data().map { try Self.remote($0, object: object) }
                    if let old, old.mutationID == mutation.id { return CloudTransactionBox(.accepted(old)) }
                    if (old?.revision ?? 0) != mutation.baseRevision {
                        guard let old else { throw CloudServiceError.invalidResponse }
                        return CloudTransactionBox(.conflict(old))
                    }
                    let revision = (old?.revision ?? 0) + 1
                    transaction.setData(["revision": revision, "mutationID": mutation.id.uuidString,
                                         "deleted": mutation.payload == nil, "payload": mutation.payload ?? Data(),
                                         "updatedAt": FieldValue.serverTimestamp()], forDocument: document)
                    return CloudTransactionBox(.accepted(CatalogRemoteValue(object: object, revision: revision, mutationID: mutation.id, payload: mutation.payload)))
                } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }
            }, completion: { result, error in
                if let error { continuation.resume(throwing: error) }
                else if let box = result as? CloudTransactionBox { continuation.resume(returning: box.value) }
                else { continuation.resume(throwing: CloudServiceError.invalidResponse) }
            })
        }
    }
}

private final class CloudTransactionBox: NSObject {
    let value: CatalogCommitResult
    init(_ value: CatalogCommitResult) { self.value = value }
}

enum CloudServiceError: LocalizedError {
    case offline, invalidResponse, tooLarge
    var errorDescription: String? {
        switch self {
        case .offline: return "Sei offline. Le modifiche restano salvate su questo Mac."
        case .invalidResponse: return "Il servizio ha restituito dati non validi. Il catalogo locale è conservato."
        case .tooLarge: return "Questo elemento supera la dimensione consentita dal cloud. La copia locale è conservata."
        }
    }
}
