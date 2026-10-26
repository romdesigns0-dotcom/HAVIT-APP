import CryptoKit
import FirebaseAuth
import Foundation
import Security

struct HavitDeviceIdentity: Codable, Equatable {
    let protocolVersion: Int
    let deviceID: String
    let name: String
    let identityProvisioned: Bool

    init(json: [String: Any]) throws {
        guard let protocolVersion = json["protocol"] as? Int,
              let name = json["name"] as? String,
              let provisioned = json["identity_provisioned"] as? Bool,
              protocolVersion == 1,
              !name.isEmpty, name.utf8.count <= 15 else {
            throw HavitClaimError.invalidDeviceInfo
        }
        let deviceID = json["device_id"] as? String ?? ""
        if provisioned {
            guard deviceID.utf8.count <= 23,
                  deviceID.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{2,22}$"#, options: .regularExpression) != nil else {
                throw HavitClaimError.invalidDeviceInfo
            }
        }
        self.protocolVersion = protocolVersion
        self.deviceID = deviceID
        self.name = name
        self.identityProvisioned = provisioned
    }
}

struct HavitClaimProof: Codable, Equatable, Identifiable {
    let protocolVersion: Int
    let deviceID: String
    let claimSessionID: String
    let claimSecret: String
    let expiresAt: Date
    var id: String { "\(deviceID):\(claimSessionID)" }
}

struct HavitLinkedReceipt: Codable, Equatable, Identifiable {
    let deviceID: String
    let bindingID: String
    let ownerUID: String
    let linkedAt: Date
    var id: String { "\(ownerUID):\(deviceID)" }
}

struct HavitFactoryResetProof: Codable, Equatable, Identifiable {
    let deviceID: String
    let bindingID: String
    let ownerUID: String
    let requestID: String
    let sealedProof: Data
    var id: String { "\(ownerUID):\(deviceID):\(requestID)" }
}

enum HavitClaimError: LocalizedError {
    case invalidDeviceInfo
    case deviceNotEnrolled
    case selectedDeviceMismatch
    case invalidClaimResponse
    case claimRecoveryUnavailable
    case deviceAlreadyLinked
    case devicePersistenceFailed
    case expiredProof
    case keychain(OSStatus)
    case invalidSecret
    case invalidAcknowledgement

    var errorDescription: String? {
        switch self {
        case .invalidDeviceInfo: return "HAVIT no devolvió una identidad válida. No se enviaron datos de Wi‑Fi."
        case .deviceNotEnrolled: return "Este HAVIT necesita preparación de operador antes de poder vincularse."
        case .selectedDeviceMismatch: return "La identidad de HAVIT no coincide con el dispositivo Bluetooth elegido. Vuelve a buscarlo y selecciona el correcto."
        case .invalidClaimResponse: return "HAVIT devolvió una respuesta de vinculación incompleta. No se enviaron datos de Wi‑Fi."
        case .claimRecoveryUnavailable: return "Actualiza el software de HAVIT para recuperar la vinculación y vuelve a conectarlo. No se enviaron datos de Wi‑Fi."
        case .deviceAlreadyLinked: return "HAVIT ya está vinculado. Si quieres usar otra cuenta, desvincúlalo primero desde la cuenta propietaria."
        case .devicePersistenceFailed: return "HAVIT no pudo guardar la prueba de vinculación. Reinicia el dispositivo y vuelve a intentarlo. No se enviaron datos de Wi‑Fi."
        case .expiredProof: return "La prueba de vinculación venció. Vuelve a abrir la configuración Bluetooth de HAVIT para generar una nueva."
        case .keychain: return "No se pudo guardar la prueba de vinculación de forma segura. No se enviaron datos de Wi‑Fi."
        case .invalidSecret: return "HAVIT envió una prueba de vinculación inválida. No se enviaron datos de Wi‑Fi."
        case .invalidAcknowledgement: return "HAVIT no confirmó que guardó la prueba. No se enviaron datos de Wi‑Fi."
        }
    }
}

enum HavitClaimProofVault {
    private static let proofService = "com.havit.device-claim.proof.v1"
    private static let receiptService = "com.havit.device-claim.receipt.v1"
    private static let factoryResetService = "com.havit.device-claim.factory-reset.v1"
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func saveAndVerify(_ proof: HavitClaimProof) throws {
        let data = try encoder.encode(proof)
        let query = baseQuery(service: proofService, account: proof.id)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var add = query
            attributes.forEach { add[$0.key] = $0.value }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw HavitClaimError.keychain(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw HavitClaimError.keychain(updateStatus)
        }
        guard try readProof(account: proof.id) == proof else { throw HavitClaimError.keychain(errSecDecode) }
    }

    static func proofs() throws -> [HavitClaimProof] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: proofService,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw HavitClaimError.keychain(status) }
        let values = result as? [Data] ?? (result as? Data).map { [$0] } ?? []
        return try values.map { try decoder.decode(HavitClaimProof.self, from: $0) }
    }

    static func saveReceipt(_ receipt: HavitLinkedReceipt) throws {
        let data = try encoder.encode(receipt)
        let query = baseQuery(service: receiptService, account: receipt.id)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var add = query
            attributes.forEach { add[$0.key] = $0.value }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw HavitClaimError.keychain(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw HavitClaimError.keychain(updateStatus)
        }
    }

    static func receipts() throws -> [HavitLinkedReceipt] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: receiptService,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw HavitClaimError.keychain(status) }
        let values = result as? [Data] ?? (result as? Data).map { [$0] } ?? []
        return try values.map { try decoder.decode(HavitLinkedReceipt.self, from: $0) }
    }

    static func saveAndVerify(_ resetProof: HavitFactoryResetProof) throws {
        let data = try encoder.encode(resetProof)
        let query = baseQuery(service: factoryResetService, account: resetProof.id)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var add = query
            attributes.forEach { add[$0.key] = $0.value }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw HavitClaimError.keychain(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw HavitClaimError.keychain(updateStatus)
        }
        guard try factoryResetProof(id: resetProof.id) == resetProof else {
            throw HavitClaimError.keychain(errSecDecode)
        }
    }

    static func factoryResetProofs() throws -> [HavitFactoryResetProof] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: factoryResetService,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw HavitClaimError.keychain(status) }
        let values = result as? [Data] ?? (result as? Data).map { [$0] } ?? []
        return try values.map { try decoder.decode(HavitFactoryResetProof.self, from: $0) }
    }

    static func removeFactoryResetProofs(deviceID: String, ownerUID: String) throws {
        for proof in try factoryResetProofs() where proof.deviceID == deviceID && proof.ownerUID == ownerUID {
            let status = SecItemDelete(baseQuery(service: factoryResetService, account: proof.id) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw HavitClaimError.keychain(status) }
        }
    }

    static func removeProofs(deviceID: String) throws {
        for proof in try proofs() where proof.deviceID == deviceID {
            let status = SecItemDelete(baseQuery(service: proofService, account: proof.id) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw HavitClaimError.keychain(status) }
        }
    }

    static func removeReceipts(deviceID: String, ownerUID: String) throws {
        for receipt in try receipts() where receipt.deviceID == deviceID && receipt.ownerUID == ownerUID {
            let status = SecItemDelete(baseQuery(service: receiptService, account: receipt.id) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw HavitClaimError.keychain(status) }
        }
    }

    static func removeReceipts(ownerUID: String) throws {
        for receipt in try receipts() where receipt.ownerUID == ownerUID {
            let status = SecItemDelete(baseQuery(service: receiptService, account: receipt.id) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw HavitClaimError.keychain(status) }
        }
    }

    private static func readProof(account: String) throws -> HavitClaimProof? {
        var query = baseQuery(service: proofService, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw HavitClaimError.keychain(status) }
        return try decoder.decode(HavitClaimProof.self, from: data)
    }

    private static func factoryResetProof(id: String) throws -> HavitFactoryResetProof? {
        var query = baseQuery(service: factoryResetService, account: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw HavitClaimError.keychain(status) }
        return try decoder.decode(HavitFactoryResetProof.self, from: data)
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }
}

@MainActor
final class HavitDeviceLinkCoordinator: ObservableObject {
    enum State: Equatable {
        case none
        case waitingForAccount
        case linking
        case waitingForDevice
        case expired
        case linked(deviceID: String, bindingID: String, ownerUID: String)
        case linkedToAnotherAccount(deviceID: String)
        case needsNewBLEWindow
        case failed(String)
    }

    @Published private(set) var state: State = .none
    @Published private(set) var linkedReceipts: [HavitLinkedReceipt] = []
    @Published private(set) var hasPendingProof = false
    @Published private(set) var isUnlinking = false
    @Published var unlinkMessage: String?
    private var linkTask: Task<Void, Never>?
    private var isResettingForTests = false
    private let apiBaseURL = URL(string: "https://us-central1-havit-c8c1d.cloudfunctions.net/havitDeviceApiV1")!
    private let session = URLSession(configuration: .ephemeral)

    init() { refreshStoredState() }

    func refreshStoredState() {
        do {
            linkedReceipts = try HavitClaimProofVault.receipts()
            let proofs = try HavitClaimProofVault.proofs()
            hasPendingProof = !proofs.isEmpty
            if !proofs.isEmpty { state = .waitingForAccount }
            else if case .linked = state {} else { state = .none }
        } catch {
            state = .failed("No se pudo leer el estado seguro de vinculación.")
        }
    }

    func hasLinkedDevice(for uid: String) -> Bool {
        linkedReceipts.contains(where: { $0.ownerUID == uid })
    }

    func homeStatus(for uid: String?) -> String? {
        if let uid, linkedReceipts.contains(where: { $0.ownerUID == uid }) { return linkStatus(for: uid) }
        return hasPendingProof ? linkStatus(for: uid) : nil
    }

    func refreshAccountDevices(for uid: String) async -> Bool? {
        guard Auth.auth().currentUser?.uid == uid else { return nil }
        do {
            var (data, response) = try await getOwnedDevices(idToken: firebaseIDToken(forceRefresh: false))
            guard var http = response as? HTTPURLResponse else { throw HavitClaimError.invalidClaimResponse }
            if http.statusCode == 401 {
                (data, response) = try await getOwnedDevices(idToken: firebaseIDToken(forceRefresh: true))
                guard let refreshed = response as? HTTPURLResponse else { throw HavitClaimError.invalidClaimResponse }
                http = refreshed
            }
            guard (200..<300).contains(http.statusCode),
                  let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let values = body["devices"] as? [[String: Any]] else {
                state = .failed("No se pudo comprobar qué dispositivos HAVIT tiene esta cuenta. Revisa tu conexión e inténtalo otra vez.")
                return nil
            }

            var current: [HavitLinkedReceipt] = []
            for value in values {
                guard let deviceID = value["deviceId"] as? String, !deviceID.isEmpty,
                      let bindingID = value["bindingId"] as? String, !bindingID.isEmpty,
                      let linkedAtText = value["linkedAt"] as? String,
                      let linkedAt = ISO8601DateFormatter().date(from: linkedAtText) else {
                    throw HavitClaimError.invalidClaimResponse
                }
                let receipt = HavitLinkedReceipt(deviceID: deviceID, bindingID: bindingID, ownerUID: uid, linkedAt: linkedAt)
                try HavitClaimProofVault.saveReceipt(receipt)
                current.append(receipt)
            }
            let currentIDs = Set(current.map(\.deviceID))
            for stale in try HavitClaimProofVault.receipts() where stale.ownerUID == uid && !currentIDs.contains(stale.deviceID) {
                try HavitClaimProofVault.removeReceipts(deviceID: stale.deviceID, ownerUID: uid)
                HavitDeviceLocalState.clear(uid: uid, receipt: stale)
            }
            for proof in try HavitClaimProofVault.proofs() where currentIDs.contains(proof.deviceID) {
                try HavitClaimProofVault.removeProofs(deviceID: proof.deviceID)
            }
            linkedReceipts = try HavitClaimProofVault.receipts()
            if let first = current.first {
                state = .linked(deviceID: first.deviceID, bindingID: first.bindingID, ownerUID: uid)
            } else if case .linked = state {
                state = .none
            }
            return !current.isEmpty
        } catch {
            state = .failed("No se pudo comprobar qué dispositivos HAVIT tiene esta cuenta. Revisa tu conexión e inténtalo otra vez.")
            return nil
        }
    }

    func linkStatus(for uid: String?) -> String {
        if let uid, let receipt = linkedReceipts.first(where: { $0.ownerUID == uid }) {
            return "Dispositivo vinculado · \(receipt.deviceID)"
        }
        switch state {
        case .none: return "Aún no hay un dispositivo vinculado a esta cuenta."
        case .waitingForAccount: return "HAVIT está listo. Inicia sesión para completar la vinculación."
        case .linking: return "Confirmando la vinculación de HAVIT…"
        case .waitingForDevice: return "Esperando que HAVIT confirme la conexión al servidor…"
        case .expired: return "La prueba venció. Vuelve a abrir la configuración Bluetooth de HAVIT."
        case .linked(let deviceID, _, let ownerUID): return ownerUID == uid ? "Dispositivo vinculado · \(deviceID)" : "El dispositivo ya se vinculó con otra cuenta."
        case .linkedToAnotherAccount: return "Este dispositivo ya está vinculado con otra cuenta."
        case .needsNewBLEWindow: return "La prueba fue sustituida. Vuelve a abrir la configuración Bluetooth de HAVIT."
        case .failed(let message): return message
        }
    }

    func linkReceiptDetails(for uid: String?) -> String? {
        guard let uid,
              let receipt = linkedReceipts.first(where: { $0.ownerUID == uid }) else { return nil }
        return "ID: \(receipt.deviceID)\nVínculo: \(receipt.bindingID)"
    }

    func refreshAfterBLEProofSaved() { refreshStoredState() }

    func unlinkCurrentDevice(for uid: String) async {
        guard (!isUnlinking || isResettingForTests),
              let receipt = linkedReceipts.first(where: { $0.ownerUID == uid }),
              Auth.auth().currentUser?.uid == uid else { return }
        isUnlinking = true
        unlinkMessage = nil
        defer { if !isResettingForTests { isUnlinking = false } }
        do {
            let token = try await firebaseIDToken(forceRefresh: false)
            let requestId = unlinkRequestID(uid: uid, deviceID: receipt.deviceID)
            let (data, response) = try await postUnlink(receipt, requestId: requestId, idToken: token)
            guard let http = response as? HTTPURLResponse else { throw HavitClaimError.invalidClaimResponse }
            if (200..<300).contains(http.statusCode) {
                try validateUnlinkResponse(data, receipt: receipt)
            } else {
                let code = apiErrorCode(data) ?? "ERROR_DE_RED"
                if code == "UNAUTHENTICATED" {
                    let refreshedToken = try await firebaseIDToken(forceRefresh: true)
                    let (retryData, retryResponse) = try await postUnlink(receipt, requestId: requestId, idToken: refreshedToken)
                    guard let retryHTTP = retryResponse as? HTTPURLResponse,
                          (200..<300).contains(retryHTTP.statusCode) else {
                        throw HavitUnlinkError.server(apiErrorCode(retryData) ?? code)
                    }
                    try validateUnlinkResponse(retryData, receipt: receipt)
                } else {
                    throw HavitUnlinkError.server(code)
                }
            }
            try clearLocalLink(uid: uid, receipt: receipt)
            unlinkMessage = "HAVIT se desvinculó de esta cuenta. Para vincularlo con otra, conecta la placa a internet y completa una nueva prueba Bluetooth desde esa cuenta."
        } catch HavitUnlinkError.server(let code) where code == "DEVICE_NOT_FOUND_OR_NOT_OWNED" || code == "BINDING_CHANGED" {
            // The receipt is stale (for example, unlink completed but its response was lost
            // and another account reclaimed the unit). Never retain the old account's queue.
            do {
                try clearLocalLink(uid: uid, receipt: receipt)
                unlinkMessage = "Esta cuenta ya no es propietaria de la vinculación anterior. Se limpió su estado local; para usar HAVIT aquí, completa una vinculación Bluetooth nueva."
            } catch {
                unlinkMessage = "El servidor confirma que esta cuenta ya no es propietaria, pero no se pudo limpiar el estado local. Cierra y vuelve a abrir HAVIT para reintentar."
            }
        } catch {
            unlinkMessage = "No se pudo confirmar la desvinculación. El dispositivo y sus datos locales no se limpiaron: \(error.localizedDescription)"
        }
    }

    func resetAccountForTesting(for uid: String) async {
        guard !isUnlinking, Auth.auth().currentUser?.uid == uid else { return }
        isResettingForTests = true
        isUnlinking = true
        unlinkMessage = nil
        defer { isResettingForTests = false; isUnlinking = false }
        do {
            // Keep the local receipt (and therefore the HomeView BLE relay task)
            // alive while the reset is requested. Refreshing the account here
            // could discard a stale receipt and cancel BLE before the board
            // receives the reset ticket. The authenticated server request is
            // the authoritative ownership check.
            var receipt = linkedReceipts.first(where: { $0.ownerUID == uid })
            if receipt == nil {
                let accountDevices = await refreshAccountDevices(for: uid)
                guard let accountDevices else { throw HavitUnlinkError.server("ACCOUNT_DEVICE_LOOKUP_FAILED") }
                guard accountDevices else { throw HavitUnlinkError.server("DEVICE_NOT_LINKED_TO_ACCOUNT") }
                receipt = linkedReceipts.first(where: { $0.ownerUID == uid })
            }
            guard let receipt else {
                throw HavitUnlinkError.server("DEVICE_RECEIPT_NOT_AVAILABLE")
            }
            let key = factoryResetRequestKey(uid: uid, deviceID: receipt.deviceID)
            let requestID = UserDefaults.standard.string(forKey: key) ?? UUID().uuidString.lowercased()
            UserDefaults.standard.set(requestID, forKey: key)
            var (data, response) = try await postFactoryReset(receipt, requestID: requestID, token: try await firebaseIDToken(forceRefresh: false))
            if (response as? HTTPURLResponse)?.statusCode == 401 {
                (data, response) = try await postFactoryReset(receipt, requestID: requestID, token: try await firebaseIDToken(forceRefresh: true))
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  result["deviceId"] as? String == receipt.deviceID,
                  result["requestId"] as? String == requestID else {
                throw HavitUnlinkError.server(apiErrorCode(data) ?? "FACTORY_RESET_REQUEST_FAILED")
            }

            unlinkMessage = "Solicitud enviada. HAVIT la recibirá por Wi‑Fi si está conectado; si no, la app la entregará por Bluetooth. Mantén HAVIT encendido y deja esta pantalla abierta hasta confirmar."
            for _ in 0..<30 {
                if Auth.auth().currentUser?.uid != uid { throw CancellationError() }
                var (statusData, statusResponse) = try await getFactoryResetStatus(receipt, requestID: requestID, token: try await firebaseIDToken(forceRefresh: false))
                if (statusResponse as? HTTPURLResponse)?.statusCode == 401 {
                    (statusData, statusResponse) = try await getFactoryResetStatus(receipt, requestID: requestID, token: try await firebaseIDToken(forceRefresh: true))
                }
                if let http = statusResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                   let status = try JSONSerialization.jsonObject(with: statusData) as? [String: Any],
                   status["state"] as? String == "completed" {
                    try HavitClaimProofVault.removeProofs(deviceID: receipt.deviceID)
                    try HavitClaimProofVault.removeReceipts(deviceID: receipt.deviceID, ownerUID: uid)
                    try HavitClaimProofVault.removeFactoryResetProofs(deviceID: receipt.deviceID, ownerUID: uid)
                    HavitDeviceLocalState.clear(uid: uid, receipt: receipt)
                    HavitTaskStore.clearCachedData(uid: uid)
                    UserDefaults.standard.removeObject(forKey: key)
                    _ = await refreshAccountDevices(for: uid)
                    unlinkMessage = "HAVIT se restableció: borró Wi‑Fi, vinculación y actividades locales; Firebase purgó las actividades y operaciones de esta cuenta. La identidad de fábrica se conservó para volver a vincularlo."
                    refreshStoredState()
                    return
                }
                try await Task.sleep(for: .seconds(2))
            }
            unlinkMessage = "La solicitud sigue pendiente. Acerca HAVIT al iPhone, mantenlos encendidos y vuelve a comprobar Perfil. No se borraron los datos de Firebase antes de confirmar el borrado de la placa."
        } catch HavitUnlinkError.server(let code) where code == "DEVICE_NOT_FOUND_OR_NOT_OWNED" || code == "DEVICE_NOT_LINKED" {
            if let stale = linkedReceipts.first(where: { $0.ownerUID == uid }) {
                try? HavitClaimProofVault.removeProofs(deviceID: stale.deviceID)
                try? HavitClaimProofVault.removeReceipts(deviceID: stale.deviceID, ownerUID: uid)
                try? HavitClaimProofVault.removeFactoryResetProofs(deviceID: stale.deviceID, ownerUID: uid)
                HavitDeviceLocalState.clear(uid: uid, receipt: stale)
                HavitTaskStore.clearCachedData(uid: uid)
                UserDefaults.standard.removeObject(forKey: factoryResetRequestKey(uid: uid, deviceID: stale.deviceID))
                linkedReceipts = (try? HavitClaimProofVault.receipts()) ?? []
            }
            unlinkMessage = "El servidor ya no tiene un HAVIT vinculado a esta cuenta. Se limpió el estado local; no había un vínculo remoto que restablecer."
            refreshStoredState()
        } catch {
            unlinkMessage = "No se pudo completar el reinicio de pruebas: \(error.localizedDescription)"
        }
    }

    private func factoryResetRequestKey(uid: String, deviceID: String) -> String {
        "havit.factory-reset.request.\(uid).\(deviceID)"
    }

    private func postFactoryReset(_ receipt: HavitLinkedReceipt, requestID: String, token: String) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("v1").appendingPathComponent("devices")
            .appendingPathComponent(receipt.deviceID).appendingPathComponent("factory-reset"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["bindingId": receipt.bindingID, "requestId": requestID])
        return try await session.data(for: request)
    }

    private func getFactoryResetStatus(_ receipt: HavitLinkedReceipt, requestID: String, token: String) async throws -> (Data, URLResponse) {
        var components = URLComponents(url: apiBaseURL.appendingPathComponent("v1").appendingPathComponent("devices")
            .appendingPathComponent(receipt.deviceID).appendingPathComponent("factory-reset").appendingPathComponent(requestID), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "bindingId", value: receipt.bindingID)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return try await session.data(for: request)
    }

    private func clearLocalLink(uid: String, receipt: HavitLinkedReceipt) throws {
        try HavitClaimProofVault.removeProofs(deviceID: receipt.deviceID)
        try HavitClaimProofVault.removeReceipts(deviceID: receipt.deviceID, ownerUID: uid)
        HavitDeviceLocalState.clear(uid: uid, receipt: receipt)
        UserDefaults.standard.removeObject(forKey: unlinkRequestKey(uid: uid, deviceID: receipt.deviceID))
        linkedReceipts = try HavitClaimProofVault.receipts()
        state = .none
        refreshStoredState()
    }

    private func unlinkRequestKey(uid: String, deviceID: String) -> String {
        "havit.device.unlink.request.\(uid).\(deviceID)"
    }

    private func unlinkRequestID(uid: String, deviceID: String) -> String {
        let key = unlinkRequestKey(uid: uid, deviceID: deviceID)
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let requestID = UUID().uuidString.lowercased()
        UserDefaults.standard.set(requestID, forKey: key)
        return requestID
    }

    private func postUnlink(_ receipt: HavitLinkedReceipt, requestId: String, idToken: String) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("v1").appendingPathComponent("devices")
            .appendingPathComponent(receipt.deviceID).appendingPathComponent("unlink"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["bindingId": receipt.bindingID, "requestId": requestId])
        return try await session.data(for: request)
    }

    private func validateUnlinkResponse(_ data: Data, receipt: HavitLinkedReceipt) throws {
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              body["deviceId"] as? String == receipt.deviceID,
              body["state"] as? String == "unlinked",
              body["previousBindingId"] as? String == receipt.bindingID else {
            throw HavitClaimError.invalidClaimResponse
        }
    }

    func resumePendingClaim() {
        guard linkTask == nil, Auth.auth().currentUser != nil else {
            if Auth.auth().currentUser == nil { refreshStoredState() }
            return
        }
        linkTask = Task { [weak self] in
            guard let self else { return }
            await self.claimNewestPendingProof()
            self.linkTask = nil
        }
    }

    private func claimNewestPendingProof() async {
        let uid = Auth.auth().currentUser?.uid
        guard let uid else { refreshStoredState(); return }
        var proof: HavitClaimProof
        do {
            let candidates = try HavitClaimProofVault.proofs()
                .sorted { $0.expiresAt > $1.expiresAt }
            guard let latest = candidates.first else { refreshStoredState(); return }
            proof = latest
        } catch {
            state = .failed("No se pudo leer la prueba guardada en este iPhone.")
            return
        }
        guard proof.expiresAt > Date() else { state = .expired; return }
        state = .linking
        var retryDelay: TimeInterval = 5
        var didRefreshToken = false
        while !Task.isCancelled, Date() < proof.expiresAt {
            guard Auth.auth().currentUser?.uid == uid else { state = .waitingForAccount; return }
            do {
                let token = try await firebaseIDToken(forceRefresh: didRefreshToken)
                let (data, response) = try await postClaim(proof, idToken: token)
                guard let http = response as? HTTPURLResponse else { throw HavitClaimError.invalidClaimResponse }
                if (200..<300).contains(http.statusCode) {
                    let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    guard let body, body["deviceId"] as? String == proof.deviceID,
                          body["state"] as? String == "linked",
                          let bindingID = body["bindingId"] as? String,
                          !bindingID.isEmpty else { throw HavitClaimError.invalidClaimResponse }
                    let linkedAt = ISO8601DateFormatter().date(from: body["linkedAt"] as? String ?? "") ?? Date()
                    let receipt = HavitLinkedReceipt(deviceID: proof.deviceID, bindingID: bindingID, ownerUID: uid, linkedAt: linkedAt)
                    try HavitClaimProofVault.saveReceipt(receipt)
                    try HavitClaimProofVault.removeProofs(deviceID: proof.deviceID)
                    linkedReceipts = try HavitClaimProofVault.receipts()
                    state = .linked(deviceID: proof.deviceID, bindingID: bindingID, ownerUID: uid)
                    return
                }
                let code = apiErrorCode(data)
                switch code {
                case "CLAIM_NOT_READY":
                    state = .waitingForDevice
                    retryDelay = retryAfter(response: http, data: data, fallback: 5)
                case "RATE_LIMITED", "TEMPORARILY_UNAVAILABLE":
                    retryDelay = retryAfter(response: http, data: data, fallback: 15)
                case "CLAIM_EXPIRED": state = .expired; return
                case "DEVICE_ALREADY_LINKED": state = .linkedToAnotherAccount(deviceID: proof.deviceID); return
                case "FORBIDDEN": state = .failed("El servidor rechazó la credencial del dispositivo. Conservamos la prueba en este iPhone."); return
                case "CLAIM_SUPERSEDED":
                    if let replacement = try? HavitClaimProofVault.proofs()
                        .filter({ $0.deviceID == proof.deviceID && $0.id != proof.id && $0.expiresAt > Date() })
                        .max(by: { $0.expiresAt < $1.expiresAt }) {
                        proof = replacement
                        state = .linking
                        retryDelay = 1
                        continue
                    }
                    state = .needsNewBLEWindow
                    return
                case "CLAIM_PROOF_INVALID": state = .failed("El servidor no aceptó la prueba de HAVIT. Conservamos la prueba para poder revisar el problema."); return
                case "UNAUTHENTICATED":
                    if !didRefreshToken { didRefreshToken = true; continue }
                    state = .failed("La sesión de Firebase venció. Vuelve a iniciar sesión para vincular HAVIT.")
                    return
                default:
                    state = .failed("No se pudo vincular HAVIT (\(code ?? "ERROR_DE_RED")). La prueba sigue guardada en este iPhone.")
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                state = .waitingForDevice
                retryDelay = min(max(retryDelay, 5), 30)
            }
            let remaining = proof.expiresAt.timeIntervalSinceNow
            guard remaining > 0 else { state = .expired; return }
            do { try await Task.sleep(for: .seconds(min(retryDelay, remaining))) }
            catch { return }
        }
        state = .expired
    }

    private func firebaseIDToken(forceRefresh: Bool) async throws -> String {
        guard let user = Auth.auth().currentUser else { throw HavitClaimError.invalidClaimResponse }
        return try await withCheckedThrowingContinuation { continuation in
            user.getIDTokenForcingRefresh(forceRefresh) { token, error in
                if let error { continuation.resume(throwing: error) }
                else if let token { continuation.resume(returning: token) }
                else { continuation.resume(throwing: HavitClaimError.invalidClaimResponse) }
            }
        }
    }

    private func postClaim(_ proof: HavitClaimProof, idToken: String) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("v1/devices/claim"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "deviceId": proof.deviceID,
            "claimSessionId": proof.claimSessionID,
            "claimSecret": proof.claimSecret
        ])
        return try await session.data(for: request)
    }

    private func getOwnedDevices(idToken: String) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("v1").appendingPathComponent("user").appendingPathComponent("devices"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return try await session.data(for: request)
    }

    private func getTasks(idToken: String) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("v1").appendingPathComponent("tasks"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return try await session.data(for: request)
    }

    private func apiErrorCode(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return nil }
        return error["code"] as? String
    }

    private func retryAfter(response: HTTPURLResponse, data: Data, fallback: TimeInterval) -> TimeInterval {
        if let header = response.value(forHTTPHeaderField: "Retry-After"), let seconds = TimeInterval(header) {
            return min(max(seconds, 1), 60)
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let bodySeconds = object["error"] as? [String: Any],
           let seconds = bodySeconds["retryAfterSeconds"] as? Double {
            return min(max(seconds, 1), 60)
        }
        return fallback
    }
}

private enum HavitUnlinkError: LocalizedError {
    case server(String)
    var errorDescription: String? {
        switch self {
        case .server("ACCOUNT_DEVICE_LOOKUP_FAILED"):
            return "No se pudo consultar el vínculo de HAVIT. No se envió el restablecimiento ni se borraron datos. Revisa Internet e inténtalo de nuevo."
        case .server("DEVICE_NOT_LINKED_TO_ACCOUNT"):
            return "La cuenta iniciada no aparece como propietaria de un HAVIT vinculado. No se envió el restablecimiento ni se borraron datos. Inicia sesión con la cuenta que vinculó esta placa."
        case .server("DEVICE_RECEIPT_NOT_AVAILABLE"):
            return "La cuenta sí tiene un HAVIT vinculado, pero falta su recibo seguro en este iPhone. No se envió el restablecimiento; vuelve a abrir la app y actualiza Perfil."
        case .server("DEVICE_NOT_FOUND_OR_NOT_OWNED"):
            return "El servidor ya no reconoce esta cuenta como propietaria de HAVIT. Actualiza el estado antes de continuar."
        case .server("UNAUTHENTICATED"):
            return "Tu sesión venció. Inicia sesión otra vez y reintenta."
        case .server("UNLINK_INCOMPLETE"):
            return "No se pudieron desvincular todos los dispositivos. No se borraron las actividades."
        case .server("TASKS_UNAVAILABLE"):
            return "No se pudieron cargar las actividades de la cuenta. Los datos restantes se conservaron."
        case .server("TASK_DELETE_FAILED"):
            return "No se pudieron borrar todas las actividades. Vuelve a intentarlo para terminar el reinicio."
        case .server(let code):
            return "El servidor rechazó la desvinculación (\(code))."
        }
    }
}

private enum HavitDeviceLocalState {
    static func clear(uid: String, receipt: HavitLinkedReceipt) {
        // Sync data is not implemented yet. Keep cleanup scoped to the old owner/device/binding.
        let prefix = "havit.sync.\(uid).\(receipt.deviceID).\(receipt.bindingID)."
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

func havitClaimSecretBytes(_ secret: String) throws -> Data {
    guard secret.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil else {
        throw HavitClaimError.invalidSecret
    }
    let base64 = secret.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
    guard let bytes = Data(base64Encoded: base64), bytes.count == 32,
          bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == secret else {
        throw HavitClaimError.invalidSecret
    }
    return bytes
}

func havitClaimSecretHash(deviceID: String, sessionID: String, secretBytes: Data) -> String {
    var message = Data("havit-claim-v1:".utf8)
    message.append(Data(deviceID.utf8))
    message.append(0)
    message.append(Data(sessionID.utf8))
    message.append(0)
    message.append(secretBytes)
    return SHA256.hash(data: message).map { String(format: "%02x", $0) }.joined()
}
