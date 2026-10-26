import CoreBluetooth
import Foundation

struct BLEDevice: Identifiable {
    let id: UUID
    var name: String
    var rssi: Int
    var state: CBPeripheralState
}

@MainActor
final class BluetoothController: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    @Published private(set) var devices: [BLEDevice] = []
    @Published private(set) var message = "Pulsa Buscar para detectar dispositivos Bluetooth LE cercanos."
    @Published private(set) var scanning = false
    @Published private(set) var connectedID: UUID?
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var scanTimeout: Task<Void, Never>?

    override init() { super.init(); central = CBCentralManager(delegate: self, queue: .main) }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: message = "Bluetooth activo. Pulsa Buscar."
        case .unauthorized: message = "Permiso de Bluetooth denegado en Ajustes."
        case .poweredOff: message = "Activa Bluetooth en el iPhone."
        default: message = "Bluetooth: \(central.state.rawValue)"
        }
    }
    func scan() {
        switch central.state {
        case .poweredOn:
            break
        case .unauthorized:
            message = "HAVIT no tiene permiso de Bluetooth. Actívalo en Ajustes → Privacidad y seguridad → Bluetooth."
            return
        case .poweredOff:
            message = "Activa Bluetooth en el iPhone y vuelve a buscar."
            return
        case .unsupported:
            message = "Este iPhone no admite Bluetooth LE."
            return
        case .resetting, .unknown:
            message = "Bluetooth aún se está iniciando. Espera un momento y vuelve a buscar."
            return
        @unknown default:
            message = "No se pudo iniciar Bluetooth. Revisa el permiso de HAVIT en Ajustes."
            return
        }
        scanTimeout?.cancel()
        devices = []; peripherals = [:]; scanning = true
        message = "Buscando dispositivos BLE durante 12 segundos…"
        // Keep listening for names included in later scan responses.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        scanTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            self?.stopScan()
        }
    }
    func stopScan() {
        guard scanning else { return }
        scanTimeout?.cancel()
        scanTimeout = nil
        central.stopScan()
        scanning = false
        if devices.isEmpty {
            message = "No se detectó HAVIT. Confirma que el dispositivo esté en modo de configuración Bluetooth y vuelve a buscar."
        }
    }
    func connect(_ id: UUID) {
        guard let p = peripherals[id] else { return }
        stopScan(); message = "Conectando a \(displayName(for: p, advertisedName: nil))…"; central.connect(p)
    }
    func disconnect(_ id: UUID) { if let p = peripherals[id] { central.cancelPeripheralConnection(p) } }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        guard scanning else { return }
        // Each row keeps its initial name and position for the whole scan.
        guard !devices.contains(where: { $0.id == peripheral.identifier }) else { return }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard let name = resolvedName(advertisedName) ?? resolvedName(peripheral.name) else { return }
        // The normal relay is used automatically for an existing binding;
        // it does not provide the endpoints of the setup/PIN flow.
        guard !name.uppercased().hasPrefix("HAVIT-SYNC-") else { return }
        peripherals[peripheral.identifier] = peripheral
        devices.append(BLEDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue, state: peripheral.state))
    }

    private func resolvedName(_ candidate: String?) -> String? {
        guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func displayName(for peripheral: CBPeripheral, advertisedName: String?) -> String {
        if let device = devices.first(where: { $0.id == peripheral.identifier }) { return device.name }
        for candidate in [advertisedName, peripheral.name] {
            if let value = resolvedName(candidate) {
                return value
            }
        }
        return "Dispositivo · \(peripheral.identifier.uuidString.suffix(4))"
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedID = peripheral.identifier; peripheral.delegate = self; peripheral.discoverServices(nil)
        updateState(peripheral.identifier, .connected); message = "Conectado a \(displayName(for: peripheral, advertisedName: nil)). Explorando servicios BLE…"
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { message = "Falló la conexión: \(error?.localizedDescription ?? "sin detalles")"; updateState(peripheral.identifier, .disconnected) }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { connectedID = nil; updateState(peripheral.identifier, .disconnected); message = "Desconectado. Una conexión BLE genérica no intercambia datos sin conocer el protocolo del accesorio." }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let ids = peripheral.services?.map { $0.uuid.uuidString }.joined(separator: ", ") ?? "ninguno anunciado"
        message = "Conectado a \(displayName(for: peripheral, advertisedName: nil)). Servicios BLE: \(ids)"
    }
    private func updateState(_ id: UUID, _ state: CBPeripheralState) { if let i = devices.firstIndex(where: { $0.id == id }) { devices[i].state = state } }
}
