import Foundation
import Combine
import ESPProvision

struct HavitWiFiNetwork: Identifiable {
    var id: String { ssid }
    let ssid: String
    let rssi: Int32
    let isOpen: Bool
}

@MainActor
final class WiFiProvisioningController: ObservableObject {
    enum Phase {
        case idle, verifyingIdentity, preparingClaim, savingProof, acknowledgingClaim
        case sending, connecting, connected, failed
    }

    @Published private(set) var isConnecting = false
    @Published private(set) var sessionReady = false
    @Published private(set) var isScanning = false
    @Published private(set) var networks: [HavitWiFiNetwork] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var networkName = ""
    @Published private(set) var identity: HavitDeviceIdentity?
    @Published private(set) var claimProofSessionID: String?
    private var device: ESPDevice?
    private var generation = UUID()
    private var timeout: Task<Void, Never>?

    var isProvisioning: Bool { phase == .sending || phase == .connecting }
    var status: String {
        switch phase {
        case .idle: return "Elige la red que usará HAVIT."
        case .verifyingIdentity: return "Verificando la identidad completa de HAVIT…"
        case .preparingClaim: return "Preparando la prueba segura de vinculación…"
        case .savingProof: return "Guardando la prueba en este iPhone…"
        case .acknowledgingClaim: return "Confirmando la prueba con HAVIT…"
        case .sending: return "Enviando las credenciales por el canal cifrado…"
        case .connecting: return "HAVIT está intentando conectarse a \(networkName)…"
        case .connected: return "HAVIT confirmó la conexión a \(networkName)."
        case .failed: return errorMessage ?? "No se pudo completar la conexión."
        }
    }

    func connect(name: String, selectedPeripheralID: UUID, code: String) {
        cancel()
        guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            errorMessage = "Escribe el código Bluetooth de seis dígitos que muestra HAVIT."
            return
        }
        ESPProvisionManager.shared.enableLogs(false)
        isConnecting = true
        let attempt = generation
        armTimeout(seconds: 60, attempt: attempt, message: "No se pudo verificar y preparar HAVIT. Revisa el código y vuelve a intentarlo.")
        ESPProvisionManager.shared.createESPDevice(
            deviceName: name,
            transport: .ble,
            security: .secure,
            proofOfPossession: code,
            peripheralIdentifier: selectedPeripheralID
        ) { [weak self] found, error in
            Task { @MainActor in
                guard let self, self.generation == attempt else { return }
                guard error == nil, let found, found.name == name else {
                    self.failSession("No se encontró el dispositivo Bluetooth que seleccionaste (\(name)). Vuelve a buscarlo.")
                    return
                }
                self.device = found
                found.connect { [weak self] state in
                    Task { @MainActor in
                        guard let self, self.generation == attempt else { return }
                        switch state {
                        case .connected:
                            self.phase = .verifyingIdentity
                            Task { await self.verifyIdentityAndAcknowledge(device: found, selectedName: name, attempt: attempt) }
                        case .failedToConnect:
                            self.failSession("No se pudo verificar el código Bluetooth. Comprueba el código que muestra HAVIT y vuelve a conectarlo.")
                        case .disconnected:
                            self.sessionReady = false
                            self.isConnecting = false
                            if self.phase != .connected {
                                self.failSession("Se perdió la conexión Bluetooth. Vuelve a conectar HAVIT para continuar.")
                            }
                        }
                    }
                }
            }
        }
    }

    func scanNetworks() {
        guard sessionReady, let device, !isScanning, !isProvisioning else { return }
        errorMessage = nil
        isScanning = true
        let attempt = generation
        armTimeout(seconds: 35, attempt: attempt, message: "HAVIT no respondió a la búsqueda de redes. Vuelve a conectarlo.")
        device.scanWifiList { [weak self] results, error in
            Task { @MainActor in
                guard let self, self.generation == attempt else { return }
                self.timeout?.cancel()
                self.isScanning = false
                if let error {
                    switch error {
                    case .emptyResultCount: self.errorMessage = "No se encontraron redes. Puedes buscar otra vez o escribir el nombre de una red oculta."
                    default: self.failSession("No se pudo consultar la lista de redes. Vuelve a conectar HAVIT.")
                    }
                    return
                }
                var unique: [String: HavitWiFiNetwork] = [:]
                for item in results ?? [] where !item.ssid.isEmpty {
                    let network = HavitWiFiNetwork(ssid: item.ssid, rssi: item.rssi, isOpen: item.auth == .open)
                    if unique[item.ssid] == nil || item.rssi > unique[item.ssid]!.rssi { unique[item.ssid] = network }
                }
                self.networks = unique.values.sorted {
                    $0.rssi == $1.rssi ? $0.ssid < $1.ssid : $0.rssi > $1.rssi
                }
                if self.networks.isEmpty { self.errorMessage = "No se encontraron redes. Acerca HAVIT al router y vuelve a buscar." }
            }
        }
    }

    func provision(ssid: String, password: String) {
        guard sessionReady, identity != nil, claimProofSessionID != nil,
              let device, !isScanning, !isProvisioning else {
            errorMessage = "Primero verifica la identidad y confirma la vinculación segura de HAVIT."
            return
        }
        guard !ssid.isEmpty, ssid.utf8.count <= 32, password.utf8.count <= 64 else {
            errorMessage = "Revisa el nombre de la red y su contraseña."
            return
        }
        networkName = ssid
        errorMessage = nil
        phase = .sending
        let attempt = generation
        armTimeout(seconds: 90, attempt: attempt, message: "HAVIT no confirmó la conexión. Revisa su pantalla antes de volver a configurarlo.")
        device.provision(ssid: ssid, passPhrase: password) { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == attempt, self.phase != .failed else { return }
                switch state {
                case .configApplied: self.phase = .connecting
                case .success:
                    self.timeout?.cancel()
                    self.phase = .connected
                    self.errorMessage = nil
                case .failure(let error):
                    let message: String
                    switch error {
                    case .wifiStatusAuthenticationError: message = "La contraseña de Wi‑Fi es incorrecta. Revisa la contraseña y vuelve a configurar HAVIT."
                    case .wifiStatusNetworkNotFound: message = "HAVIT no encontró esa red. Comprueba que sea de 2.4 GHz y que esté cerca."
                    default: message = "HAVIT no pudo confirmar la conexión Wi‑Fi. Revisa la red y vuelve a configurar el dispositivo."
                    }
                    self.failSession(message)
                }
            }
        }
    }

    func cancel() {
        generation = UUID()
        timeout?.cancel()
        timeout = nil
        ESPProvisionManager.shared.stopESPDevicesSearch()
        device?.disconnect()
        device = nil
        isConnecting = false
        sessionReady = false
        isScanning = false
        networks = []
        errorMessage = nil
        phase = .idle
        networkName = ""
        identity = nil
        claimProofSessionID = nil
    }

    private func verifyIdentityAndAcknowledge(device: ESPDevice, selectedName: String, attempt: UUID) async {
        do {
            phase = .verifyingIdentity
            let infoData = try await sendJSON(path: "havit-info", payload: [:], to: device)
            let infoObject = try jsonObject(infoData)
            let verifiedIdentity = try HavitDeviceIdentity(json: infoObject)
            guard verifiedIdentity.name == selectedName else { throw HavitClaimError.selectedDeviceMismatch }
            guard verifiedIdentity.identityProvisioned else { throw HavitClaimError.deviceNotEnrolled }
            identity = verifiedIdentity

            phase = .preparingClaim
            let responseData = try await sendJSON(
                path: "havit-claim",
                payload: ["protocol": 1, "op": "prepare_claim"],
                to: device
            )
            let response = try jsonObject(responseData)
            guard response["protocol"] as? Int == 1,
                  response["device_id"] as? String == verifiedIdentity.deviceID,
                  response["name"] as? String == verifiedIdentity.name,
                  let sessionID = response["claim_session_id"] as? String,
                  sessionID.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#, options: .regularExpression) != nil else {
                throw HavitClaimError.invalidClaimResponse
            }

            let proof: HavitClaimProof
            if response["state"] as? String == "acknowledged" {
                if let saved = try HavitClaimProofVault.proofs().first(where: {
                    $0.deviceID == verifiedIdentity.deviceID && $0.claimSessionID == sessionID
                }) {
                    guard saved.protocolVersion == 1 else { throw HavitClaimError.invalidClaimResponse }
                    guard saved.expiresAt > Date() else { throw HavitClaimError.expiredProof }
                    proof = saved
                } else {
                    // The ESP persisted an ACK from an older app session. Its secret is
                    // intentionally gone, so create a fresh proof over this secure BLE link.
                    phase = .preparingClaim
                    let replacementData = try await sendJSON(
                        path: "havit-claim",
                        payload: ["protocol": 1, "op": "restart_claim"],
                        to: device
                    )
                    let replacement = try jsonObject(replacementData, operation: "restart_claim")
                    let newProof = try pendingProof(from: replacement, identity: verifiedIdentity)
                    try HavitClaimProofVault.removeProofs(deviceID: verifiedIdentity.deviceID)
                    phase = .savingProof
                    try HavitClaimProofVault.saveAndVerify(newProof)
                    claimProofSessionID = newProof.claimSessionID
                    proof = newProof
                }
            } else {
                proof = try pendingProof(from: response, identity: verifiedIdentity)
                phase = .savingProof
                try HavitClaimProofVault.saveAndVerify(proof)
                claimProofSessionID = sessionID
            }

            guard self.generation == attempt else { return }
            phase = .acknowledgingClaim
            let secretBytes = try havitClaimSecretBytes(proof.claimSecret)
            let hash = havitClaimSecretHash(deviceID: proof.deviceID, sessionID: proof.claimSessionID, secretBytes: secretBytes)
            let ackData = try await sendJSON(
                path: "havit-claim",
                payload: [
                    "protocol": 1,
                    "op": "ack_claim",
                    "claim_session_id": proof.claimSessionID,
                    "claim_secret_hash": hash
                ],
                to: device
            )
            let ack = try jsonObject(ackData)
            guard ack["protocol"] as? Int == 1,
                  ack["device_id"] as? String == proof.deviceID,
                  ack["claim_session_id"] as? String == proof.claimSessionID,
                  ack["acknowledged"] as? Bool == true else {
                throw HavitClaimError.invalidAcknowledgement
            }
            guard self.generation == attempt else { return }
            timeout?.cancel()
            claimProofSessionID = proof.claimSessionID
            isConnecting = false
            sessionReady = true
            errorMessage = nil
            phase = .idle
        } catch {
            guard self.generation == attempt else { return }
            failSession(error.localizedDescription)
        }
    }

    private func pendingProof(from response: [String: Any], identity: HavitDeviceIdentity) throws -> HavitClaimProof {
        guard response["protocol"] as? Int == 1,
              response["device_id"] as? String == identity.deviceID,
              response["name"] as? String == identity.name,
              let sessionID = response["claim_session_id"] as? String,
              sessionID.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#, options: .regularExpression) != nil,
              let secret = response["claim_secret"] as? String,
              let expiresIn = response["expires_in"] as? TimeInterval,
              expiresIn > 0, expiresIn <= 1800 else {
            throw HavitClaimError.invalidClaimResponse
        }
        _ = try havitClaimSecretBytes(secret)
        return HavitClaimProof(
            protocolVersion: 1,
            deviceID: identity.deviceID,
            claimSessionID: sessionID,
            claimSecret: secret,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    private func sendJSON(path: String, payload: [String: Any], to device: ESPDevice) async throws -> Data {
        let request = try JSONSerialization.data(withJSONObject: payload)
        return try await withCheckedThrowingContinuation { continuation in
            device.sendData(path: path, data: request) { response, error in
                if let error { continuation.resume(throwing: error) }
                else if let response { continuation.resume(returning: response) }
                else { continuation.resume(throwing: HavitClaimError.invalidClaimResponse) }
            }
        }
    }

    private func jsonObject(_ data: Data, operation: String? = nil) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HavitClaimError.invalidClaimResponse
        }
        if let remoteError = object["error"] as? [String: Any], let code = remoteError["code"] as? String {
            if operation == "restart_claim",
               ["INVALID_REQUEST", "UNSUPPORTED_PROTOCOL", "UNSUPPORTED_OPERATION"].contains(code) {
                throw HavitClaimError.claimRecoveryUnavailable
            }
            switch code {
            case "DEVICE_NOT_ENROLLED": throw HavitClaimError.deviceNotEnrolled
            case "CLAIM_EXPIRED": throw HavitClaimError.expiredProof
            case "DEVICE_ALREADY_LINKED": throw HavitClaimError.deviceAlreadyLinked
            case "PERSISTENCE_FAILED": throw HavitClaimError.devicePersistenceFailed
            case "CLAIM_SESSION_MISMATCH": throw HavitClaimError.invalidAcknowledgement
            case "CLAIM_PROOF_INVALID": throw HavitClaimError.invalidSecret
            default: throw HavitClaimError.invalidClaimResponse
            }
        }
        return object
    }

    private func failSession(_ message: String) {
        generation = UUID()
        timeout?.cancel()
        isConnecting = false
        isScanning = false
        sessionReady = false
        errorMessage = message
        phase = .failed
        ESPProvisionManager.shared.stopESPDevicesSearch()
        device?.disconnect()
        device = nil
    }

    private func armTimeout(seconds: Int, attempt: UUID, message: String) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, self.generation == attempt else { return }
            self.failSession(message)
        }
    }
}
