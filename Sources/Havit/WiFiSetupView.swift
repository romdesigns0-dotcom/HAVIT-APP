import SwiftUI

struct WiFiSetupView: View {
    @ObservedObject var provisioning: WiFiProvisioningController
    let onStartConnection: (String, String) -> Void
    let onReconnect: () -> Void
    let onContinueWithoutWiFi: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var networkName = ""
    @State private var password = ""
    @State private var passwordVisible = false
    @State private var showSearchInfo = false

    private var isOpenNetwork: Bool { provisioning.networks.first(where: { $0.ssid == networkName })?.isOpen == true }
    private var canSend: Bool {
        provisioning.sessionReady && !provisioning.isScanning && !provisioning.isProvisioning &&
        !networkName.isEmpty && networkName.utf8.count <= 32 && (isOpenNetwork || !password.isEmpty)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Button { dismiss() } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 20)).foregroundStyle(.white)
                        .frame(width: 28, height: 34).contentShape(Rectangle())
                }
                .accessibilityLabel("Volver")
                .padding(.leading, -6)

                Text("PASO 3 · CONFIGURA EL WI-FI")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(red: 0.69, green: 0.83, blue: 0.93).opacity(0.7))
                    .padding(.top, 14)

                Text("Elige la red Wi-Fi")
                    .font(.system(size: 28, weight: .bold)).foregroundStyle(.white)
                    .padding(.top, 15)

                Text("Pulsa Buscar cuando quieras consultar las redes cercanas o escribe el nombre de una red oculta.")
                    .font(.system(size: 16)).foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 17)

                statusRow(icon: "lock.shield", text: provisioning.sessionReady ? "Canal Bluetooth cifrado" : "Vuelve a conectar HAVIT")
                    .padding(.top, 23)

                Text("Selecciona una red")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    .padding(.top, 21).padding(.bottom, 9)

                HStack(spacing: 12) {
                    Image(systemName: "wifi").frame(width: 22)
                    TextField("Nombre de red Wi-Fi", text: $networkName)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Buscar") {
                        showSearchInfo = true
                        provisioning.scanNetworks()
                    }
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                        .buttonStyle(.plain)
                }
                .font(.system(size: 15)).foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 18).frame(height: 58)
                .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.12), lineWidth: 1))

                if !isOpenNetwork { HStack(spacing: 13) {
                    Image(systemName: "lock").frame(width: 22)
                    Group {
                        if passwordVisible {
                            TextField("Contraseña de la red", text: $password)
                        } else {
                            SecureField("Contraseña de la red", text: $password)
                        }
                    }
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button { passwordVisible.toggle() } label: {
                        Image(systemName: passwordVisible ? "eye.slash" : "eye")
                            .frame(width: 24, height: 32)
                    }
                    .buttonStyle(.plain).accessibilityLabel(passwordVisible ? "Ocultar contraseña" : "Mostrar contraseña")
                }
                .font(.system(size: 15)).foregroundStyle(.white.opacity(0.82))
                .padding(.horizontal, 18).frame(height: 58)
                .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.12), lineWidth: 1))
                .padding(.top, 8)
                }

                if let error = provisioning.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.white.opacity(0.8)).padding(.top, 12)
                }
                if !provisioning.sessionReady {
                    Button("Volver a conectar HAVIT", action: onReconnect)
                        .buttonStyle(.bordered).padding(.top, 12)
                }

                Text("HAVIT utiliza redes Wi‑Fi de 2.4 GHz. Puedes escribir el nombre de una red oculta.")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.68)).padding(.top, 16)

                Text("Las credenciales se enviarán de forma segura a HAVIT por Bluetooth.")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 16)

                Button {
                    let submittedPassword = isOpenNetwork ? "" : password
                    password = ""
                    onStartConnection(networkName, submittedPassword)
                } label: {
                    Text("Enviar credenciales")
                        .font(.system(size: 16, weight: .bold)).foregroundStyle(.black)
                        .frame(maxWidth: .infinity).frame(height: 60).background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.55)
                .padding(.top, 22)

                Button(action: onContinueWithoutWiFi) {
                    Text("Cancelar configuración")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity).frame(height: 48)
                }
                .buttonStyle(.plain).padding(.top, 6)

                Text("Mantén HAVIT encendido y cerca durante el envío.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    .padding(.top, 2).padding(.bottom, 20)
            }
            .padding(.horizontal, 24).frame(maxWidth: 440).frame(maxWidth: .infinity)
        }
        .background(Color(red: 0.055, green: 0.055, blue: 0.059).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showSearchInfo) {
            HavitWiFiNetworkPicker(
                provisioning: provisioning,
                selectedSSID: networkName,
                onSelect: { ssid in
                    networkName = ssid
                    password = ""
                    showSearchInfo = false
                },
                onClose: { showSearchInfo = false }
            )
            .presentationDetents([.height(510), .large])
            .presentationDragIndicator(.hidden)
            .presentationBackground(.clear)
            .presentationCornerRadius(34)
            .preferredColorScheme(.dark)
        }
    }

    private func statusRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 18))
            Text(text).font(.system(size: 15, weight: .bold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white).padding(.horizontal, 17).frame(height: 54)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}
