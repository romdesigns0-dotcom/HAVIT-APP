import SwiftUI

struct WelcomeView: View {
    let onStart: () -> Void
    let onLogin: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer(minLength: 24)
                    HavitMark(onTap: onLogin)
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
    var onTap: (() -> Void)? = nil

    @State private var eyeHeight: CGFloat = 4
    @State private var eyeOpacity = 1.0
    @State private var animationTask: Task<Void, Never>?
    @State private var isActivating = false

    private let eyeWidth: CGFloat = 36.623
    private let eyeGap: CGFloat = 62.377
    private let closedHeight: CGFloat = 4
    private let restingHeight: CGFloat = 98
    private let openHeight: CGFloat = 109.868

    var body: some View {
        HStack(alignment: .bottom, spacing: eyeGap) {
            eye
            eye
        }
        .frame(width: eyeWidth * 2 + eyeGap, height: 109.868, alignment: .bottom)
        .contentShape(Rectangle())
        .opacity(eyeOpacity)
        .onTapGesture { activate() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("HAVIT")
        .accessibilityHint(onTap == nil ? "" : "Toca para continuar al acceso")
        .accessibilityAction { activate() }
        .onAppear { startAnimation() }
        .onDisappear { animationTask?.cancel() }
    }

    private var eye: some View {
        Capsule()
            .fill(.white)
            .frame(width: eyeWidth, height: eyeHeight)
            .shadow(color: .white.opacity(0.25), radius: 10.65, x: 0, y: 2)
    }

    @MainActor
    private func startAnimation() {
        animationTask?.cancel()
        animationTask = Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.46)) { eyeHeight = restingHeight }
            guard await pause(milliseconds: 460) else { return }

            withAnimation(.easeInOut(duration: 0.18)) { eyeHeight = openHeight }
            guard await pause(milliseconds: 180) else { return }

            while !Task.isCancelled {
                guard await pause(milliseconds: 3_400) else { return }
                withAnimation(.easeInOut(duration: 0.12)) { eyeHeight = closedHeight }
                guard await pause(milliseconds: 120) else { return }
                withAnimation(.easeInOut(duration: 0.16)) { eyeHeight = openHeight }
                guard await pause(milliseconds: 160) else { return }
            }
        }
    }

    @MainActor
    private func activate() {
        guard let onTap, !isActivating else { return }
        isActivating = true
        animationTask?.cancel()
        animationTask = Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.12)) { eyeHeight = closedHeight }
            guard await pause(milliseconds: 120) else { return }

            withAnimation(.easeInOut(duration: 0.16)) { eyeHeight = openHeight }
            guard await pause(milliseconds: 160) else { return }

            withAnimation(.easeInOut(duration: 0.3)) { eyeOpacity = 0 }
            guard await pause(milliseconds: 300) else { return }
            onTap()
        }
    }

    @MainActor
    private func pause(milliseconds: Int) async -> Bool {
        do {
            try await Task.sleep(for: .milliseconds(milliseconds))
            return !Task.isCancelled
        } catch {
            return false
        }
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
