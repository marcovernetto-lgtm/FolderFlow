import SwiftUI
import GoogleSignInSwift

struct CatalogAppView: View {
    @EnvironmentObject var workspace: CatalogWorkspace
    @EnvironmentObject var cloud: CloudService
    @State private var showAccount = false
    @State private var showNewCatalog = false

    var body: some View {
        VStack(spacing: 0) {
            if workspace.active == nil {
                HStack { Spacer(); AccountToolbarButton { showAccount = true } }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                Divider().overlay(StudioTheme.line)
                VStack(spacing: 18) {
                    Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 36)).foregroundColor(StudioTheme.accent)
                    Text("I tuoi cataloghi").font(.system(size: 24, weight: .semibold))
                    Text("Crea un catalogo per i lavori di questo Mac, oppure importa quelli già presenti qui.")
                        .font(.system(size: 13)).foregroundColor(StudioTheme.secondary)
                    HStack(spacing: 14) {
                        Button("Importa un catalogo…") { showAccount = true }
                            .buttonStyle(ModernButtonStyle(color: StudioTheme.secondary))
                        Button("Nuovo catalogo") { showNewCatalog = true }
                            .buttonStyle(ModernButtonStyle(color: StudioTheme.accent, isPrimary: true))
                    }
                    if let error = workspace.errorMessage { Text(error).foregroundColor(StudioTheme.red).frame(maxWidth: 550) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentView(onShowSettings: { showAccount = true }).id(workspace.archive.activeCatalogID)
            }
            if let error = workspace.errorMessage {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12))
                    Spacer()
                    Button("Account") { showAccount = true }.buttonStyle(.plain)
                }
                .foregroundColor(StudioTheme.amber).padding(12).background(StudioTheme.surface)
            }
        }
        .foregroundColor(StudioTheme.text).background(StudioTheme.background)
        .sheet(isPresented: $showAccount) { SettingsView(initialTab: .account) }
        .sheet(isPresented: $showNewCatalog) { NewCatalogSheet() }
    }

}

struct AccountToolbarButton: View {
    @EnvironmentObject var workspace: CatalogWorkspace
    @EnvironmentObject var cloud: CloudService
    let action: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(syncColor).frame(width: 8, height: 8).help(workspace.status).accessibilityLabel(workspace.status)
            Button(action: action) {
                HStack(spacing: 8) {
                    Label(cloud.user?.displayName ?? "Accedi", systemImage: cloud.user == nil ? "person.crop.circle" : "person.crop.circle.fill")
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 14, weight: .medium))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundColor(StudioTheme.accent).help("Profilo e impostazioni")
            .accessibilityLabel("Profilo e impostazioni, \(cloud.user?.displayName ?? "Accedi")")
        }
    }
    private var syncColor: Color {
        if workspace.readOnly || workspace.errorMessage != nil || cloud.errorMessage != nil || !workspace.archive.conflicts.isEmpty { return StudioTheme.red }
        if cloud.user == nil { return StudioTheme.secondary }
        if !cloud.online || !workspace.archive.pending.isEmpty { return StudioTheme.amber }
        return workspace.syncing ? StudioTheme.accent : StudioTheme.green
    }
}

struct NewCatalogSheet: View {
    @EnvironmentObject var workspace: CatalogWorkspace
    @EnvironmentObject var cloud: CloudService
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Nuovo catalogo").font(.system(size: 22, weight: .semibold))
            TextField("Nome del catalogo", text: $name).textFieldStyle(.roundedBorder).onSubmit(create)
            HStack {
                Button("Annulla") { dismiss() }
                Spacer()
                Button("Crea catalogo", action: create)
                    .buttonStyle(ModernButtonStyle(color: StudioTheme.accent, isPrimary: true))
                    .disabled(!valid || workspace.readOnly)
            }
        }
        .padding(28).frame(width: 460).background(StudioTheme.background).foregroundColor(StudioTheme.text)
    }
    private var valid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 100 }
    private func create() {
        guard valid, !workspace.readOnly else { return }
        workspace.createCatalog(name: name)
        dismiss()
    }
}

struct CloudAccountView: View {
    @EnvironmentObject var cloud: CloudService
    @EnvironmentObject var workspace: CatalogWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var createAccount = false
    @FocusState private var focusedField: LoginField?
    private enum LoginField: Hashable { case email, password }
    private var signedOut: Bool { cloud.user == nil }
    private var authenticationUnavailable: Bool { !cloud.configured || cloud.authenticating || !cloud.online }
    private var emailSignInUnavailable: Bool { authenticationUnavailable || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty }
    private var sheetHeight: CGFloat {
        let preferred: CGFloat = signedOut ? ((cloud.errorMessage != nil || !cloud.configured) ? 640 : 590) : (workspace.archive.conflicts.isEmpty ? 560 : 720)
        return min(preferred, (NSScreen.main?.visibleFrame.height ?? 900) - 100)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(signedOut ? (createAccount ? "Crea il tuo account" : "Accedi a FolderFlow") : "Il tuo account")
                    .font(.system(size: 21, weight: .semibold))
                Spacer(minLength: 16)
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                }
                .foregroundColor(StudioTheme.secondary).buttonStyle(.plain).accessibilityLabel("Chiudi")
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
            Divider().overlay(StudioTheme.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let user = cloud.user { accountContent(user) }
                    else { loginContent }
                    if let error = cloud.errorMessage {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.system(size: 12)).foregroundColor(StudioTheme.amber)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    if let information = cloud.information {
                        Label(information, systemImage: "checkmark.circle")
                            .font(.system(size: 12)).foregroundColor(StudioTheme.green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: signedOut ? 364 : .infinity)
                .padding(.horizontal, 32).padding(.vertical, 26)
                .frame(maxWidth: .infinity)
            }
            Divider().overlay(StudioTheme.line)
            VStack(spacing: 12) {
                Text("Solo cataloghi e metadati. Foto e video restano sugli HD.")
                    .font(.system(size: 11)).foregroundColor(StudioTheme.secondary)
                    .multilineTextAlignment(.center)
                Button(signedOut ? "Continua su questo Mac" : "Chiudi") { password = ""; dismiss() }
                    .buttonStyle(ModernButtonStyle(color: StudioTheme.secondary))
            }
            .padding(.horizontal, 24).padding(.vertical, 18)
        }
        .frame(width: signedOut ? 500 : 650, height: sheetHeight)
        .background(StudioTheme.background).foregroundColor(StudioTheme.text)
        .tint(StudioTheme.accent)
        .onDisappear { password = "" }
        .onChange(of: cloud.user?.id) { if $0 != nil { dismiss() } }
    }

    private var loginContent: some View {
        VStack(spacing: 24) {
            Text("Ritrova i tuoi cataloghi sul fisso e sul portatile. Ogni account ha uno spazio privato; puoi continuare a lavorare anche offline.")
                .font(.system(size: 13)).foregroundColor(StudioTheme.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if !cloud.configured {
                Label("Il cloud non è ancora attivo per questa copia. I cataloghi locali sono disponibili e restano sul Mac.", systemImage: "icloud.slash")
                    .font(.system(size: 12)).foregroundColor(StudioTheme.amber)
            }
            GoogleSignInButton(scheme: .light, style: .wide, state: authenticationUnavailable ? .disabled : .normal) {
                focusedField = nil
                Task { await cloud.signInWithGoogle() }
            }
            .frame(width: 240, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .disabled(authenticationUnavailable)
            HStack(spacing: 14) {
                Rectangle().fill(StudioTheme.line).frame(height: 1)
                Text("oppure con email").font(.system(size: 11)).foregroundColor(StudioTheme.secondary).fixedSize()
                Rectangle().fill(StudioTheme.line).frame(height: 1)
            }
            VStack(spacing: 12) {
                field("envelope", focused: focusedField == .email) {
                    TextField("Email", text: $email)
                        .textContentType(.username).focused($focusedField, equals: .email)
                        .accessibilityLabel("Email").onSubmit { focusedField = .password }
                }
                field("lock", focused: focusedField == .password) {
                    SecureField("Password", text: $password)
                        .textContentType(.password).focused($focusedField, equals: .password)
                        .accessibilityLabel("Password").onSubmit { authenticate() }
                }
                Button { authenticate() } label: {
                    HStack(spacing: 10) {
                        if cloud.authenticating { ProgressView().controlSize(.small) }
                        Text(createAccount ? "Crea account" : "Accedi")
                    }
                    .frame(maxWidth: .infinity).frame(height: 24)
                }
                .buttonStyle(ModernButtonStyle(color: StudioTheme.accent, isPrimary: !emailSignInUnavailable))
                .disabled(emailSignInUnavailable)
                HStack {
                    Button(createAccount ? "Ho già un account" : "Crea un account") { createAccount.toggle() }
                    Spacer(minLength: 12)
                    Button("Password dimenticata?") { Task { await cloud.resetPassword(email: email) } }
                        .disabled(!cloud.configured || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !cloud.online)
                }
                .font(.system(size: 11)).buttonStyle(.plain).foregroundColor(StudioTheme.accent)
                .padding(.top, 5)
            }
        }
    }

    private func field<Content: View>(_ symbol: String, focused: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundColor(StudioTheme.secondary).frame(width: 16)
            content().font(.system(size: 13)).textFieldStyle(.plain)
        }
        .padding(.horizontal, 14).frame(height: 44)
        .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused ? StudioTheme.accent : StudioTheme.line, lineWidth: 1))
    }

    private func accountContent(_ user: CloudUser) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Accesso effettuato", systemImage: "checkmark.circle").foregroundColor(StudioTheme.green)
            Text(user.displayName).font(.system(size: 18, weight: .semibold))
            Text("Puoi gestire i tuoi cataloghi e le copie di sicurezza nella scheda Cataloghi delle impostazioni.")
                .font(.system(size: 13)).foregroundColor(StudioTheme.secondary)
        }
    }

    private func authenticate() {
        guard !authenticationUnavailable, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else { return }
        Task { await cloud.signIn(email: email, password: password, create: createAccount); password = "" }
    }
}

struct CatalogConflictView: View {
    let conflict: CatalogConflict
    @EnvironmentObject var workspace: CatalogWorkspace
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                version("Questo Mac", workspace.archive.pending[conflict.id]?.payload)
                version("Cloud", conflict.remote.payload)
            }
            HStack {
                Button("Mantieni questo Mac") { workspace.resolveConflict(conflict.id, keepLocal: true) }
                Button("Usa versione cloud") { workspace.resolveConflict(conflict.id, keepLocal: false) }
            }
            .buttonStyle(ModernButtonStyle(color: StudioTheme.accent))
        }
        .padding(18).background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
    private func version(_ title: String, _ data: Data?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(StudioTheme.accent)
            if let data, let project = try? CatalogArchive.decodeValue(CatalogProject.self, data) {
                Text(project.name).font(.system(size: 13, weight: .semibold))
                Text("\(project.isCompleted ? "Concluso" : "In corso") · \(project.billingStatus.rawValue)").font(.system(size: 11))
                Text("HD \(project.volumeName) · \(project.folderSize, specifier: "%.2f") GB").font(.system(size: 11))
                if let deadline = project.deadline { Text("Scadenza: \(deadline.formatted(date: .abbreviated, time: .omitted))").font(.system(size: 11)) }
                ScrollView { Text(project.comments.isEmpty ? "Nessuna nota" : project.comments).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 130)
            } else if let data, let info = try? CatalogArchive.decodeValue(CatalogInfo.self, data) {
                Text(info.name).font(.system(size: 13, weight: .semibold))
                Text(info.namingPattern).font(.system(size: 11))
                ForEach(info.colors.keys.sorted(), id: \.self) { disk in
                    HStack { Circle().fill(info.colors[disk]!.toColor()).frame(width: 8, height: 8); Text(disk).font(.system(size: 11)) }
                }
            } else if let data, let preferences = try? CatalogArchive.decodeValue(SharedAppPreferences.self, data) {
                Text("Preferenze dell’app").font(.system(size: 13, weight: .semibold))
                Text("Avvio all’accesso: \(preferences.launchAtLogin ? "Sì" : "No")").font(.system(size: 12))
                Text("Solo barra dei menu: \(preferences.hideDockIcon ? "Sì" : "No")").font(.system(size: 12))
            } else { Text("Elemento eliminato").font(.system(size: 12)) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// A compact, embedded year wheel: no menus or detached windows.
struct InlineYearWheel: NSViewRepresentable {
    @Binding var selection: String
    var options: [String]

    func makeNSView(context: Context) -> YearWheelControl { YearWheelControl() }
    func updateNSView(_ view: YearWheelControl, context: Context) {
        view.options = options
        view.selection = selection
        view.onChange = { selection = $0 }
        view.needsDisplay = true
    }
}

final class YearWheelControl: NSView {
    var options: [String] = []
    var selection = "Tutti"
    var onChange: ((String) -> Void)?
    private var scrollRemainder: CGFloat = 0
    private var index: Int { options.firstIndex(of: selection) ?? 0 }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.incrementor)
        setAccessibilityLabel("Anno")
        toolTip = "Scorri per cambiare anno. Usa le frecce su e giù quando il controllo è selezionato."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func accessibilityValue() -> Any? { selection }
    override func accessibilityPerformIncrement() -> Bool { move(1); return true }
    override func accessibilityPerformDecrement() -> Bool { move(-1); return true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.10, green: 0.15, blue: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.94),
            .paragraphStyle: paragraph
        ]
        (selection as NSString).draw(in: NSRect(x: 10, y: (bounds.height - 18) / 2, width: bounds.width - 36, height: 18), withAttributes: attributes)
        NSColor(calibratedRed: 0.66, green: 0.76, blue: 0.78, alpha: 1).setStroke()
        for direction: CGFloat in [-1, 1] {
            let x = bounds.width - 15
            let y = bounds.midY + direction * 5
            let chevron = NSBezierPath()
            chevron.move(to: NSPoint(x: x - 3, y: y - direction * 1.5))
            chevron.line(to: NSPoint(x: x, y: y + direction * 1.5))
            chevron.line(to: NSPoint(x: x + 3, y: y - direction * 1.5))
            chevron.lineWidth = 1.5
            chevron.lineJoinStyle = .round
            chevron.stroke()
        }
        if window?.firstResponder === self {
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
            path.lineWidth = 2; path.stroke()
        }
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let y = convert(event.locationInWindow, from: nil).y
        move(y < bounds.midY ? -1 : 1)
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: move(-1)
        case 125: move(1)
        case 115: choose(0)
        case 119: choose(options.count - 1)
        default: super.keyDown(with: event)
        }
    }
    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began { scrollRemainder = 0 }
        scrollRemainder += event.scrollingDeltaY
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 16 : 1
        let steps = Int(scrollRemainder / threshold)
        guard steps != 0 else { return }
        scrollRemainder -= CGFloat(steps) * threshold
        move(-steps)
    }
    private func move(_ amount: Int) { choose(index + amount) }
    private func choose(_ target: Int) {
        guard !options.isEmpty else { return }
        let next = options[min(max(target, 0), options.count - 1)]
        guard next != selection else { return }
        selection = next; needsDisplay = true; onChange?(next)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
}
