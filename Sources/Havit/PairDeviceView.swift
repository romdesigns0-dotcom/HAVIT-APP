import SwiftUI
import CoreBluetooth

struct PairDeviceView: View {
    @ObservedObject var bluetooth: BluetoothController
    let onSelectDevice: (BLEDevice) -> Void
    let onContinue: () -> Void

    private let background = Color(red: 15.0 / 255, green: 15.0 / 255, blue: 15.0 / 255)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    stepLabel("PASO 1 · BLUETOOTH")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)

                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 42, weight: .regular))
                        .foregroundStyle(.white)
                        .frame(width: 96, height: 96)
                        .background(Color.white.opacity(0.08), in: Circle())
                        .padding(.top, 108)

                    Text("Vincula tu HAVIT")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.top, 32)

                    Text("Enciende el dispositivo y búscalo por Bluetooth para iniciar la configuración segura.")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .padding(.top, 14)

                    Button(action: { bluetooth.scanning ? bluetooth.stopScan() : bluetooth.scan() }) {
                        HStack(spacing: 8) {
                            Image(systemName: bluetooth.scanning ? "stop.fill" : "magnifyingglass")
                            Text(bluetooth.scanning ? "Detener búsqueda" : "Buscar HAVIT")
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 28)
                    .padding(.top, 23)

                    if !bluetooth.devices.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(bluetooth.devices) { device in
                                Button { onSelectDevice(device) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "dot.radiowaves.left.and.right")
                                        Text(device.name).lineLimit(1)
                                        Spacer(minLength: 8)
                                        Text("Elegir")
                                            .fontWeight(.semibold)
                                    }
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 16)
                                    .frame(height: 52)
                                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 12)
                    }

                    Text(bluetooth.scanning ? "Buscando HAVIT cercanos por Bluetooth…" : bluetooth.message)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                        .padding(.top, 18)
                        .padding(.bottom, 18)
                }
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
            }

            VStack(spacing: 14) {
                Button(action: onContinue) {
                    Text("Configurar después")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)

                Text("El dispositivo se identifica como HAVIT-AB12. Manténlo encendido y cerca.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .background(background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private func stepLabel(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color(red: 176.0 / 255, green: 212.0 / 255, blue: 237.0 / 255).opacity(0.7))
            .padding(.horizontal, 24)
    }
}
