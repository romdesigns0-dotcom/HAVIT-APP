import SwiftUI
import UIKit
import FirebaseAuth

private enum HavitEntryRoute: Hashable { case signIn, connectDevice }

struct ContentView: View {
    @StateObject private var authSession = HavitAuthSession()
    @AppStorage("havit.onboardingCompleted") private var onboardingCompleted = false
    @State private var onboardingPath = NavigationPath()
    @State private var showingWelcome = false
    @State private var showingAccount = false
    @State private var emailLinkConfirmation = ""
    @StateObject private var notifications = NotificationDemo()
    @StateObject private var bluetooth = BluetoothController()
    @StateObject private var liveActivity = LiveActivityDemo()
    @AppStorage("study.useFocusShortcuts") private var useFocus = false
    @State private var minutes = 25
    @State private var projectTitle = "Diseño CAD"
    @State private var projectSubtitle = "Joyería 1"
    @State private var showingFocusSetup = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if !showingWelcome && (authSession.isAuthenticated || onboardingCompleted) {
                dashboard
            } else {
                NavigationStack(path: $onboardingPath) {
                    WelcomeView(
                        onStart: { onboardingPath.append(HavitEntryRoute.connectDevice) },
                        onLogin: { onboardingPath.append(HavitEntryRoute.signIn) }
                    )
                    .navigationDestination(for: HavitEntryRoute.self) { route in
                        switch route {
                        case .signIn: LoginView(session: authSession, onContinueWithoutAccount: finishOnboarding)
                        case .connectDevice:
                            PairDeviceView(bluetooth: bluetooth) { onboardingPath.append(HavitEntryRoute.signIn) }
                        }
                    }
                }
            }
        }
        .onOpenURL { url in
            if !authSession.handleEmailSignInURL(url) && !FirebaseAppDelegate.handleAuthURL(url) { liveActivity.handleFocusCallback(url) }
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { _ = authSession.handleEmailSignInURL(url) }
        }
        .alert("Confirma tu correo", isPresented: Binding(
            get: { authSession.pendingEmailSignInLink != nil && authSession.savedEmailForLink.isEmpty && !authSession.isBusy },
            set: { _ in }
        )) {
            TextField("Correo electrónico", text: $emailLinkConfirmation)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
            Button("Continuar") { authSession.completeEmailSignIn(email: emailLinkConfirmation) }
            Button("Cancelar", role: .cancel) { authSession.clearEmailSignInLink() }
        } message: {
            Text("Escribe el correo al que enviamos este enlace de acceso.")
        }
        .preferredColorScheme(.dark)
        .onChange(of: authSession.isAuthenticated) { _, authenticated in
            if authenticated { finishOnboarding(); showingAccount = false }
        }
    }

    private var dashboard: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    accountCard
                    studyCard
                    notificationsCard
                    bluetoothCard
                }
                .padding()
            }
            .navigationTitle("HAVIT")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cuenta", systemImage: "person.crop.circle") { showingAccount = true }
                }
            }
            .sheet(isPresented: $showingAccount) {
                NavigationStack {
                    if authSession.isAuthenticated {
                        VStack(spacing: 24) {
                            Label("Sesión iniciada", systemImage: "person.crop.circle.badge.checkmark")
                                .font(.title2.bold())
                            Text("Tu cuenta está conectada a HAVIT.")
                            Button("Cerrar sesión") {
                                if authSession.signOut() {
                                    onboardingCompleted = false
                                    showingAccount = false
                                    returnToWelcome()
                                }
                            }
                            .buttonStyle(.bordered)
                            if let message = authSession.statusMessage { Text(message).font(.footnote) }
                        }
                        .padding()
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { showingAccount = false } } }
                    } else {
                        LoginView(session: authSession, onContinueWithoutAccount: { showingAccount = false })
                            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { showingAccount = false } } }
                    }
                }
                .preferredColorScheme(.dark)
            }
            .sheet(isPresented: $showingFocusSetup) { FocusSetupView() }
            .task {
                await notifications.refresh()
                await liveActivity.refresh()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task {
                        await liveActivity.refresh()
                        await notifications.refresh()
                    }
                }
            }

        }
    }

    private func finishOnboarding() {
        onboardingCompleted = true
        showingWelcome = false
        onboardingPath = NavigationPath()
    }

    private func returnToWelcome() {
        onboardingPath = NavigationPath()
        showingWelcome = true
    }

    private var accountCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label(authSession.isAuthenticated ? "Cuenta conectada" : "Estás usando HAVIT sin cuenta", systemImage: "person.crop.circle")
                    .font(.headline)
                if !authSession.isAuthenticated {
                    Button("Iniciar sesión o crear cuenta") { showingAccount = true }
                        .buttonStyle(.borderedProminent)
                }
                Button(action: returnToWelcome) {
                    Label("Volver al inicio", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                Text("Vuelve a la bienvenida para repetir la configuración. Tus datos se conservan.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var studyCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Label("Sesión Estudio", systemImage: "book.closed.fill")
                    .font(.title2.bold())
                Text("Un tiempo para concentrarte y avanzar con tus tareas.")
                    .font(.subheadline).foregroundStyle(.secondary)

                if !liveActivity.isRunning {
                    TextField("Proyecto", text: $projectTitle)
                        .textFieldStyle(.roundedBorder)
                    TextField("Detalle", text: $projectSubtitle)
                        .textFieldStyle(.roundedBorder)
                }

                sessionPreview

                if !liveActivity.isRunning {
                    Picker("Duración", selection: $minutes) {
                        Text("1 min · prueba").tag(1)
                        Text("5 minutos").tag(5)
                        Text("25 minutos").tag(25)
                        Text("50 minutos").tag(50)
                    }
                    .pickerStyle(.menu)
                    .disabled(liveActivity.isBusy)
                }

                HStack(spacing: 12) {
                    Button {
                        Task { await beginSession() }
                    } label: {
                        Label(liveActivity.isRunning ? "En marcha" : "Iniciar \(minutes) min", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(liveActivity.isRunning || liveActivity.isBusy)

                    Button("Finalizar") {
                        Task {
                            let stopFocus = await liveActivity.end()
                            if stopFocus { runShortcut(StudyShortcutLinks.stop) }
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!liveActivity.isRunning || liveActivity.isBusy)
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await liveActivity.changeTasks(by: -1) }
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel("Completar una tarea")
                    .buttonStyle(.bordered)
                    .disabled(liveActivity.pendingTasks == 0 || liveActivity.isBusy)

                    Text("\(liveActivity.pendingTasks) pendientes")
                        .font(.headline.monospacedDigit())
                        .frame(maxWidth: .infinity)

                    Button {
                        Task { await liveActivity.changeTasks(by: 1) }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Añadir tarea")
                    .buttonStyle(.bordered)
                    .disabled(liveActivity.pendingTasks >= 999 || liveActivity.isBusy)
                }

                Divider()
                Label(useFocus ? "Estudio con Atajos" : "Concentración opcional", systemImage: "moon.fill")
                    .font(.subheadline.bold())
                Text(useFocus
                     ? "Al iniciar, ejecutaremos el atajo para activar Estudio hasta la hora de fin."
                     : "Configura el modo Estudio una vez para silenciar distracciones durante la sesión.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Configurar enfoque") { showingFocusSetup = true }
                    .buttonStyle(.bordered)
                if useFocus {
                    Text(liveActivity.focusMessage).font(.caption).foregroundStyle(.secondary)
                }
                Text(liveActivity.message).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sessionPreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("ESTUDIO", systemImage: "timer")
                    .font(.caption.bold()).foregroundStyle(.orange)
                Spacer()
                if let start = liveActivity.startedAt, let end = liveActivity.timerEnd {
                    Text(timerInterval: start...end, countsDown: true)
                        .font(.system(.title, design: .rounded, weight: .bold).monospacedDigit())
                        .frame(width: 100, alignment: .trailing)
                } else {
                    Text("\(minutes):00")
                        .font(.system(.title, design: .rounded, weight: .bold).monospacedDigit())
                }
            }
            HStack {
                Label("\(liveActivity.pendingTasks) tareas por completar", systemImage: "checklist")
                    .font(.subheadline)
                Spacer(minLength: 0)
            }
            if let end = liveActivity.timerEnd {
                Text("Termina a las \(end.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
            } else {
                Text("Vista previa de tu sesión")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .background(.black, in: RoundedRectangle(cornerRadius: 24))
    }

    private var notificationsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Notificaciones", systemImage: "bell.badge.fill").font(.headline)
                Text("La sesión programa un aviso local al terminar.")
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    Button("Permitir avisos") { Task { await notifications.requestPermission() } }
                        .buttonStyle(.borderedProminent)
                    Button("Prueba 5 s") { Task { await notifications.schedule() } }
                        .buttonStyle(.bordered)
                        .disabled(![.authorized, .provisional, .ephemeral].contains(notifications.permission))
                }
                if notifications.permission == .denied {
                    Button("Abrir Ajustes") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
                Text(notifications.message).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var bluetoothCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Bluetooth LE", systemImage: "antenna.radiowaves.left.and.right").font(.headline)
                Text(bluetooth.message).font(.subheadline).foregroundStyle(.secondary)
                Button(bluetooth.scanning ? "Buscando…" : "Buscar dispositivos") {
                    bluetooth.scanning ? bluetooth.stopScan() : bluetooth.scan()
                }
                .buttonStyle(.borderedProminent)
                ForEach(bluetooth.devices) { device in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(device.name).font(.subheadline.bold())
                            Text("Señal: \(device.rssi) dBm · \(device.state == .connected ? "conectado" : "disponible")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(device.state == .connected ? "Desconectar" : "Conectar") {
                            device.state == .connected ? bluetooth.disconnect(device.id) : bluetooth.connect(device.id)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Text("Busca accesorios Bluetooth LE. Sus funciones dependen del protocolo de cada accesorio.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @MainActor
    private func beginSession() async {
        let focusEnabled = useFocus
        let started = await liveActivity.start(minutes: minutes, useFocus: focusEnabled)
        if started, focusEnabled, let end = liveActivity.timerEnd {
            runShortcut(StudyShortcutLinks.start(until: end))
        }
    }

    private func runShortcut(_ url: URL) {
        openURL(url) { accepted in
            if !accepted { liveActivity.shortcutCouldNotOpen() }
        }
    }
}
