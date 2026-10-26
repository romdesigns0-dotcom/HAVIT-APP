import SwiftUI

struct HavitHomeView: View {
    let onAccount: () -> Void
    let onRestart: () -> Void
    @ObservedObject var taskBridge: HavitTaskBLEBridge
    var onConnectDevice: () -> Void = {}
    var deviceStatus: String? = nil
    var accountUID: String? = nil
    var linkedReceipt: HavitLinkedReceipt? = nil
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedTab = "Inicio"
    @State private var showingComposer = false
    @State private var showingRestartConfirmation = false
    @State private var draftTitle = ""
    @State private var draftDetail = ""
    @StateObject private var taskStore = HavitTaskStore()
    @State private var draftHasDate = false
    @State private var draftDate = Date()
    @State private var editingID: String?
    @State private var calendarDate = Date()
    @State private var showingConflicts = false
    @State private var showingTimeZone = false
    private var taskCalendar: Calendar { var value = Calendar.current; value.timeZone = TimeZone(identifier: taskStore.timeZoneID) ?? .current; return value }
    private var tasks: [HavitTask] { taskStore.tasks }
    private var visibleTasks: [HavitTask] {
        selectedTab == "Calendario" ? tasks.filter { $0.dueDate.map { taskCalendar.isDate($0, inSameDayAs: calendarDate) } ?? false } : tasks
    }

    private let tabs = [("Inicio", "house"), ("Tareas", "checkmark.square"), ("Calendario", "calendar"), ("Perfil", "person")]

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(red: 0.055, green: 0.055, blue: 0.059).ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    HStack {
                        Text(taskStore.statusText).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                        Spacer()
                        Button { Task { await taskStore.synchronize() } } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                            .disabled(taskStore.isSyncing).accessibilityLabel("Actualizar actividades")
                    }.padding(.top, 10)
                    if !taskBridge.status.isEmpty {
                        Text(taskBridge.status).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).padding(.top, 4)
                        if taskBridge.status.contains("configúralo a Wi‑Fi") {
                            Button(action: onConnectDevice) {
                                Label("Conectar HAVIT a Wi‑Fi", systemImage: "wifi")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(.bordered)
                            .padding(.top, 5)
                        }
                    }
                    Button("Zona de tu cuenta: \(taskStore.timeZoneID)") { showingTimeZone = true }
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).padding(.top, 6)
                    if !taskStore.conflicts.isEmpty {
                        Button("Revisar cambios en conflicto") { showingConflicts = true }.font(.system(size: 13)).padding(.top, 8)
                    }
                    if let deviceStatus {
                        Text(deviceStatus)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                            .padding(.top, 12)
                    }
                    Button(action: onConnectDevice) {
                        Label("Conectar dispositivo HAVIT", systemImage: "dot.radiowaves.left.and.right")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, deviceStatus == nil ? 14 : 10)
                    progressCard.padding(.top, deviceStatus == nil ? 20 : 12)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedTab == "Calendario" ? "Actividades del día" : "Próximas actividades")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                        Text(todayLabel)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                    .padding(.top, 20)

                    if selectedTab == "Calendario" {
                        DatePicker("Día", selection: $calendarDate, displayedComponents: .date)
                            .datePickerStyle(.graphical).tint(.white)
                        Text("Las actividades sin vencimiento aparecen en Tareas.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    }
                    if visibleTasks.isEmpty {
                        if !taskStore.hasLoadedLocalState {
                            Text("Cargando actividades guardadas…")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.65))
                                .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.top, 8)
                        } else {
                            emptyTasksCard.padding(.top, 8)
                        }
                    } else {
                        ForEach(visibleTasks) { task in
                            taskCard(task).padding(.top, 8)
                        }
                    }

                    Button {
                        draftTitle = ""
                        draftDetail = ""
                        editingID = nil
                        draftHasDate = selectedTab == "Calendario"
                        draftDate = selectedTab == "Calendario" ? calendarDate : Date()
                        showingComposer = true
                    } label: {
                        Text("+ Crear actividad")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color(red: 0.055, green: 0.055, blue: 0.059))
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 22)

                    Button { showingRestartConfirmation = true } label: {
                        Label("Reiniciar recorrido", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.65))
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                    }
                    .buttonStyle(.plain)

                    Color.clear.frame(height: 68)
                }
                .padding(.horizontal, 18)
                .padding(.top, 0)
            }

            floatingNavigation
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingComposer) { taskComposer }
        .alert("¿Reiniciar recorrido?", isPresented: $showingRestartConfirmation) {
            Button("Cancelar", role: .cancel) {}
            Button("Reiniciar", role: .destructive, action: onRestart)
        } message: {
            Text("Se cerrará tu sesión para volver a empezar desde la bienvenida.")
        }
        .task(id: accountUID) { await taskStore.run(accountUID: accountUID) }
        .task(id: "\(accountUID ?? ""):\(linkedReceipt?.bindingID ?? ""):\(scenePhase == .active)") {
            await taskBridge.run(receipt: linkedReceipt, active: scenePhase == .active, tasks: taskStore)
        }
        .environment(\.timeZone, TimeZone(identifier: taskStore.timeZoneID) ?? .current)
        .sheet(isPresented: $showingTimeZone) {
            NavigationStack {
                List(TimeZone.knownTimeZoneIdentifiers, id: \.self) { zone in
                    Button(zone) { Task { await taskStore.setTimeZone(zone); showingTimeZone = false } }
                }.navigationTitle("Zona de la cuenta")
                    .toolbar { Button("Cancelar") { showingTimeZone = false } }
            }.preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showingConflicts) {
            NavigationStack {
                List(taskStore.conflicts) { change in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(change.fields?.title ?? "Eliminar actividad").font(.headline)
                        Text(change.problem ?? "Revisa este cambio antes de enviarlo.").font(.caption)
                        Button("Aplicar mi cambio") { taskStore.resolve(change, useLocal: true) }
                        Button("Conservar lo del servidor", role: .destructive) { taskStore.resolve(change, useLocal: false) }
                    }
                }.navigationTitle("Revisar cambios")
                    .toolbar { Button("Listo") { showingConflicts = false } }
            }.preferredColorScheme(.dark)
        }
    }

    private var todayLabel: String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "es_MX")
        formatter.timeZone = taskCalendar.timeZone; formatter.dateFormat = "EEEE, d 'de' MMMM"
        let date = formatter.string(from: Date())
        return date.prefix(1).uppercased() + date.dropFirst()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Buen día, Rom")
                .font(.system(size: 23, weight: .bold))
                .foregroundStyle(.white)
            Text("Organiza tu día, una actividad a la vez.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.68))
        }
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
    }

    private var progressCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("TU PROGRESO")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.62))
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(tasks.filter(\.done).count)")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                    Text("/\(tasks.count)")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                }
                Text("actividades completadas")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.67))
            }

            Spacer()

            ZStack(alignment: .top) {
                Circle()
                    .trim(from: 0.01, to: 0.99)
                    .stroke(.white.opacity(0.18), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Circle()
                    .fill(Color(red: 0.66, green: 0.83, blue: 1))
                    .frame(width: 6, height: 6)
                    .offset(y: -2)
            }
            .frame(width: 56, height: 56)
            .padding(.trailing, 1)
        }
        .padding(.horizontal, 13)
        .frame(height: 102)
        .background(Color(red: 0.094, green: 0.094, blue: 0.106), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(red: 0.2, green: 0.2, blue: 0.22), lineWidth: 1))
    }

    private var emptyTasksCard: some View {
        let offline = taskStore.statusText.localizedCaseInsensitiveContains("sin conexión") ||
            taskStore.statusText.localizedCaseInsensitiveContains("sin respuesta")
        let hasCache = taskStore.hasCachedSnapshot
        return VStack(alignment: .leading, spacing: 6) {
            Text(offline
                 ? (hasCache ? "Sin conexión; se conserva el último estado" : "Sin conexión y sin copia local")
                 : "Aún no tienes actividades")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Text(offline
                 ? (hasCache
                    ? "Mostramos las actividades guardadas en este iPhone. Se actualizarán al recuperar internet."
                    : "Conecta el iPhone a internet para cargar tus actividades de HAVIT.")
                 : "Crea tu primera actividad para verla aquí.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .frame(minHeight: 76)
        .background(Color(red: 0.094, green: 0.094, blue: 0.106), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(red: 0.2, green: 0.2, blue: 0.22), lineWidth: 1))
    }

    private func taskCard(_ task: HavitTask) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(task.title == "Seminario de Diseño" ? Color(red: 0.56, green: 0.82, blue: 0.92) : Color(red: 0.78, green: 0.69, blue: 0.94))
                .frame(width: 3, height: 70)

            VStack(alignment: .leading, spacing: 5) {
                Text(task.displayTime(in: taskStore.timeZoneID))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(task.title == "Seminario de Diseño" ? Color(red: 0.66, green: 0.88, blue: 0.96) : Color(red: 0.84, green: 0.76, blue: 0.98))
                Text(task.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .strikethrough(task.done)
                Text(task.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                editingID = task.id; draftTitle = task.title; draftDetail = task.detail
                draftHasDate = task.dueDate != nil; draftDate = task.dueDate ?? Date()
                showingComposer = true
            }

            Spacer(minLength: 2)

            Button { toggle(task) } label: {
                Image(systemName: task.done ? "checkmark" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 18, height: 18)
                    .background(.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.done ? "Marcar pendiente" : "Completar actividad")
        }
        .padding(.horizontal, 1)
        .frame(maxWidth: .infinity)
        .frame(height: 96)
        .background(Color(red: 0.094, green: 0.094, blue: 0.106), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(red: 0.2, green: 0.2, blue: 0.22), lineWidth: 1))
    }

    @ViewBuilder
    private var floatingNavigation: some View {
        if #available(iOS 26.0, *) {
            glassFloatingNavigation
        } else {
            legacyFloatingNavigation
        }
    }

    @available(iOS 26.0, *)
    private var glassFloatingNavigation: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(0..<tabs.count, id: \.self) { index in
                    let title = tabs[index].0
                    let icon = tabs[index].1
                    let isSelected = selectedTab == title
                    Button {
                        selectedTab = title
                        if title == "Perfil" { onAccount() }
                    } label: {
                        tabLabel(title: title, icon: icon, selected: isSelected)
                            .background {
                                if isSelected {
                                    Capsule()
                                        .fill(.white.opacity(0.08))
                                        .glassEffect(.regular.tint(.white.opacity(0.12)).interactive(), in: Capsule())
                                        .padding(.horizontal, 1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 5).padding(.vertical, 2)
            .frame(width: 332, height: 53)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.42), radius: 18, y: 6)
        }
        .frame(maxWidth: .infinity)
    }

    private var legacyFloatingNavigation: some View {
        HStack(spacing: 2) {
            ForEach(0..<tabs.count, id: \.self) { index in
                let title = tabs[index].0
                let icon = tabs[index].1
                let isSelected = selectedTab == title
                Button {
                    selectedTab = title
                    if title == "Perfil" { onAccount() }
                } label: {
                    tabLabel(title: title, icon: icon, selected: isSelected)
                        .background(isSelected ? .white.opacity(0.12) : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 5).padding(.vertical, 2)
        .frame(width: 332, height: 53)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.42), radius: 18, y: 6)
        .frame(maxWidth: .infinity)
    }

    private func tabLabel(title: String, icon: String, selected: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: selected ? .semibold : .regular))
            Text(title)
                .font(.system(size: 9, weight: selected ? .bold : .regular))
        }
        .foregroundStyle(selected ? .white : .white.opacity(0.52))
        .frame(maxWidth: .infinity)
        .frame(height: 49)
        .contentShape(Capsule())
    }

    private var taskComposer: some View {
        TaskEntryForm(title: $draftTitle, detail: $draftDetail, hasDate: $draftHasDate, dueDate: $draftDate,
                      editing: editingID != nil, timeZoneID: taskStore.timeZoneID, onCancel: { showingComposer = false }, onSave: saveTask,
                      onDelete: {
                          if let task = tasks.first(where: { $0.id == editingID }) { taskStore.delete(task) }
                          showingComposer = false
                      })
        .preferredColorScheme(.dark)
        .presentationDetents([.height(510), .large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(.clear)
        .presentationCornerRadius(34)
    }

    private func saveTask() {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let detail = draftDetail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard taskStore.save(id: editingID, title: title, detail: detail, due: draftHasDate ? draftDate : nil) else { return }
        draftTitle = ""
        draftDetail = ""
        showingComposer = false
    }

    private func toggle(_ task: HavitTask) {
        taskStore.toggle(task)
    }
}

private struct TaskEntryForm: View {
    @Binding var title: String
    @Binding var detail: String
    @Binding var hasDate: Bool
    @Binding var dueDate: Date
    let editing: Bool
    let timeZoneID: String
    let onCancel: () -> Void
    let onSave: () -> Void
    let onDelete: () -> Void
    @State private var confirmDeletion = false

    var body: some View {
        VStack(spacing: 0) {
            HavitSheetHeader(
                title: editing ? "Editar actividad" : "Nueva actividad",
                actionIcon: "arrow.up",
                actionLabel: "Guardar actividad",
                actionEnabled: !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.utf8.count <= 160 && detail.utf8.count <= 2048,
                actionProminent: true,
                onClose: onCancel,
                onAction: onSave
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("¿Qué necesitas hacer?").font(.system(size: 25, weight: .bold)).foregroundStyle(.white)
                        Text("Anota una actividad y organiza el siguiente paso.").font(.system(size: 14)).foregroundStyle(.white.opacity(0.64))
                    }

                    VStack(spacing: 0) {
                        TextField("Nombre de la actividad", text: $title)
                            .font(.system(size: 16)).textInputAutocapitalization(.sentences)
                            .padding(.horizontal, 16).frame(minHeight: 58)
                        Rectangle().fill(.white.opacity(0.1)).frame(height: 1).padding(.leading, 16)
                        TextField("Añade detalles (opcional)", text: $detail, axis: .vertical)
                            .font(.system(size: 15)).lineLimit(3...5).textInputAutocapitalization(.sentences)
                            .padding(.horizontal, 16).padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .havitInsetCard()

                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Fecha de entrega", isOn: $hasDate)
                        if hasDate {
                            DatePicker("Entrega", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
                            Text("Zona horaria: \(timeZoneID)").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(16).havitInsetCard()
                    if title.utf8.count > 160 || detail.utf8.count > 2048 {
                        Text("Acorta el título o los detalles para guardar la actividad.").font(.caption).foregroundStyle(.orange)
                    }
                    if editing { Button("Eliminar actividad", role: .destructive) { confirmDeletion = true } }
                }
                .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
        }
        .havitSheetSurface()
        .confirmationDialog("¿Eliminar esta actividad de tu cuenta y tus dispositivos?", isPresented: $confirmDeletion) {
            Button("Eliminar actividad", role: .destructive, action: onDelete)
        }
    }
}
