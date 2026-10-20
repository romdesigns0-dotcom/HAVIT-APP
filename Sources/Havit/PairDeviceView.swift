import SwiftUI
import CoreBluetooth

struct PairDeviceView: View {
    @ObservedObject var bluetooth: BluetoothController
    let onContinue: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Volver")
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(.white)
                        .frame(width: 96, height: 96)
                        .background(.white.opacity(0.08), in: Circle())
                        .padding(.top, 24)

                    Text("Conecta tu HAVIT")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    Text("Enciende el dispositivo y búscalo por Bluetooth para tener tus tareas a la vista.")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)

                    Button {
                        bluetooth.scanning ? bluetooth.stopScan() : bluetooth.scan()
                    } label: {
                        Label(bluetooth.scanning ? "Dejar de buscar" : "Buscar dispositivos", systemImage: "magnifyingglass")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 10)

                    if !bluetooth.devices.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(bluetooth.devices) { device in
                                HStack(spacing: 12) {
                                    Image(systemName: "wave.3.right")
                                        .foregroundStyle(.white)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(device.name).font(.subheadline.bold()).foregroundStyle(.white)
                                        Text("\(device.rssi) dBm")
                                            .font(.caption).foregroundStyle(.white.opacity(0.6))
                                    }
                                    Spacer()
                                    Button(device.state == .connected ? "Conectado" : "Conectar") {
                                        bluetooth.connect(device.id)
                                    }
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .disabled(device.state == .connected)
                                }
                                .padding(14)
                                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                            }
                        }
                    }

                    Text(bluetooth.message)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
            }

            VStack(spacing: 14) {
                Button(action: onContinue) {
                    Text(bluetooth.connectedID == nil ? "Configurar después" : "Continuar")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
                Text("Puedes usar HAVIT aunque tu dispositivo no esté conectado.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)
            .padding(.bottom, 20)
        }
        .background(Color(red: 0.059, green: 0.059, blue: 0.059).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}
