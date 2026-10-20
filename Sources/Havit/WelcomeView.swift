import SwiftUI

struct WelcomeView: View {
    let onStart: () -> Void
    let onLogin: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer(minLength: 24)
                    HavitMark()
                    Spacer().frame(height: 81)

                    Text("Bienvenido a Havit")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text("Empieza hoy a organizar y realizar tus actividades.")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.top, 15)

                    Spacer().frame(height: 39)
                    Button(action: onStart) {
                        Text("Empecemos")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(Color(red: 0.996, green: 0.996, blue: 0.996), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Configura o conecta tu dispositivo HAVIT")
                    .frame(maxWidth: 344)

                    Spacer().frame(height: 39)
                    HStack(spacing: 4) {
                        Text("¿Ya tienes una cuenta?")
                            .font(.system(size: 16))
                            .foregroundStyle(.white)
                        Button(action: onLogin) {
                            Text("Inicia Sesión")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer().frame(height: 39)
                    LegalCopy()
                    Spacer().frame(height: 12)
                }
                .padding(.horizontal, 19)
                .frame(minHeight: geometry.size.height)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
            }
            .background(Color(red: 0.059, green: 0.059, blue: 0.059).ignoresSafeArea())
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct HavitMark: View {
    var body: some View {
        HStack(spacing: 62.377) {
            Capsule().fill(.white).frame(width: 36.623, height: 109.868)
                .shadow(color: .white.opacity(0.25), radius: 10.65, x: 0, y: 2)
            Capsule().fill(.white).frame(width: 36.623, height: 109.868)
                .shadow(color: .white.opacity(0.25), radius: 10.65, x: 0, y: 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("HAVIT")
    }
}

struct LegalCopy: View {
    var body: some View {
        (
            Text("Al tocar ") +
            Text("Empecemos").bold() +
            Text(", aceptas nuestros ") +
            Text("Términos y condiciones").bold() +
            Text(" y nuestra ") +
            Text("Política de privacidad").bold() +
            Text(".")
        )
        .font(.system(size: 14))
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}
