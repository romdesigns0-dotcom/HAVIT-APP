import Foundation
import Combine
import FirebaseAuth
import ESPProvision

// BLE carries opaque AES-GCM envelopes. Only firmware and the backend hold the
// derived device key; Firebase authorizes the owner on every relay operation.
@MainActor
final class HavitTaskBLEBridge: ObservableObject {
    @Published private(set) var status = ""
    private var device: ESPDevice?
    private var generation = UUID()
    private var pendingFactoryResetRequestID: String?
    private let session = URLSession(configuration: .ephemeral)
    private let api = URL(string: "https://us-central1-havit-c8c1d.cloudfunctions.net/havitDeviceApiV1/v1/devices/relay")!
    private enum Failure: Error { case transport, identity, ownership, invalidEnvelope }

    func run(receipt: HavitLinkedReceipt?, active: Bool, tasks: HavitTaskStore) async {
        stop()
        guard active, let receipt, Auth.auth().currentUser?.uid == receipt.ownerUID else { return }
        let attempt = generation
        ESPProvisionManager.shared.enableLogs(false)
        defer { if generation == attempt { stop() } }
        var retryDelay: TimeInterval = 5
        var consecutiveFailures = 0
        while !Task.isCancelled, generation == attempt, Auth.auth().currentUser?.uid == receipt.ownerUID {
            do {
                if let pendingReset = try HavitClaimProofVault.factoryResetProofs().first(where: {
                    $0.deviceID == receipt.deviceID && $0.bindingID == receipt.bindingID && $0.ownerUID == receipt.ownerUID
                }) {
                    try await completeFactoryReset(pendingReset.requestID, proof: pendingReset.sealedProof, receipt: receipt)
                    try HavitClaimProofVault.removeFactoryResetProofs(deviceID: receipt.deviceID, ownerUID: receipt.ownerUID)
                    pendingFactoryResetRequestID = nil
                    status = "HAVIT restablecido de fábrica"
                    return
                }
                if device?.isSessionEstablished() != true {
                    status = "Buscando HAVIT por Bluetooth…"
                    device = try await connect(receipt: receipt)
                }
                guard let device else { throw Failure.transport }
                let head = try await send(Data([1]), device: device)
                guard head.count == 4 else { throw Failure.transport }
                let count = Int(read32(head))
                guard (1..<300000).contains(count) else { throw Failure.invalidEnvelope }
                var envelope = Data()
                while envelope.count < count {
                    try check(receipt, attempt: attempt)
                    let chunk = try await send(frame(2, UInt32(envelope.count)), device: device)
                    guard !chunk.isEmpty, chunk.count <= 160, envelope.count + chunk.count <= count else { throw Failure.transport }
                    envelope.append(chunk)
                }
                guard let object = try JSONSerialization.jsonObject(with: envelope) as? [String: Any],
                      object["protocol"] as? Int == 1,
                      object["deviceId"] as? String == receipt.deviceID,
                      object["bindingId"] as? String == receipt.bindingID,
                      let nonce = object["nonce"] as? String, nonce.count == 64 else { throw Failure.identity }
                try check(receipt, attempt: attempt)
                let response = try await relay(envelope, receipt: receipt)
                guard let reply = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                      reply["protocol"] as? Int == 1,
                      reply["deviceId"] as? String == receipt.deviceID,
                      reply["bindingId"] as? String == receipt.bindingID,
                      reply["nonce"] as? String == nonce,
                      (1..<300000).contains(response.count) else { throw Failure.identity }
                try check(receipt, attempt: attempt)
                _ = try await send(frame(3, UInt32(response.count)), device: device)
                var offset = 0
                while offset < response.count {
                    try check(receipt, attempt: attempt)
                    let end = min(offset + 160, response.count)
                    var packet = frame(4, UInt32(offset)); packet.append(response[offset..<end])
                    _ = try await send(packet, device: device)
                    offset = end
                }
                try check(receipt, attempt: attempt)
                let (applyStatus, _) = try await sendRaw(Data([5]), device: device)
                if applyStatus == 2 {
                    guard let requestID = pendingFactoryResetRequestID else { throw Failure.invalidEnvelope }
                    let proofHead = try await send(Data([6]), device: device)
                    guard proofHead.count == 4 else { throw Failure.invalidEnvelope }
                    let proofLength = Int(read32(proofHead))
                    guard (1..<4096).contains(proofLength) else { throw Failure.invalidEnvelope }
                    var proof = Data()
                    while proof.count < proofLength {
                        let chunk = try await send(frame(7, UInt32(proof.count)), device: device)
                        guard !chunk.isEmpty, chunk.count <= 160, proof.count + chunk.count <= proofLength else { throw Failure.transport }
                        proof.append(chunk)
                    }
                    let savedProof = HavitFactoryResetProof(
                        deviceID: receipt.deviceID,
                        bindingID: receipt.bindingID,
                        ownerUID: receipt.ownerUID,
                        requestID: requestID,
                        sealedProof: proof
                    )
                    try HavitClaimProofVault.saveAndVerify(savedProof)
                    try await completeFactoryReset(requestID, proof: proof, receipt: receipt)
                    try HavitClaimProofVault.removeFactoryResetProofs(deviceID: receipt.deviceID, ownerUID: receipt.ownerUID)
                    pendingFactoryResetRequestID = nil
                    status = "HAVIT restablecido de fábrica"
                    return
                }
                guard applyStatus == 0 else { throw Failure.transport }
                status = "HAVIT actualizado por Bluetooth"
                await tasks.synchronize()
                consecutiveFailures = 0
                retryDelay = 15
            } catch is CancellationError { return }
            catch Failure.ownership {
                status = "El vínculo cambió. Actualiza los dispositivos de tu cuenta."
                device?.disconnect(); device = nil
                return
            } catch {
                guard generation == attempt, !Task.isCancelled else { return }
                device?.disconnect(); device = nil
                consecutiveFailures += 1
                status = consecutiveFailures >= 3
                    ? "HAVIT sin conexión. Acércalo o configúralo a Wi‑Fi para sincronizar."
                    : "Buscando HAVIT por Bluetooth. Tus actividades siguen guardadas."
                retryDelay = min(max(retryDelay * 2, 5), 60)
            }
            do { try await Task.sleep(for: .seconds(retryDelay)) } catch { return }
        }
    }
    func stop() {
        generation = UUID()
        device?.disconnect(); device = nil
        status = ""
    }
    private func check(_ receipt: HavitLinkedReceipt, attempt: UUID) throws {
        guard !Task.isCancelled, generation == attempt, Auth.auth().currentUser?.uid == receipt.ownerUID else { throw CancellationError() }
    }
    private func connect(receipt: HavitLinkedReceipt) async throws -> ESPDevice {
        let name = "HAVIT-SYNC-" + receipt.deviceID.suffix(4).uppercased()
        let found: ESPDevice = try await wait { finish in
            ESPProvisionManager.shared.createESPDevice(deviceName: name, transport: .ble, security: .secure, proofOfPossession: "") { device, error in
                Task { @MainActor in
                    if let device, error == nil, device.name == name { finish(.success(device)) }
                    else { finish(.failure(Failure.transport)) }
                }
            }
        }
        // Retain before connecting so cancellation can also close an in-flight link.
        device = found
        let _: Bool = try await wait { finish in
            found.connect { state in
                Task { @MainActor in
                    switch state {
                    case .connected: finish(.success(true))
                    case .disconnected, .failedToConnect: finish(.failure(Failure.transport))
                    }
                }
            }
        }
        return found
    }
    private func send(_ packet: Data, device: ESPDevice) async throws -> Data {
        let (status, data) = try await sendRaw(packet, device: device)
        guard status == 0 else { throw Failure.transport }
        return data
    }
    private func sendRaw(_ packet: Data, device: ESPDevice) async throws -> (UInt8, Data) {
        let result: Data = try await wait { finish in
            device.sendData(path: "havit-relay", data: packet) { data, error in
                Task { @MainActor in
                    if let data, error == nil { finish(.success(data)) }
                    else { finish(.failure(Failure.transport)) }
                }
            }
        }
        guard let code = result.first else { throw Failure.transport }
        return (code, Data(result.dropFirst()))
    }
    private func relay(_ envelope: Data, receipt: HavitLinkedReceipt) async throws -> Data {
        for force in [false, true] {
            guard let user = Auth.auth().currentUser, user.uid == receipt.ownerUID else { throw CancellationError() }
            let token: String = try await wait { finish in
                user.getIDTokenForcingRefresh(force) { token, error in
                    Task { @MainActor in
                        if let token, error == nil { finish(.success(token)) }
                        else { finish(.failure(Failure.ownership)) }
                    }
                }
            }
            guard Auth.auth().currentUser?.uid == receipt.ownerUID else { throw CancellationError() }
            var request = URLRequest(url: api); request.httpMethod = "POST"; request.httpBody = envelope; request.timeoutInterval = 25
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.transport }
            if http.statusCode == 401, !force { continue }
            if http.statusCode == 403 {
                let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let code = (body?["error"] as? [String: Any])?["code"] as? String
                if code == "INVALID_RELAY_PROOF" { throw Failure.identity }
                throw Failure.ownership
            }
            guard http.statusCode == 200 else { throw Failure.transport }
            if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let requestID = body["factoryResetRequestId"] as? String,
               UUID(uuidString: requestID) != nil {
                pendingFactoryResetRequestID = requestID
            }
            return data
        }
        throw Failure.ownership
    }
    private func completeFactoryReset(_ requestID: String, proof: Data, receipt: HavitLinkedReceipt) async throws {
        guard UUID(uuidString: requestID) != nil,
              let proofObject = try JSONSerialization.jsonObject(with: proof) as? [String: Any],
              proofObject["deviceId"] as? String == receipt.deviceID,
              proofObject["bindingId"] as? String == receipt.bindingID else { throw Failure.invalidEnvelope }
        for force in [false, true] {
            guard let user = Auth.auth().currentUser, user.uid == receipt.ownerUID else { throw CancellationError() }
            let token: String = try await wait { finish in
                user.getIDTokenForcingRefresh(force) { token, error in
                    Task { @MainActor in
                        if let token, error == nil { finish(.success(token)) }
                        else { finish(.failure(Failure.ownership)) }
                    }
                }
            }
            var request = URLRequest(url: URL(string: "https://us-central1-havit-c8c1d.cloudfunctions.net/havitDeviceApiV1/v1/devices/\(receipt.deviceID)/factory-reset/complete")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 25
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["bindingId": receipt.bindingID, "requestId": requestID, "proof": proofObject])
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.transport }
            if http.statusCode == 401 {
                if !force { continue }
                throw Failure.ownership
            }
            if [403, 404, 409].contains(http.statusCode) { throw Failure.ownership }
            guard http.statusCode == 200,
                  let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  result["deviceId"] as? String == receipt.deviceID,
                  result["requestId"] as? String == requestID,
                  result["state"] as? String == "completed" else { throw Failure.transport }
            return
        }
        throw Failure.ownership
    }
    private func frame(_ op: UInt8, _ value: UInt32) -> Data {
        Data([op, UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)])
    }
    private func read32(_ bytes: Data) -> UInt32 {
        bytes.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
    }
    private func wait<T>(_ register: (@escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        let promise = HavitRelayPromise<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                promise.continuation = continuation
                promise.timer = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(25)) } catch { return }
                    promise.finish(.failure(Failure.transport))
                }
                if Task.isCancelled { promise.finish(.failure(CancellationError())) }
                else { register { promise.finish($0) } }
            }
        } onCancel: {
            Task { @MainActor in promise.finish(.failure(CancellationError())) }
        }
    }
}

@MainActor
private final class HavitRelayPromise<T> {
    var continuation: CheckedContinuation<T, Error>?
    var timer: Task<Void, Never>?
    func finish(_ result: Result<T, Error>) {
        guard let continuation else { return }
        self.continuation = nil; timer?.cancel(); timer = nil
        continuation.resume(with: result)
    }
}
