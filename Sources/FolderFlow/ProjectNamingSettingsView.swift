import SwiftUI

struct ProjectNamingSettingsView: View {
    @EnvironmentObject var dataManager: DataManager
    @State private var selection = ProjectNaming.defaultPattern
    @State private var customPattern = ProjectNaming.defaultPattern

    private var pattern: String { selection == "custom" ? customPattern : selection }
    private var naming: ProjectNaming { ProjectNaming(pattern: pattern) }
    private var example: String? { naming.name(title: "Campagna_Autunno", date: Date(), existingNames: []) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nomenclatura dei progetti").font(.system(size: 18, weight: .semibold))
                    Text("Lo stesso formato viene usato per creare i progetti e cercarli sui dischi.")
                        .font(.system(size: 12)).foregroundColor(StudioTheme.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Formato", selection: $selection) {
                        ForEach(ProjectNaming.presets, id: \.self) { pattern in
                            Text(pattern == ProjectNaming.defaultPattern ? "AA_MM_NN_Nome — il tuo formato" : pattern.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: ""))
                                .tag(pattern)
                        }
                        Text("Personalizzato").tag("custom")
                    }
                    .pickerStyle(.menu)
                    if selection == "custom" {
                        TextField("Es. {AAAA}-{MM}_{NN}_{Nome}", text: $customPattern)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, design: .monospaced))
                            .accessibilityLabel("Formato personalizzato delle cartelle")
                        Text("Campi: {AA} anno breve · {AAAA} anno · {MM} mese · {GG} giorno · {NN} progressivo · {Nome} titolo")
                            .font(.system(size: 12)).foregroundColor(StudioTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Anteprima").font(.system(size: 12)).foregroundColor(StudioTheme.secondary)
                    Text(example ?? "Formato non valido")
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error = naming.validationError {
                        Text(error).font(.system(size: 12)).foregroundColor(StudioTheme.red)
                    }
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                Text("Il progressivo riparte quando cambiano le parti di data presenti nel formato. I progetti già in catalogo restano disponibili e le cartelle esistenti mantengono il loro nome.")
                    .font(.system(size: 12)).foregroundColor(StudioTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Ripristina il mio formato") {
                        selection = ProjectNaming.defaultPattern
                        customPattern = ProjectNaming.defaultPattern
                        dataManager.updateProjectNamingPattern(ProjectNaming.defaultPattern)
                    }
                    .buttonStyle(ModernButtonStyle(color: StudioTheme.secondary))
                    Spacer()
                    if pattern == dataManager.projectNamingPattern {
                        Label("Formato attivo", systemImage: "checkmark.circle")
                            .font(.system(size: 12)).foregroundColor(StudioTheme.green)
                    }
                    Button("Applica formato") { dataManager.updateProjectNamingPattern(pattern) }
                        .buttonStyle(ModernButtonStyle(color: StudioTheme.accent, isPrimary: true))
                        .disabled(naming.validationError != nil || example == nil || pattern == dataManager.projectNamingPattern)
                }
            }
            .foregroundColor(StudioTheme.text)
            .padding(2)
        }
        .onAppear {
            customPattern = dataManager.projectNamingPattern
            selection = ProjectNaming.presets.contains(customPattern) ? customPattern : "custom"
        }
    }
}
