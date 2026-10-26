import SwiftUI
import UIKit
import FirebaseAuth

private enum HavitEntryRoute: Hashable { case signIn, connectDevice, deviceFound, wifiSetup, wifiConnecting }

struct ContentView: View {
    @StateObject private var authSession = HavitAuthSession()
    @AppStorage("havit.onboardingCompleted") private var onboardingCompleted = false
    @State private var onboardingPath = NavigationPath()
    @State private var showingWelcome = false
    @State private var connectAfterSignIn = false
    @State private var checkingAccountDevices = false
    @State private var checkedAccountUID: String?
    @State private var showingAccount = false
    @State private var showingUnlinkConfirmation = false
    @State private var showingResetConfirmation = false
    @State private var emailLinkConfirmation = ""
    @State private var selectedDeviceID: UUID?
    @State private var selectedDeviceName = ""
    @State private var waitingForBluetoothConnection = false
    @StateObject private var notifications = NotificationDemo()
    @StateObject private var bluetooth = BluetoothController()
    @StateObject private var provisioning = WiFiProvisioningController()
    @StateObject private var deviceLink = HavitDeviceLinkCoordinator()
    @StateObject private var taskBridge = HavitTaskBLEBridge()
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
                        onStart: { beginAccountFirstSetup() },
                        onLogin: { beginAccountFirstSetup() }
                    )
                    .navigationDestination(for: HavitEntryRoute.self) { route in
                        switch route {
                        case .signIn: LoginView(session: authSession, onContinueWithoutAccount: continueWithoutAccount)
                        case .connectDevice:
                            PairDeviceView(bluetooth: bluetooth, onSelectDevice: { device in
                                selectedDeviceID = device.id
                                selectedDeviceName = device.name
                                onboardingPath.append(HavitEntryRoute.deviceFound)
                            }, onContinue: {
                                onboardingPath.append(HavitEntryRoute.signIn)
                            })
                        case .deviceFound:
                            FoundDeviceView(
                                deviceName: selectedDeviceName,
                                isConnecting: provisioning.isConnecting,
                                errorMessage: provisioning.errorMessage,
                                onConnect: { code in
                                    guard let selectedDeviceID else { return }
                                    bluetooth.stopScan()
                                    waitingForBluetoothConnection = true
                                    provisioning.connect(name: selectedDeviceName, selectedPeripheralID: selectedDeviceID, code: code)
                                },
                                onUseAnother: {
                                    provisioning.cancel()
                                    waitingForBluetoothConnection = false
                                    selectedDeviceID = nil
                                    selectedDeviceName = ""
                                    if onboardingPath.count > 0 { onboardingPath.removeLast() }
                                }
                            )
                        case .wifiSetup:
                            WiFiSetupView(
                                provisioning: provisioning,
                                onStartConnection: { ssid, password in
                                    provisioning.provision(ssid: ssid, password: password)
                                    onboardingPath.append(HavitEntryRoute.wifiConnecting)
                                },
                                onReconnect: { returnToDeviceConnection() },
                                onContinueWithoutWiFi: {
                                    provisioning.cancel()
                                    onboardingPath.append(HavitEntryRoute.signIn)
                                }
                            )
                        case .wifiConnecting:
                            WiFiConnectingView(
                                provisioning: provisioning,
                                onRetry: { returnToDeviceConnection() },
                                onContinue: { continueAfterWiFiSetup() }
                            )
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
            guard authenticated else {
                checkedAccountUID = nil
                deviceLink.refreshStoredState()
                return
            }
            Task { await routeAuthenticatedAccount() }
        }
        .onChange(of: provisioning.claimProofSessionID) { _, sessionID in
            guard sessionID != nil else { return }
            deviceLink.refreshAfterBLEProofSaved()
        }
        .task {
            deviceLink.refreshStoredState()
            if authSession.isAuthenticated { await routeAuthenticatedAccount() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            deviceLink.refreshStoredState()
            if authSession.isAuthenticated { Task { await routeAuthenticatedAccount() } }
        }
        .onChange(of: provisioning.sessionReady) { _, ready in
            guard ready, waitingForBluetoothConnection else { return }
            waitingForBluetoothConnection = false
            onboardingPath.append(HavitEntryRoute.wifiSetup)
        }
    }

    private var dashboard: some View {
        HavitHomeView(
            onAccount: { showingAccount = true },
            onRestart: restartOnboarding,
            taskBridge: taskBridge,
            onConnectDevice: connectDeviceFromHome,
            deviceStatus: deviceLink.homeStatus(for: Auth.auth().currentUser?.uid),
            accountUID: Auth.auth().currentUser?.uid,
            linkedReceipt: deviceLink.linkedReceipts.first(where: { $0.ownerUID == Auth.auth().currentUser?.uid })
        )
            .sheet(isPresented: $showingAccount) {
                NavigationStack {
                    if authSession.isAuthenticated {
                        VStack(spacing: 24) {
                            Label("Sesión iniciada", systemImage: "person.crop.circle.badge.checkmark").font(.title2.bold())
                            Text(deviceLink.linkStatus(for: Auth.auth().currentUser?.uid))
                            if let details = deviceLink.linkReceiptDetails(for: Auth.auth().currentUser?.uid) {
                                Text(details)
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                                Button(role: .destructive) {
                                    showingUnlinkConfirmation = true
                                } label: {
                                    if deviceLink.isUnlinking {
                                        ProgressView("Desvinculando…")
                                    } else {
                                        Text("Desvincular HAVIT")
                                    }
                                }
                                .disabled(deviceLink.isUnlinking)
                            }
                            if let message = deviceLink.unlinkMessage {
                                Text(message).font(.footnote).foregroundStyle(.secondary)
                            }
                            if deviceLink.hasPendingProof {
                                Button("Reintentar vinculación") { deviceLink.resumePendingClaim() }.buttonStyle(.borderedProminent)
                            }
                            if Auth.auth().currentUser != nil {
                                Button(role: .destructive) {
                                    showingResetConfirmation = true
                                } label: {
                                    if deviceLink.isUnlinking {
                                        ProgressView("Restableciendo…")
                                    } else {
                                        Label("Restablecer datos para pruebas", systemImage: "trash")
                                    }
                                }
                                .disabled(deviceLink.isUnlinking)
                                .confirmationDialog("¿Restablecer esta cuenta para pruebas?", isPresented: $showingResetConfirmation, titleVisibility: .visible) {
                                    Button("Restablecer HAVIT y borrar datos", role: .destructive) {
                                        guard let uid = Auth.auth().currentUser?.uid else { return }
                                        Task { await deviceLink.resetAccountForTesting(for: uid) }
                                    }
                                    Button("Cancelar", role: .cancel) {}
                                } message: {
                                    Text("HAVIT debe estar encendido. Si tiene Wi‑Fi, recibirá el reinicio directamente; si no, la app lo enviará por Bluetooth. La placa borrará la red guardada, el vínculo y su caché; Firebase purgará las actividades y operaciones de esta cuenta. Se conserva la identidad de fábrica para configurarlo otra vez.")
                                }
                            }
                            Button("Cerrar sesión") {
                                if authSession.signOut() { onboardingCompleted = false; showingAccount = false; returnToWelcome() }
                            }.buttonStyle(.bordered)
                            if let message = authSession.statusMessage { Text(message).font(.footnote) }
                        }
                        .padding()
                        .confirmationDialog("¿Desvincular HAVIT de esta cuenta?", isPresented: $showingUnlinkConfirmation, titleVisibility: .visible) {
                            Button("Desvincular", role: .destructive) {
                                guard let uid = Auth.auth().currentUser?.uid else { return }
                                Task { await deviceLink.unlinkCurrentDevice(for: uid) }
                            }
                            Button("Cancelar", role: .cancel) {}
                        } message: {
                            Text("La desvinculación se guarda en la cuenta aunque la placa esté desconectada. Cerrar sesión o restablecer Wi‑Fi no desvincula el dispositivo. Para usar otra cuenta, HAVIT deberá conectarse a internet y completar una nueva prueba Bluetooth.")
                        }
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { showingAccount = false } } }
                    } else {
                        LoginView(session: authSession, onContinueWithoutAccount: { showingAccount = false })
                            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { showingAccount = false } } }
                    }
                }.preferredColorScheme(.dark)
            }
    }

    private func restartOnboarding() {
        if authSession.isAuthenticated && !authSession.signOut() { return }
        onboardingCompleted = false
        showingAccount = false
        returnToWelcome()
    }

    private func continueAfterWiFiSetup() {
        if authSession.isAuthenticated {
            deviceLink.resumePendingClaim()
            finishOnboarding()
        } else {
            provisioning.cancel()
            onboardingPath.append(HavitEntryRoute.signIn)
        }
    }

    private func beginAccountFirstSetup() {
        if authSession.isAuthenticated {
            Task { await routeAuthenticatedAccount(forceRefresh: true) }
            return
        }
        connectAfterSignIn = true
        showingWelcome = true
        onboardingPath.append(HavitEntryRoute.signIn)
    }

    @MainActor
    private func routeAuthenticatedAccount(forceRefresh: Bool = false) async {
        guard let uid = Auth.auth().currentUser?.uid, !checkingAccountDevices else { return }
        if checkedAccountUID == uid && !forceRefresh { return }
        checkingAccountDevices = true
        defer { checkingAccountDevices = false }

        if deviceLink.hasPendingProof {
            deviceLink.resumePendingClaim()
            checkedAccountUID = uid
            connectAfterSignIn = false
            finishOnboarding()
            return
        }

        let hasDevice = await deviceLink.refreshAccountDevices(for: uid)
        guard Auth.auth().currentUser?.uid == uid else { return }
        checkedAccountUID = uid
        showingAccount = false
        connectAfterSignIn = false
        let accountHasDevice = hasDevice ?? deviceLink.hasLinkedDevice(for: uid)
        if accountHasDevice {
            finishOnboarding()
        } else {
            showingWelcome = true
            onboardingPath = NavigationPath()
            onboardingPath.append(HavitEntryRoute.connectDevice)
        }
    }

    private func connectDeviceFromHome() {
        if authSession.isAuthenticated {
            showingWelcome = true
            onboardingPath = NavigationPath()
            onboardingPath.append(HavitEntryRoute.connectDevice)
        } else {
            beginAccountFirstSetup()
        }
    }

    private func continueWithoutAccount() {
        connectAfterSignIn = false
        finishOnboarding()
    }

    private func finishOnboarding() {
        onboardingCompleted = true
        showingWelcome = false
        provisioning.cancel()
        waitingForBluetoothConnection = false
        onboardingPath = NavigationPath()
    }

    private func returnToWelcome() {
        provisioning.cancel()
        bluetooth.stopScan()
        waitingForBluetoothConnection = false
        onboardingPath = NavigationPath()
        showingWelcome = true
    }

    private func returnToDeviceConnection() {
        provisioning.cancel()
        waitingForBluetoothConnection = false
        onboardingPath = NavigationPath()
        onboardingPath.append(HavitEntryRoute.connectDevice)
        onboardingPath.append(HavitEntryRoute.deviceFound)
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
