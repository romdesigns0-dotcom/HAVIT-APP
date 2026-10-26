import SwiftUI
import UIKit

private enum LoginSheet: String, Identifiable {
    case phone
    case email
    case createAccount
    var id: String { rawValue }
}

struct LoginView: View {
    @ObservedObject var session: HavitAuthSession
    var onContinueWithoutAccount: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var activeSheet: LoginSheet?

    var body: some View {
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer(minLength: 24)
                    HavitMark()
                    Spacer().frame(height: 81)

                    Text("Inicia Sesión")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)

                    Text("Empieza hoy a organizar y realizar tus actividades.")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.top, 15)

                    Spacer().frame(height: 39)
                    VStack(spacing: 15) {
                        providerButton(title: "Teléfono", asset: "phone") {
                            activeSheet = .phone
                        }
                        providerButton(title: "Google", asset: "google-logo") {
                            session.signInWithGoogle()
                        }
                        providerButton(title: "Correo electrónico", asset: "mail") {
                            activeSheet = .email
                        }
                    }

                    .frame(maxWidth: 344)
                    Spacer().frame(height: 34)
                    HStack(spacing: 4) {
                        Text("¿No tienes una cuenta?")
                            .font(.system(size: 16))
                            .foregroundStyle(.white)
                        Button {
                            activeSheet = .createAccount
                        } label: {
                            Text("Crea tu cuenta")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }

                    if let message = session.statusMessage, !message.isEmpty {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                            .padding(.top, 12)
                    }

                    Spacer().frame(height: 37)
                    LegalCopy()
                }
                .padding(.horizontal, 19)
                .frame(minHeight: geometry.size.height)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
            }
            .background(Color(red: 0.059, green: 0.059, blue: 0.059).ignoresSafeArea())
        }
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) {
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
                if let onContinueWithoutAccount {
                    Button("Sin cuenta", action: onContinueWithoutAccount)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(minHeight: 44)
                        .disabled(session.isBusy)
                }
            }
            .padding(.horizontal, 19)
        }
        .onChange(of: activeSheet) { _, _ in session.statusMessage = nil }
        .sheet(item: $activeSheet) { sheet in
            HavitCredentialView(session: session, initialMode: sheet == .phone ? .phone : (sheet == .createAccount ? .register : .email))
            .preferredColorScheme(.dark)
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
            .interactiveDismissDisabled(session.isBusy)
        }
    }

    private func providerImage(named name: String) -> UIImage {
        guard let path = Bundle.module.path(forResource: name, ofType: "png", inDirectory: "Auth") ?? Bundle.module.path(forResource: name, ofType: "png"),
              let image = UIImage(contentsOfFile: path) else {
            return UIImage(systemName: "person.crop.circle") ?? UIImage()
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    private func providerButton(title: String, asset: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(uiImage: providerImage(named: asset))
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: asset == "mail" ? 25 : (asset == "phone" ? 18 : 22), height: asset == "mail" ? 20 : 22)
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(Color(red: 0.996, green: 0.996, blue: 0.996), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(session.isBusy)
        .accessibilityHint(session.isBusy ? "Procesando inicio de sesión" : "")
    }
}
