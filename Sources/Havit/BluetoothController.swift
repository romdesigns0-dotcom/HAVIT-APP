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
        guard central.state == .poweredOn else { message = "Espera a que Bluetooth esté activo."; return }
        devices = []; peripherals = [:]; scanning = true
        message = "Buscando dispositivos BLE durante 12 segundos…"
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        Task { try? await Task.sleep(for: .seconds(12)); stopScan() }
    }
    func stopScan() { if scanning { central.stopScan(); scanning = false; if devices.isEmpty { message = "No se encontraron dispositivos BLE. Asegúrate de que estén encendidos y visibles." } } }
    func connect(_ id: UUID) {
        guard let p = peripherals[id] else { return }
        stopScan(); message = "Conectando a \(p.name ?? "dispositivo")…"; central.connect(p)
    }
    func disconnect(_ id: UUID) { if let p = peripherals[id] { central.cancelPeripheralConnection(p) } }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        peripherals[peripheral.identifier] = peripheral
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Dispositivo sin nombre"
        if let index = devices.firstIndex(where: { $0.id == peripheral.identifier }) { devices[index].rssi = RSSI.intValue }
        else { devices.append(BLEDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue, state: peripheral.state)) }
        devices.sort { $0.rssi > $1.rssi }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedID = peripheral.identifier; peripheral.delegate = self; peripheral.discoverServices(nil)
        updateState(peripheral.identifier, .connected); message = "Conectado a \(peripheral.name ?? "dispositivo"). Explorando servicios BLE…"
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { message = "Falló la conexión: \(error?.localizedDescription ?? "sin detalles")"; updateState(peripheral.identifier, .disconnected) }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { connectedID = nil; updateState(peripheral.identifier, .disconnected); message = "Desconectado. Una conexión BLE genérica no intercambia datos sin conocer el protocolo del accesorio." }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let ids = peripheral.services?.map { $0.uuid.uuidString }.joined(separator: ", ") ?? "ninguno anunciado"
        message = "Conectado a \(peripheral.name ?? "dispositivo"). Servicios BLE: \(ids)"
    }
    private func updateState(_ id: UUID, _ state: CBPeripheralState) { if let i = devices.firstIndex(where: { $0.id == id }) { devices[i].state = state } }
}
