import SwiftUI
import UniformTypeIdentifiers

struct CatalogManagementView: View {
    @EnvironmentObject var workspace: CatalogWorkspace
    @EnvironmentObject var cloud: CloudService
    @EnvironmentObject var dataManager: DataManager
    @State private var showLogin = false
    @State private var showNewCatalog = false
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var document: CatalogBackupDocument?
    @State private var pendingImport: ImportRequest?
    @State private var backups: [URL] = []
    @State private var busy = false
    @State private var message: String?
    @State private var failure: String?
    @State private var advanced = false
    @State private var bulkAction: BulkAction?

    private struct ImportRequest: Identifiable {
        let id = UUID()
        let transfer: CatalogTransfer
        let filename: String
        let restoring: Bool
        let owner: String?
        let target: UUID?
    }
    private enum BulkAction: String, Identifiable {
        case billed = "Segna tutti fatturati", completed = "Segna tutti conclusi", toBill = "Segna tutti da fatturare", clear = "Svuota catalogo"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                account
                Divider().overlay(StudioTheme.line)
                catalogs
                if let message { Label(message, systemImage: "checkmark.circle").foregroundColor(StudioTheme.green).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) }
                if let failure { Label(failure, systemImage: "exclamationmark.circle").foregroundColor(StudioTheme.red).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                Divider().overlay(StudioTheme.line)
                onlineBackupSection
                if !workspace.localCatalogsToImport.isEmpty {
                    Divider().overlay(StudioTheme.line)
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Cataloghi precedenti su questo Mac").font(.system(size: 13, weight: .semibold))
                        }
                        Spacer()
                        Button("Aggiungi all’account") {
                            let count = workspace.importLocalCatalogs()
                            if count > 0 { message = "Aggiunti \(count) cataloghi all’account." }
                            else { failure = workspace.errorMessage ?? "Questi cataloghi sono già presenti nell’account." }
                        }
                        .buttonStyle(ModernButtonStyle(color: StudioTheme.accent)).disabled(busy || workspace.readOnly)
                    }
                }
                if !workspace.archive.conflicts.isEmpty {
                    Divider().overlay(StudioTheme.line)
                    Text("Modifiche da confrontare").font(.system(size: 15, weight: .semibold))
                    ForEach(workspace.archive.conflicts.values.sorted { $0.id < $1.id }) { CatalogConflictView(conflict: $0) }
                }
                DisclosureGroup("Operazioni avanzate", isExpanded: $advanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach([BulkAction.billed, .completed, .toBill, .clear]) { action in
                            Button(action.rawValue) { bulkAction = action }
                                .buttonStyle(.plain).foregroundColor(action == .clear ? StudioTheme.red : StudioTheme.accent)
                                .disabled(busy || workspace.readOnly || dataManager.projects.isEmpty)
                        }
                        Divider().overlay(StudioTheme.line)
                        Text("Copie locali").font(.system(size: 12, weight: .semibold))
                        localBackupRows
                    }.padding(.top, 12)
                }
                .font(.system(size: 12, weight: .medium)).foregroundColor(StudioTheme.secondary)
            }
            .padding(.bottom, 8)
        }
        .foregroundColor(StudioTheme.text)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): prepareImport(url, restoring: false)
            case .failure(let error): if (error as NSError).code != NSUserCancelledError { failure = error.localizedDescription }
            }
        }
        .fileExporter(isPresented: $showExporter, document: document, contentType: .json,
                      defaultFilename: "FolderFlow_\(workspace.active?.info.name ?? "Catalogo")") { result in
            switch result {
            case .success(let url): message = "Catalogo esportato in \(url.lastPathComponent)."; failure = nil
            case .failure(let error): if (error as NSError).code != NSUserCancelledError { failure = error.localizedDescription }
            }
        }
        .sheet(isPresented: $showLogin) { CloudAccountView() }
        .sheet(isPresented: $showNewCatalog) { NewCatalogSheet() }
        .sheet(item: $pendingImport) { request in
            CatalogImportReview(transfer: request.transfer, filename: request.filename, restoring: request.restoring,
                                owner: request.owner, target: request.target) { text in
                message = text; failure = nil; reloadBackups()
            }
        }
        .alert(item: $bulkAction) { action in
            Alert(title: Text(action.rawValue + "?"),
                  message: Text("L’operazione riguarda \(dataManager.projects.count) progetti di «\(workspace.active?.info.name ?? "")». I file sugli HD rimangono conservati."),
                  primaryButton: .destructive(Text("Continua")) { performBulk(action) }, secondaryButton: .cancel(Text("Annulla")))
        }
        .onAppear(perform: reloadBackups)
        .onChange(of: workspace.archive.activeCatalogID) { _ in reloadBackups() }
        .onChange(of: workspace.ownerID) { _ in
            showImporter = false; showExporter = false; pendingImport = nil; document = nil
            message = nil; failure = nil; reloadBackups()
        }
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle").font(.system(size: 30)).foregroundColor(StudioTheme.accent)
                Text(cloud.user?.displayName ?? "Su questo Mac")
                    .font(.system(size: 16, weight: .semibold))
                    .help(cloud.user?.email ?? "Account")
                Spacer()
                if cloud.user != nil {
                    Button("Esci dall’account") { cloud.signOut() }.disabled(busy).buttonStyle(.plain).font(.system(size: 12)).foregroundColor(StudioTheme.secondary)
                } else {
                    Button("Accedi") { showLogin = true }.buttonStyle(ModernButtonStyle(color: StudioTheme.accent, isPrimary: true))
                }
            }
            if cloud.user != nil {
                if let error = workspace.errorMessage ?? cloud.errorMessage {
                    Text(error).font(.system(size: 12)).foregroundColor(StudioTheme.red).textSelection(.enabled)
                    Button("Riprova l’invio delle modifiche") { Task { await workspace.synchronize() } }
                        .buttonStyle(.plain).foregroundColor(StudioTheme.accent).disabled(workspace.syncing || !cloud.online)
                }
            }
        }
    }

    private var catalogs: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(workspace.archive.catalogs) { catalog in
                Button { workspace.selectCatalog(catalog.id) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.stack").foregroundColor(StudioTheme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(catalog.info.name).font(.system(size: 13, weight: .medium)).lineLimit(2)
                            Text("\(catalog.projects.count) progetti").font(.system(size: 11)).foregroundColor(StudioTheme.secondary)
                        }
                        Spacer()
                        if catalog.id == workspace.archive.activeCatalogID { Image(systemName: "checkmark.circle.fill").foregroundColor(StudioTheme.accent) }
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(catalog.id == workspace.archive.activeCatalogID ? StudioTheme.raised : StudioTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(busy || workspace.readOnly)
                .accessibilityValue(catalog.id == workspace.archive.activeCatalogID ? "Selezionato" : "")
            }
            HStack(spacing: 12) {
                Button { failure = nil; showImporter = true } label: { Label("Importa da file…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(ModernButtonStyle(color: StudioTheme.accent, isPrimary: true)).disabled(busy || workspace.readOnly)
                Button { exportCatalog() } label: { Label("Esporta catalogo…", systemImage: "square.and.arrow.up") }
                    .buttonStyle(ModernButtonStyle(color: StudioTheme.accent)).disabled(busy || workspace.active == nil)
                Button { showNewCatalog = true } label: { Label("Nuovo catalogo", systemImage: "plus") }
                    .buttonStyle(ModernButtonStyle(color: StudioTheme.secondary)).disabled(busy || workspace.readOnly)
            }
        }
    }

    private var onlineBackupSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Backup automatici").font(.system(size: 15, weight: .semibold))
                Spacer()
                if workspace.onlineBackups.running || workspace.onlineBackups.loading { ProgressView().controlSize(.small) }
                Text("60 giorni").font(.system(size: 11)).foregroundColor(StudioTheme.secondary)
            }
            if let error = workspace.onlineBackups.errorMessage {
                Text(error).font(.system(size: 12)).foregroundColor(StudioTheme.red).fixedSize(horizontal: false, vertical: true)
            }
            if workspace.onlineBackups.items.isEmpty {
                Text(cloud.user == nil ? "Accedi per i backup online" : (!cloud.online ? "Offline" : "Nessuna copia"))
                    .font(.system(size: 12)).foregroundColor(StudioTheme.secondary)
            }
            ForEach(workspace.onlineBackups.items) { backup in
                HStack {
                    Image(systemName: "icloud").foregroundColor(StudioTheme.secondary)
                    Text(backup.createdAt.formatted(date: .abbreviated, time: .standard)).font(.system(size: 12))
                    Text("\(backup.projectCount) progetti").font(.system(size: 11)).foregroundColor(StudioTheme.secondary)
                    Spacer()
                    Button("Ripristina…") { restoreOnline(backup) }
                        .buttonStyle(.plain).foregroundColor(StudioTheme.accent).font(.system(size: 12, weight: .medium))
                        .disabled(busy || workspace.readOnly || !cloud.online)
                }.padding(.vertical, 8)
            }
            if workspace.onlineBackups.hasMore {
                Button("Mostra altre copie") { Task { await workspace.onlineBackups.loadMore() } }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(StudioTheme.accent)
                    .disabled(workspace.onlineBackups.loading || !cloud.online)
            }
        }
    }

    private var localBackupRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            if backups.isEmpty { Text("Nessuna copia").font(.system(size: 12)).foregroundColor(StudioTheme.secondary) }
            ForEach(backups, id: \.self) { url in
                HStack {
                    Image(systemName: "clock.arrow.circlepath").foregroundColor(StudioTheme.secondary)
                    Text(backupDate(url)).font(.system(size: 12))
                    Spacer()
                    Button("Ripristina…") { prepareImport(url, restoring: true) }
                        .buttonStyle(.plain).foregroundColor(StudioTheme.accent).font(.system(size: 12, weight: .medium))
                        .disabled(busy || workspace.readOnly)
                }
                .padding(.vertical, 8)
            }
            Button("Mostra cartella delle copie") { NSWorkspace.shared.open(dataManager.getBackupDirectory()) }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(StudioTheme.secondary)
        }
    }
    private func reloadBackups() {
        backups = dataManager.getAvailableBackups()
        Task { await workspace.onlineBackups.refresh(owner: workspace.ownerID, catalogID: workspace.archive.activeCatalogID) }
    }
    private func restoreOnline(_ backup: CloudBackupInfo) {
        guard let owner = workspace.ownerID else { return }
        let target = workspace.archive.activeCatalogID
        busy = true; failure = nil
        Task {
            do {
                let snapshot = try await workspace.onlineBackups.read(backup, owner: owner)
                guard workspace.ownerID == owner, workspace.archive.activeCatalogID == target else { throw CatalogTransferError.contextChanged }
                let transfer = CatalogTransfer(catalog: snapshot.catalog, sourceDeviceID: snapshot.sourceDeviceID, exportDate: snapshot.capturedAt)
                pendingImport = ImportRequest(transfer: transfer, filename: "Backup del \(backup.createdAt.formatted(date: .abbreviated, time: .standard))", restoring: true, owner: owner, target: target)
            } catch { failure = error.localizedDescription }
            busy = false
        }
    }
    private func backupDate(_ url: URL) -> String {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return date?.formatted(date: .abbreviated, time: .standard) ?? url.lastPathComponent
    }
    private func exportCatalog() {
        do { document = CatalogBackupDocument(data: try dataManager.catalogExportData()); failure = nil; showExporter = true }
        catch { failure = error.localizedDescription }
    }
    private func prepareImport(_ url: URL, restoring: Bool) {
        do {
            let transfer = try CatalogTransfer.read(url, deviceID: workspace.deviceID)
            pendingImport = ImportRequest(transfer: transfer, filename: url.lastPathComponent, restoring: restoring, owner: workspace.ownerID, target: workspace.archive.activeCatalogID)
            failure = nil
        } catch { failure = error.localizedDescription }
    }
    private func performBulk(_ action: BulkAction) {
        let owner = workspace.ownerID, target = workspace.archive.activeCatalogID
        busy = true; failure = nil
        Task {
            do {
                _ = try await dataManager.createRecoveryBackup()
                guard owner == workspace.ownerID, target == workspace.archive.activeCatalogID else { throw CatalogTransferError.contextChanged }
                switch action {
                case .billed: dataManager.markAllProjectsBilled()
                case .completed: dataManager.markAllProjectsCompleted()
                case .toBill: dataManager.markAllProjectsToBill()
                case .clear: dataManager.clearAllProjects()
                }
                guard !workspace.readOnly else { throw CatalogArchiveError.unableToSave }
                reloadBackups(); message = "Operazione completata."
            } catch { failure = error.localizedDescription }
            busy = false
        }
    }
}

struct CatalogImportReview: View {
    let transfer: CatalogTransfer
    let filename: String
    let restoring: Bool
    let owner: String?
    let target: UUID?
    let onComplete: (String) -> Void
    @EnvironmentObject var workspace: CatalogWorkspace
    @EnvironmentObject var dataManager: DataManager
    @Environment(\.dismiss) private var dismiss
    @State private var replace: Bool
    @State private var name: String
    @State private var working = false
    @State private var error: String?

    init(transfer: CatalogTransfer, filename: String, restoring: Bool, owner: String?, target: UUID?, onComplete: @escaping (String) -> Void) {
        self.transfer = transfer; self.filename = filename; self.restoring = restoring
        self.owner = owner; self.target = target; self.onComplete = onComplete
        _replace = State(initialValue: restoring); _name = State(initialValue: transfer.catalog.info.name)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(restoring ? "Ripristina una copia" : "Importa catalogo").font(.system(size: 22, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                Label(filename, systemImage: "doc.text").font(.system(size: 13, weight: .medium)).lineLimit(2)
                Text("\(transfer.catalog.projects.count) progetti · \(Set(transfer.catalog.projects.map(\.volumeName)).count) dischi")
                Text("\(transfer.catalog.projects.filter(\.isCompleted).count) conclusi · \(transfer.catalog.projects.filter { $0.billingStatus == .billed }.count) fatturati")
                Text("Esportato il \(transfer.exportDate.formatted(date: .abbreviated, time: .shortened))")
            }.font(.system(size: 12)).foregroundColor(StudioTheme.secondary)
            Picker("Destinazione", selection: $replace) {
                Text("Aggiungi come nuovo catalogo").tag(false)
                if target != nil { Text("Sostituisci il catalogo selezionato").tag(true) }
            }.pickerStyle(.radioGroup).disabled(working)
            if replace {
                Text("Sostituisce «\(workspace.active?.info.name ?? "")», inclusi gli stati. Crea prima una copia di sicurezza.")
                    .font(.system(size: 12)).foregroundColor(StudioTheme.amber).fixedSize(horizontal: false, vertical: true)
            } else {
                TextField("Nome del catalogo", text: $name).textFieldStyle(.roundedBorder).disabled(working)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundColor(StudioTheme.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Annulla") { dismiss() }.buttonStyle(ModernButtonStyle(color: StudioTheme.secondary)).keyboardShortcut(.cancelAction).disabled(working)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(replace ? "Sostituisci catalogo" : "Importa catalogo") { performImport() }
                    .buttonStyle(ModernButtonStyle(color: replace ? StudioTheme.amber : StudioTheme.accent, isPrimary: true))
                    .disabled(working || workspace.readOnly || (!replace && (name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 100)))
            }
        }
        .padding(28).frame(width: 540).background(StudioTheme.background).foregroundColor(StudioTheme.text)
        .interactiveDismissDisabled(working)
    }
    private func performImport() {
        working = true; error = nil
        Task {
            do {
                guard workspace.ownerID == owner, !replace || workspace.archive.activeCatalogID == target else { throw CatalogTransferError.contextChanged }
                if replace {
                    _ = try await dataManager.createRecoveryBackup()
                    guard workspace.ownerID == owner, workspace.archive.activeCatalogID == target else { throw CatalogTransferError.contextChanged }
                    try workspace.importCatalog(transfer.catalog, sourceDeviceID: transfer.sourceDeviceID)
                } else {
                    try workspace.addImportedCatalog(transfer.catalog, name: name, sourceDeviceID: transfer.sourceDeviceID)
                }
                onComplete("Catalogo importato: \(transfer.catalog.projects.count) progetti."); dismiss()
            } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}
