import SwiftUI
import UIKit

struct FocusSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage("study.useFocusShortcuts") private var useFocus = false

    var body: some View {
        NavigationStack {
            Form {
                Section("1 · Crea el modo Estudio") {
                    Text("En Ajustes > Enfoque (o Modos de concentración), pulsa + y crea un modo personalizado llamado Estudio.")
                    Text("Permite las notificaciones de HAVIT en ese modo para escuchar el aviso de finalización.")
                        .foregroundStyle(.secondary)
                }
                Section("2 · Atajo para iniciar") {
                    nameRow(StudyShortcutLinks.startName)
                    Text("En Atajos, crea un atajo con ese nombre exacto y añade estas dos acciones:")
                    Text("1. Obtener fechas de la entrada: usa la variable Entrada del atajo.")
                    Text("2. Definir enfoque: activa Estudio hasta la fecha obtenida en el paso anterior.")
                    Text("La app enviará la hora exacta en que termina tu sesión. No uses Hasta desactivarlo.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("3 · Atajo para finalizar antes") {
                    nameRow(StudyShortcutLinks.stopName)
                    Text("Crea otro atajo con una acción: Definir enfoque → desactivar Estudio.")
                }
                Section {
                    Button("Abrir Atajos") {
                        if let url = URL(string: "shortcuts://") { openURL(url) }
                    }
                    Toggle("Ya creé ambos atajos · usar Estudio", isOn: $useFocus)
                    Text("Al iniciar, se abrirá Atajos y después volverás a la app. Al vencer el tiempo, iOS desactivará Estudio aunque la app esté en segundo plano.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Configurar enfoque")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
        }
    }

    private func nameRow(_ name: String) -> some View {
        HStack {
            Text(name).font(.headline).textSelection(.enabled)
            Spacer()
            Button {
                UIPasteboard.general.string = name
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .accessibilityLabel("Copiar nombre del atajo")
        }
    }
}
