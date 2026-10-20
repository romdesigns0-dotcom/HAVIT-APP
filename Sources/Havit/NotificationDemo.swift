import Foundation
import UserNotifications

@MainActor
final class NotificationDemo: ObservableObject {
    @Published var message = "Consulta el permiso y actívalo antes de enviar la prueba."
    @Published var permission: UNAuthorizationStatus = .notDetermined
    @Published var isScheduling = false
    func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        permission = settings.authorizationStatus
        switch permission {
        case .notDetermined: message = "Todavía no se ha solicitado permiso. Pulsa Activar notificaciones."
        case .authorized, .provisional, .ephemeral: message = "Notificaciones permitidas. Ya puedes enviar la prueba."
        case .denied: message = "El permiso está denegado. Pulsa Abrir Ajustes y actívalo manualmente."
        @unknown default: message = "Estado de notificaciones desconocido."
        }
    }
    func requestPermission() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await refresh()
        } catch { message = "No se pudo pedir permiso: \(error.localizedDescription)" }
    }
    func schedule() async {
        await refresh()
        guard permission == .authorized || permission == .provisional || permission == .ephemeral else {
            message = permission == .denied ? "Permiso denegado. Pulsa Abrir Ajustes para habilitarlo." : "Primero pulsa Activar notificaciones."
            return
        }
        do {
            isScheduling = true
            let content = UNMutableNotificationContent(); content.title = "HAVIT"
            content.body = "¡Tu notificación local de prueba funciona!"
            let toneID = UserDefaults.standard.string(forKey: "study.notificationSound") ?? "system"
            content.sound = SessionAlertTone.notificationSound(for: toneID)
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "demo-local-\(UUID().uuidString)", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)))
            message = "Programada. En 5 segundos debe aparecer; si la app está abierta, verás el banner."
        } catch { message = "No se pudo programar: \(error.localizedDescription)" }
        isScheduling = false
    }
}
