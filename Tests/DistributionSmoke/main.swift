import Foundation
import FirebaseCore
import FirebaseAuth
import GTMAppAuth

@main struct DistributionSmoke {
    static func main() async {
        do {
            let args = CommandLine.arguments
            guard args.count == 3, ["start", "restore"].contains(args[1]), UUID(uuidString: args[2]) != nil else {
                throw NSError(domain: "Explicit local-test arguments required", code: 1)
            }
            let options = FirebaseOptions(googleAppID: "1:123456789:ios:0123456789abcdef", gcmSenderID: "123456789")
            options.apiKey = "local-emulator-only"
            options.projectID = "demo-folderflow"
            let name = "DistributionSmoke-" + args[2]
            FirebaseApp.configure(name: name, options: options)
            let auth = Auth.auth(app: FirebaseApp.app(name: name)!)
            auth.useEmulator(withHost: "127.0.0.1", port: 19099)
            let store = KeychainStore(itemName: name, keychainAttributes: [.useFileBasedKeychain])
            let marker = Data("disposable-keychain-test".utf8)
            if args[1] == "start" {
                guard auth.currentUser == nil else { throw NSError(domain: "Test account already exists", code: 2) }
                try store.keychainHelper.setPassword(data: marker, forService: name, accessibility: nil)
                _ = try await auth.createUser(withEmail: "test-" + args[2].lowercased() + "@example.com", password: UUID().uuidString + "a1!")
                print("PASS: local Firebase account signed in and Google Keychain storage written")
            } else {
                guard let user = auth.currentUser, user.email == "test-" + args[2].lowercased() + "@example.com" else { throw NSError(domain: "Session not restored", code: 3) }
                defer { try? store.keychainHelper.removePassword(forService: name) }
                guard try store.keychainHelper.passwordData(forService: name) == marker else { throw NSError(domain: "Google Keychain marker not restored", code: 4) }
                try await user.reload()
                try await user.delete()
                try auth.signOut()
                print("PASS: session and Google Keychain storage survived process exit; local account and markers deleted")
            }
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
