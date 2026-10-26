import SwiftUI

struct HavitWiFiNetworkPicker: View {
    @ObservedObject var provisioning: WiFiProvisioningController
    let selectedSSID: String
    let onSelect: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HavitSheetHeader(
                title: "Redes cercanas",
                actionIcon: "arrow.clockwise",
                actionLabel: "Volver a buscar redes",
                actionEnabled: !provisioning.isScanning && provisioning.sessionReady,
                onClose: onClose,
                onAction: { provisioning.scanNetworks() }
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Elige tu Wi‑Fi").font(.system(size: 25, weight: .bold)).foregroundStyle(.white)
                        Text("Redes de 2.4 GHz encontradas por HAVIT.")
                            .font(.system(size: 14)).foregroundStyle(.white.opacity(0.64))
                    }
                    if provisioning.isScanning {
                        HStack(spacing: 12) {
                            ProgressView().tint(.white)
                            Text("Buscando desde tu dispositivo…").font(.system(size: 14))
                        }
                        .foregroundStyle(.white.opacity(0.75)).padding(.vertical, 8)
                        .accessibilityElement(children: .combine)
                    }
                    LazyVStack(spacing: 10) {
                        ForEach(provisioning.networks) { network in
                            Button { onSelect(network.ssid) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "wifi")
                                        .font(.system(size: 18, weight: .semibold))
                                        .frame(width: 38, height: 38)
                                        .background(.white.opacity(0.08), in: Circle())
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(network.ssid).font(.system(size: 15, weight: .semibold))
                                            .lineLimit(2).multilineTextAlignment(.leading)
                                        Text(network.isOpen ? "Red abierta" : "Protegida con contraseña")
                                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                                    }
                                    Spacer(minLength: 4)
                                    if !network.isOpen {
                                        Image(systemName: "lock.fill").font(.system(size: 12))
                                            .foregroundStyle(.white.opacity(0.55))
                                    }
                                    Image(systemName: network.ssid == selectedSSID ? "checkmark.circle.fill" : "chevron.right")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(network.ssid == selectedSSID ? .white : .white.opacity(0.45))
                                }
                                .foregroundStyle(.white).padding(14).frame(maxWidth: .infinity, minHeight: 70)
                                .havitInsetCard()
                            }
                            .buttonStyle(.plain)
                            .disabled(provisioning.isScanning || !provisioning.sessionReady)
                            .accessibilityAddTraits(network.ssid == selectedSSID ? .isSelected : [])
                        }
                    }
                    if let error = provisioning.errorMessage {
                        Text(error).font(.system(size: 14)).foregroundStyle(.white.opacity(0.72))
                    } else if provisioning.networks.isEmpty && !provisioning.isScanning {
                        Text("No encontramos redes. Acerca HAVIT al router y vuelve a buscar.")
                            .font(.system(size: 14)).foregroundStyle(.white.opacity(0.64))
                    }
                    Button(action: onClose) {
                        Text("Escribir una red oculta")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
        }
        .havitSheetSurface()
    }
}
