import SwiftUI

private let havitSetupBackground = Color(red: 0.055, green: 0.055, blue: 0.059)

struct FoundDeviceView: View {
    let deviceName: String
    let isConnecting: Bool
    let errorMessage: String?
    let onConnect: (String) -> Void
    let onUseAnother: () -> Void
    @State private var bluetoothCode = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    step("PASO 2 · BLUETOOTH")
                    heroIcon.padding(.top, 106)
                    Text("\(deviceName) encontrado")
                        .font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
                        .multilineTextAlignment(.center).padding(.top, 32)
                    Text("Confirma que este nombre coincida con el que muestra tu dispositivo. La conexión será por Bluetooth seguro.")
                        .font(.system(size: 16)).foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center).padding(.horizontal, 28).padding(.top, 14)
                    Text("Escribe el código Bluetooth de seis dígitos que aparece en HAVIT.")
                        .font(.system(size: 14)).foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center).padding(.horizontal, 28).padding(.top, 20)
                    SecureField("Código Bluetooth", text: $bluetoothCode)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .padding(18).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
                        .padding(.horizontal, 28).padding(.top, 12)
                        .disabled(isConnecting)
                        .onChange(of: bluetoothCode) { _, value in
                            bluetoothCode = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                        }
                    Text(errorMessage ?? (isConnecting ? "Verificando el código y abriendo el canal cifrado…" : "El código protege la configuración de tu dispositivo."))
                        .font(.system(size: 14)).foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center).padding(.horizontal, 30).padding(.top, 18)
                }.frame(maxWidth: 440).frame(maxWidth: .infinity)
            }
            VStack(spacing: 12) {
                primaryButton(isConnecting ? "Verificando…" : "Conectar por Bluetooth", icon: "lock.shield", action: { onConnect(bluetoothCode) })
                    .disabled(isConnecting || bluetoothCode.count != 6)
                    .opacity(isConnecting || bluetoothCode.count != 6 ? 0.55 : 1)
                Button(action: onUseAnother) {
                    Text("Este no es mi HAVIT")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isConnecting)
                .opacity(isConnecting ? 0.45 : 1)
                Text("El nombre coincide con el identificador visible en HAVIT.")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
            }.padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 8)
        }
        .background(havitSetupBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct WiFiConnectingView: View {
    @ObservedObject var provisioning: WiFiProvisioningController
    let onRetry: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    step("PASO 4 · CONEXIÓN WI-FI")
                    heroIcon.padding(.top, 106)
                    Text(provisioning.phase == .connected ? "Wi‑Fi conectado" : provisioning.phase == .failed ? "No se pudo conectar" : "Conectando a Wi‑Fi")
                        .font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
                        .multilineTextAlignment(.center).padding(.top, 32)
                    Text(provisioning.status)
                        .font(.system(size: 16)).foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center).padding(.horizontal, 28).padding(.top, 14)
                    statusPill(provisioning.phase == .connected ? "Conexión confirmada por HAVIT" : provisioning.phase == .failed ? "Revisa la configuración" : "Esperando respuesta de HAVIT", icon: provisioning.phase == .connected ? "checkmark.circle" : provisioning.phase == .failed ? "exclamationmark.triangle" : "wifi")
                        .padding(.horizontal, 28).padding(.top, 23)
                    Text("La conexión Wi‑Fi se completa desde el dispositivo.")
                        .font(.system(size: 14)).foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center).padding(.horizontal, 30).padding(.top, 18)
                }.frame(maxWidth: 440).frame(maxWidth: .infinity)
            }
            VStack(spacing: 14) {
                if provisioning.phase == .connected {
                    primaryButton("Continuar", action: onContinue)
                } else if provisioning.phase == .failed {
                    primaryButton("Volver a conectar HAVIT", action: onRetry)
                } else {
                    ProgressView().tint(.white).padding()
                }
                if provisioning.phase == .failed {
                    Button("Configurar después", action: onContinue)
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity).frame(height: 48)
                }
            }.padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 8)
        }
        .background(havitSetupBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(provisioning.isProvisioning)
    }
}

private var heroIcon: some View {
    Image(systemName: "dot.radiowaves.left.and.right")
        .font(.system(size: 42, weight: .regular)).foregroundStyle(.white)
        .frame(width: 96, height: 96).background(Color.white.opacity(0.08), in: Circle())
}

private func step(_ value: String) -> some View {
    Text(value).font(.system(size: 10, weight: .bold))
        .foregroundStyle(Color(red: 176.0 / 255, green: 212.0 / 255, blue: 237.0 / 255).opacity(0.7))
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24)
}

private func primaryButton(_ title: String, icon: String? = nil, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon) }
            Text(title)
        }
        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.black)
        .frame(maxWidth: .infinity).frame(height: 54).background(.white, in: Capsule())
    }
    .buttonStyle(.plain)
}

private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(.black)
            .frame(maxWidth: .infinity).frame(height: 54).background(.white, in: Capsule())
    }.buttonStyle(.plain)
}

private func statusPill(_ title: String, icon: String) -> some View {
    HStack(spacing: 12) {
        Image(systemName: icon).font(.system(size: 18))
        Text(title).font(.system(size: 15, weight: .semibold))
        Spacer(minLength: 0)
    }
    .foregroundStyle(.white).padding(.horizontal, 17).frame(height: 54)
    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.12), lineWidth: 1))
}
