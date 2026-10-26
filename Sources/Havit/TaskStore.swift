import Foundation
import FirebaseAuth
import Combine

struct HavitTask: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var detail: String
    var dueAt: String?
    var status: String
    var taskVersion: Int
    var createdAt: String
    var updatedAt: String
    var done: Bool { status == "completed" }
    var dueDate: Date? { dueAt.flatMap(Self.date) }
    func displayTime(in zone: String) -> String {
        guard let dueDate else { return "Sin fecha de entrega" }
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "es_MX"); formatter.timeZone = TimeZone(identifier: zone)
        return formatter.string(from: dueDate)
    }
    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    var fields: TaskFields { TaskFields(title: title, detail: detail, dueAt: dueAt, status: status) }
}

struct TaskFields: Codable, Equatable {
    var title: String
    var detail: String
    var dueAt: String?
    var status: String
    // JSON null is part of the API contract; synthesized Optional encoding omits it.
    enum CodingKeys: String, CodingKey { case title, detail, dueAt, status }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title); try c.encode(detail, forKey: .detail)
        try c.encode(status, forKey: .status)
        if let dueAt { try c.encode(dueAt, forKey: .dueAt) } else { try c.encodeNil(forKey: .dueAt) }
    }
}

struct HavitTaskChange: Codable, Identifiable, Equatable {
    var id: String
    var taskID: String
    var baseVersion: Int
    var kind: String
    var fields: TaskFields?
    var problem: String?
}

@MainActor
final class HavitTaskStore: ObservableObject {
    @Published private(set) var tasks: [HavitTask] = []
    @Published private(set) var pendingCount = 0
    @Published private(set) var conflicts: [HavitTaskChange] = []
    @Published private(set) var statusText = "Cargando actividades…"
    @Published private(set) var isSyncing = false
    @Published private(set) var hasLoadedLocalState = false
    @Published private(set) var hasCachedSnapshot = false
    @Published private(set) var timeZoneID = "America/Mexico_City"
    private struct Disk: Codable {
        var tasks: [HavitTask] = []
        var revision: Int = 0
        var hasCachedSnapshot: Bool? = nil
        var pending: [HavitTaskChange] = []
        var conflicts: [HavitTaskChange] = []
        var lastSync: Date?
        var timeZone = "America/Mexico_City"
    }
    private struct Snapshot: Decodable { let uid: String; let revision: Int; let tasks: [HavitTask]; let taskLimit: Int; let timeZone: String }
    private struct Result: Decodable { let id: String; let task: HavitTask? }
    private struct APIError: Error { let status: Int; let code: String }
    private var disk = Disk()
    private var uid: String?
    private var generation = UUID()
    private let base = "https://us-central1-havit-c8c1d.cloudfunctions.net/havitDeviceApiV1"
    private let session = URLSession(configuration: .ephemeral)
    private var storageKey: String { "havit.tasks.cloud.v1.\(uid ?? "local")" }

    static func clearCachedData(uid: String) {
        UserDefaults.standard.removeObject(forKey: "havit.tasks.cloud.v1.\(uid)")
        UserDefaults.standard.removeObject(forKey: "havit.home.tasks.account.\(uid)")
    }

    func run(accountUID: String?) async {
        generation = UUID(); let attempt = generation
        uid = accountUID; isSyncing = false
        disk = (UserDefaults.standard.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(Disk.self, from: $0) }) ?? Disk()
        hasCachedSnapshot = disk.hasCachedSnapshot ?? (disk.revision > 0)
        migrateLegacyForCurrentAccount()
        hasLoadedLocalState = true
        publish()
        if uid == nil { statusText = "Guardado en este iPhone. Inicia sesión para sincronizar."; return }
        while !Task.isCancelled, generation == attempt {
            await synchronize()
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
        }
    }

    @discardableResult
    func save(id: String? = nil, title: String, detail: String, due: Date?) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 160, detail.utf8.count <= 2048 else {
            statusText = "El título admite 160 bytes y los detalles 2048. Acorta el texto para guardarlo."; return false
        }
        if id == nil, tasks.count >= 64 { statusText = "Puedes guardar hasta 64 actividades. Elimina alguna para crear otra."; return false }
        guard disk.pending.count < 64 else { statusText = "Conecta a Internet para enviar los cambios pendientes."; return false }
        let old = id.flatMap { taskID in tasks.first { $0.id == taskID } }
        let fields = TaskFields(title: title, detail: detail, dueAt: due.map(HavitTask.iso), status: old?.status ?? "pending")
        guard let encoded = try? JSONEncoder().encode(fields), encoded.count <= 2400 else {
            statusText = "Acorta los detalles para guardarlos también en HAVIT."; return false
        }
        enqueue(HavitTaskChange(id: UUID().uuidString.lowercased(), taskID: id ?? UUID().uuidString.lowercased(), baseVersion: old?.taskVersion ?? 0, kind: old == nil ? "create" : "update", fields: fields))
        return true
    }

    func toggle(_ task: HavitTask) {
        var fields = task.fields; fields.status = task.done ? "pending" : "completed"
        enqueue(HavitTaskChange(id: UUID().uuidString.lowercased(), taskID: task.id, baseVersion: task.taskVersion, kind: "update", fields: fields))
    }
    func delete(_ task: HavitTask) {
        enqueue(HavitTaskChange(id: UUID().uuidString.lowercased(), taskID: task.id, baseVersion: task.taskVersion, kind: "delete"))
    }
    func resolve(_ change: HavitTaskChange, useLocal: Bool) {
        let last = disk.conflicts.last { $0.taskID == change.taskID } ?? change
        disk.conflicts.removeAll { $0.taskID == change.taskID }
        if useLocal {
            let current = disk.tasks.first { $0.id == change.taskID }
            var replacement = last; replacement.id = UUID().uuidString.lowercased(); replacement.problem = nil
            replacement.baseVersion = current?.taskVersion ?? 0
            if current != nil, replacement.kind == "create" { replacement.kind = "update" }
            if current == nil {
                if last.kind == "delete" { persist(); return }
                replacement.kind = "create"; replacement.taskID = UUID().uuidString.lowercased()
            }
            disk.pending.append(replacement)
        }
        persist(); Task { await synchronize() }
    }

    private func enqueue(_ change: HavitTaskChange) {
        guard disk.pending.count < 64 else { statusText = "Hay demasiados cambios pendientes. Conecta a Internet."; return }
        if uid == nil { apply(change, to: &disk.tasks) } else { disk.pending.append(change) }
        persist(); Task { await synchronize() }
    }

    private func apply(_ change: HavitTaskChange, to list: inout [HavitTask]) {
        let old = list.first { $0.id == change.taskID }
        list.removeAll { $0.id == change.taskID }
        guard change.kind != "delete", let f = change.fields else { return }
        let now = HavitTask.iso(Date())
        list.append(HavitTask(id: change.taskID, title: f.title, detail: f.detail, dueAt: f.dueAt, status: f.status,
                              taskVersion: change.baseVersion + 1, createdAt: old?.createdAt ?? now, updatedAt: now))
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(disk) { UserDefaults.standard.set(data, forKey: storageKey) }
        publish()
    }
    private func publish() {
        timeZoneID = disk.timeZone
        var visible = disk.tasks
        for change in disk.pending { apply(change, to: &visible) }
        tasks = visible.sorted {
            if $0.done != $1.done { return !$0.done }
            if $0.dueAt != $1.dueAt { return ($0.dueAt ?? "9999") < ($1.dueAt ?? "9999") }
            return $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
        }
        pendingCount = disk.pending.count; conflicts = disk.conflicts
    }

    func synchronize() async {
        guard let expectedUID = uid, Auth.auth().currentUser?.uid == expectedUID, !isSyncing else { return }
        let attempt = generation; isSyncing = true
        defer { if generation == attempt { isSyncing = false } }
        do {
            try await fetch(uid: expectedUID, attempt: attempt)
            while let change = disk.pending.first, generation == attempt, !Task.isCancelled {
                var body: [String: Any] = ["operationId": change.id, "baseTaskVersion": change.baseVersion]
                if let f = change.fields { body["task"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f)) }
                let path = change.kind == "create" ? "/v1/tasks" : "/v1/tasks/\(change.taskID)"
                let method = change.kind == "create" ? "POST" : change.kind == "delete" ? "DELETE" : "PATCH"
                if change.kind == "create" { body["taskId"] = change.taskID }
                do {
                    let data = try await request(path, method: method, body: body, uid: expectedUID, attempt: attempt)
                    let result = try JSONDecoder().decode(Result.self, from: data)
                    guard generation == attempt else { return }
                    guard result.id == change.taskID else { throw APIError(status: 503, code: "INVALID_RESPONSE") }
                    disk.tasks.removeAll { $0.id == change.taskID }
                    if let task = result.task { disk.tasks.append(task) }
                    disk.pending.removeAll { $0.id == change.id }; persist()
                } catch let error as APIError where [400, 403, 409].contains(error.status) {
                    guard generation == attempt else { return }
                    let affected = disk.pending.filter { $0.taskID == change.taskID }.map { value in
                        var value = value; value.problem = error.code == "TASK_VERSION_CONFLICT" ? "La actividad cambió en otro dispositivo." : error.code == "TASK_LIMIT_REACHED" ? "Se alcanzó el límite de 64 actividades." : "El servidor rechazó este cambio (\(error.code))."; return value
                    }
                    disk.conflicts.append(contentsOf: affected); disk.pending.removeAll { $0.taskID == change.taskID }; persist()
                }
            }
            try await fetch(uid: expectedUID, attempt: attempt)
            guard generation == attempt else { return }
            disk.lastSync = Date(); persist()
            statusText = disk.conflicts.isEmpty ? "Actividades actualizadas · \(Date().formatted(date: .omitted, time: .shortened))" : "Hay \(disk.conflicts.count) cambios que necesitan revisión."
        } catch let error as APIError where error.status == 401 {
            guard generation == attempt else { return }
            statusText = "Tu sesión necesita renovarse. Inicia sesión de nuevo; tus cambios están guardados."
        } catch {
            guard generation == attempt else { return }
            statusText = "Sin conexión con el servidor. \(disk.pending.count) cambios guardados para reintentar."
        }
    }
    private func fetch(uid: String, attempt: UUID) async throws {
        let data = try await request("/v1/tasks", method: "GET", body: nil, uid: uid, attempt: attempt)
        let value = try JSONDecoder().decode(Snapshot.self, from: data)
        guard generation == attempt, value.uid == uid, value.tasks.count <= value.taskLimit else { throw CancellationError() }
        disk.tasks = value.tasks; disk.revision = value.revision; disk.timeZone = value.timeZone
        disk.hasCachedSnapshot = true; hasCachedSnapshot = true; persist()
    }
    func setTimeZone(_ zone: String) async {
        guard let uid, TimeZone(identifier: zone) != nil else { return }
        let attempt = generation
        do {
            _ = try await request("/v1/user/preferences", method: "PUT", body: ["timeZone": zone], uid: uid, attempt: attempt)
            try await fetch(uid: uid, attempt: attempt)
        } catch { if generation == attempt { statusText = "No se pudo cambiar la zona horaria. Inténtalo con conexión." } }
    }
    private func request(_ path: String, method: String, body: [String: Any]?, uid: String, attempt: UUID) async throws -> Data {
        for force in [false, true] {
            guard generation == attempt, let user = Auth.auth().currentUser, user.uid == uid else { throw CancellationError() }
            let token: String = try await withCheckedThrowingContinuation { continuation in
                user.getIDTokenForcingRefresh(force) { token, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let token { continuation.resume(returning: token) }
                    else { continuation.resume(throwing: CancellationError()) }
                }
            }
            guard generation == attempt, Auth.auth().currentUser?.uid == uid else { throw CancellationError() }
            var request = URLRequest(url: URL(string: base + path)!)
            request.httpMethod = method; request.timeoutInterval = 20
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let (data, response) = try await session.data(for: request)
            guard generation == attempt, Auth.auth().currentUser?.uid == uid else { throw CancellationError() }
            guard let http = response as? HTTPURLResponse else { throw APIError(status: 503, code: "INVALID_RESPONSE") }
            if http.statusCode == 401, !force { continue }
            if (200..<300).contains(http.statusCode) { return data }
            let error = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw APIError(status: http.statusCode, code: (error?["error"] as? [String: Any])?["code"] as? String ?? "UNAVAILABLE")
        }
        throw APIError(status: 401, code: "UNAUTHENTICATED")
    }
    private func migrateLegacyForCurrentAccount() {
        guard disk.tasks.isEmpty, disk.pending.isEmpty else { return }
        let key = "havit.home.tasks.account.\(uid ?? "local")"
        struct Legacy: Decodable { let id: UUID; let title: String; let detail: String; let done: Bool }
        guard let text = UserDefaults.standard.string(forKey: key), let data = text.data(using: .utf8),
              let old = try? JSONDecoder().decode([Legacy].self, from: data) else { return }
        for t in old {
            let f = TaskFields(title: t.title, detail: t.detail == "Sin detalles" ? "" : t.detail, dueAt: nil, status: t.done ? "completed" : "pending")
            let change = HavitTaskChange(id: UUID().uuidString.lowercased(), taskID: t.id.uuidString.lowercased(), baseVersion: 0, kind: "create", fields: f)
            if uid == nil { apply(change, to: &disk.tasks) } else { disk.pending.append(change) }
        }
        persist(); UserDefaults.standard.removeObject(forKey: key)
    }
}
