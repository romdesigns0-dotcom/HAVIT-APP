import ActivityKit
import Foundation
import Shared
import UserNotifications

@MainActor
final class LiveActivityDemo: ObservableObject {
    @Published var message = "Prepara tus tareas e inicia una sesión Estudio."
    @Published var focusMessage = "Configura Atajos para activar el modo Estudio al iniciar."
    @Published private(set) var isRunning = false
    @Published private(set) var isBusy = false
    @Published private(set) var pendingTasks = 3
    @Published private(set) var startedAt: Date?
    @Published private(set) var timerEnd: Date?

    private static let notificationID = "study-session-finished"
    private let defaults = UserDefaults.standard
    private var activityID: String?
    private var completionTask: Task<Void, Never>?
    private var sessionUsesFocus = false

    init() {
        if defaults.object(forKey: "study.pendingTasks") != nil {
            pendingTasks = max(0, defaults.integer(forKey: "study.pendingTasks"))
        }
        if let activity = activeActivities.first {
            adopt(activity)
        } else if let start = defaults.object(forKey: "study.startedAt") as? Date,
                  let end = defaults.object(forKey: "study.timerEnd") as? Date {
            startedAt = start
            timerEnd = end
            sessionUsesFocus = defaults.bool(forKey: "study.sessionUsesFocus")
            isRunning = true
            scheduleCompletion()
        }
    }

    func start(minutes: Int = 25, useFocus: Bool = false) async -> Bool {
        guard !isBusy else { return false }
        await refresh()
        guard !isRunning else {
            message = "Ya hay una sesión en marcha. Finalízala antes de iniciar otra."
            return false
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            message = "Activa Live Activities en Ajustes > Apps > HAVIT para iniciar la sesión."
            return false
        }
        isBusy = true
        defer { isBusy = false }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }

        let duration = min(max(minutes, 1), 120) * 60
        let now = Date()
        let end = now.addingTimeInterval(TimeInterval(duration))
        let state = FocusActivityAttributes.ContentState(timerEnd: end, pendingTasks: pendingTasks)
        do {
            // Clear any ended session left by an older installation.
            for old in Activity<FocusActivityAttributes>.activities {
                await old.end(nil, dismissalPolicy: .immediate)
            }
            let activity = try Activity.request(
                attributes: FocusActivityAttributes(startedAt: now, sessionLength: duration),
                content: ActivityContent(state: state, staleDate: end),
                pushType: nil
            )
            activityID = activity.id
            startedAt = now
            timerEnd = end
            sessionUsesFocus = useFocus
            defaults.set(useFocus, forKey: "study.sessionUsesFocus")
            defaults.set(now, forKey: "study.startedAt")
            defaults.set(end, forKey: "study.timerEnd")
            isRunning = true
            scheduleCompletion()
            message = "Sesión Estudio iniciada. El contador sigue en la Dynamic Island al salir de la app."

            center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
            center.removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
            let updatedSettings = await center.notificationSettings()
            if [.authorized, .provisional, .ephemeral].contains(updatedSettings.authorizationStatus) {
                let content = UNMutableNotificationContent()
                content.title = "Estudio terminado"
                content.body = "Completaste \(duration / 60) minutos. Es momento de descansar."
                let toneID = defaults.string(forKey: "study.notificationSound") ?? "system"
                content.sound = SessionAlertTone.notificationSound(for: toneID)
                content.userInfo = ["studySession": true]
                let trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: max(1, end.timeIntervalSinceNow), repeats: false
                )
                do {
                    try await center.add(UNNotificationRequest(
                        identifier: Self.notificationID, content: content, trigger: trigger
                    ))
                } catch {
                    message += " No se pudo programar el aviso de finalización."
                }
            } else {
                message += " Activa las notificaciones en Ajustes para recibir el aviso al terminar."
            }
            return true
        } catch {
            message = "No se pudo iniciar: \(error.localizedDescription)"
            return false
        }
    }

    func changeTasks(by amount: Int) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        pendingTasks = min(999, max(0, pendingTasks + amount))
        defaults.set(pendingTasks, forKey: "study.pendingTasks")
        if let activity = currentActivity {
            var state = activity.content.state
            state.pendingTasks = pendingTasks
            await activity.update(ActivityContent(state: state, staleDate: state.timerEnd))
        }
    }

    @discardableResult
    func end() async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        let shouldStopFocus = sessionUsesFocus
        completionTask?.cancel()
        for activity in Activity<FocusActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
        clearSession()
        message = "Sesión finalizada. El aviso pendiente se canceló."
        return shouldStopFocus
    }

    func refresh() async {
        guard !isBusy else { return }
        if let activity = activeActivities.first {
            adopt(activity)
            await completeIfExpired()
        } else if isRunning {
            // Dismissing the Live Activity must not cancel the session or its alert.
            await completeIfExpired()
        }
    }

    func handleFocusCallback(_ url: URL) {
        guard url.scheme == "havit", url.host == "focus" else { return }
        switch url.path {
        case "/enabled":
            focusMessage = "Atajo de Estudio ejecutado. Su fecha de apagado coincide con el temporizador."
        case "/disabled":
            focusMessage = "Atajo para finalizar Estudio ejecutado."
        case "/cancelled":
            focusMessage = isRunning
                ? "Atajo cancelado. El temporizador sigue funcionando."
                : "Atajo cancelado. Puedes desactivar Estudio desde el Centro de control."
        default:
            focusMessage = "No se pudo ejecutar el atajo. Revisa los nombres y los pasos en Configurar enfoque."
        }
    }

    func shortcutCouldNotOpen() {
        focusMessage = "No se pudo abrir Atajos. Instala la app Atajos y revisa la configuración."
    }

    private var activeActivities: [Activity<FocusActivityAttributes>] {
        Activity<FocusActivityAttributes>.activities
            .filter { $0.activityState == .active || $0.activityState == .stale }
            .sorted { $0.attributes.startedAt > $1.attributes.startedAt }
    }

    private var currentActivity: Activity<FocusActivityAttributes>? {
        activeActivities.first(where: { $0.id == activityID })
    }

    private func adopt(_ activity: Activity<FocusActivityAttributes>) {
        activityID = activity.id
        startedAt = activity.attributes.startedAt
        timerEnd = activity.content.state.timerEnd
        pendingTasks = activity.content.state.pendingTasks
        sessionUsesFocus = defaults.bool(forKey: "study.sessionUsesFocus")
        defaults.set(activity.attributes.startedAt, forKey: "study.startedAt")
        defaults.set(activity.content.state.timerEnd, forKey: "study.timerEnd")
        isRunning = true
        scheduleCompletion()
    }

    private func scheduleCompletion() {
        completionTask?.cancel()
        guard let timerEnd else { return }
        let remaining = max(0, timerEnd.timeIntervalSinceNow)
        completionTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self?.completeIfExpired()
        }
    }

    private func completeIfExpired() async {
        guard let timerEnd, timerEnd <= Date() else { return }
        for activity in activeActivities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        clearSession()
        message = "Sesión completada. Descansa unos minutos antes de continuar."
    }

    private func clearSession() {
        completionTask?.cancel()
        completionTask = nil
        activityID = nil
        isRunning = false
        startedAt = nil
        timerEnd = nil
        sessionUsesFocus = false
        defaults.removeObject(forKey: "study.sessionUsesFocus")
        defaults.removeObject(forKey: "study.startedAt")
        defaults.removeObject(forKey: "study.timerEnd")
    }
}
