import SwiftUI
import UIKit

enum HavitCredentialMode { case email, phone, register, reset, emailLink }

struct HavitCredentialView: View {
    @ObservedObject var session: HavitAuthSession
    @Environment(\.dismiss) private var dismiss
    @State private var mode: HavitCredentialMode
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var phone = ""
    @State private var code = ""
    @State private var passwordVisible = false
    @State private var emailLink = ""

    init(session: HavitAuthSession, initialMode: HavitCredentialMode) {
        self.session = session
        _mode = State(initialValue: initialMode)
        _phone = State(initialValue: session.pendingPhoneNumber)
        _email = State(initialValue: session.savedEmailForLink)
    }

    private var title: String {
        switch mode {
        case .email: return "Correo electrónico"
        case .emailLink: return "Acceso sin contraseña"
        case .phone: return session.phoneVerificationID == nil ? "Número de teléfono" : "Verifica tu número"
        case .register: return "Crea tu cuenta"
        case .reset: return "Restablecer contraseña"
        }
    }

    private var subtitle: String {
        switch mode {
        case .email: return "Ingresa tu correo y contraseña\npara continuar."
        case .emailLink: return "Recibe un enlace de uso único\npara iniciar sesión en HAVIT."
        case .phone: return session.phoneVerificationID == nil ? "Ingresa tu número con código de país.\nTe enviaremos un código por SMS." : "Ingresa el código que recibiste por SMS\npara continuar."
        case .register: return "Organiza tus actividades con HAVIT.\nCompleta tus datos para empezar."
        case .reset: return "Ingresa tu correo y te enviaremos\nun enlace para cambiar tu contraseña."
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        if mode == .reset { changeMode(.email) } else { dismiss() }
                    } label: {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 20, weight: .regular))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Volver")
                    .padding(.leading, -10)
                    .disabled(session.isBusy)

                    Text(title)
                        .font(.system(size: 32, weight: .semibold))
                        .padding(.top, 18)
                    Text(subtitle)
                        .font(.system(size: 17))
                        .foregroundStyle(.white.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 14)

                    fields.padding(.top, 48)

                    if mode == .email {
                        Button("¿Olvidaste tu contraseña?") { changeMode(.reset) }
                            .font(.system(size: 15))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.top, 18)
                            .disabled(session.isBusy)
                    }
                    if mode == .email {
                        Button("Recibir enlace de acceso de uso único") { changeMode(.emailLink) }
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.top, 18)
                            .disabled(session.isBusy)
                    }
                    if mode == .emailLink {
                        Button("Usar mi contraseña") { changeMode(.email) }
                            .font(.system(size: 15))
                            .padding(.top, 18)
                            .disabled(session.isBusy)
                    }
                    if mode == .phone && session.phoneVerificationID != nil {
                        Button("Usar otro número") { session.resetPhoneVerification(); code = "" }
                            .font(.system(size: 15))
                            .padding(.top, 18)
                            .disabled(session.isBusy)
                    }
                    if let message = session.statusMessage, !message.isEmpty {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 16)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    Spacer(minLength: 60)
                    submitButton
                    alternatives.padding(.top, 40)
                    HStack(spacing: 4) {
                        Text(mode == .register ? "¿Ya tienes una cuenta?" : "¿No tienes una cuenta?")
                            .foregroundStyle(.white.opacity(0.65))
                        Button(mode == .register ? "Inicia sesión" : "Crea tu cuenta") {
                            changeMode(mode == .register ? .email : .register)
                        }
                        .fontWeight(.semibold)
                    }
                    .font(.system(size: 15))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 36)
                    .padding(.bottom, 24)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 440)
                .frame(minHeight: geometry.size.height, alignment: .topLeading)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .background(Color(red: 0.059, green: 0.059, blue: 0.059).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder private var fields: some View {
        VStack(spacing: 14) {
            if mode == .register {
                HavitAuthField(symbol: "person") {
                    TextField("Nombre", text: $name)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                }
            }
            if mode == .phone {
                HavitAuthField(asset: "phone") {
                    TextField("+52 55 1234 5678", text: $phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .disabled(session.phoneVerificationID != nil)
                }
                if session.phoneVerificationID != nil {
                    HavitAuthField(symbol: "key") {
                        TextField("Código SMS", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                    }
                }
            } else {
                HavitAuthField(asset: "mail") {
                    TextField("Correo electrónico", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if mode == .email || mode == .register {
                    HavitAuthField(symbol: "lock") {
                        Group {
                            if passwordVisible { TextField("Contraseña", text: $password) }
                            else { SecureField("Contraseña", text: $password) }
                        }
                        .textContentType(mode == .register ? .newPassword : .password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        Button { passwordVisible.toggle() } label: {
                            Image(systemName: passwordVisible ? "eye.slash" : "eye")
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(passwordVisible ? "Ocultar contraseña" : "Mostrar contraseña")
                    }
                }
                if mode == .emailLink {
                    HavitAuthField(symbol: "link") {
                        TextField("Pega tu enlace de acceso", text: $emailLink)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
            }
        }
        .disabled(session.isBusy)
    }

    private var submitTitle: String {
        switch mode {
        case .email: return "Iniciar sesión"
        case .emailLink: return emailLink.isEmpty && session.pendingEmailSignInLink == nil ? "Enviar enlace" : "Confirmar acceso"
        case .register: return "Crear cuenta"
        case .reset: return "Enviar enlace"
        case .phone: return session.phoneVerificationID == nil ? "Enviar código" : "Confirmar código"
        }
    }

    private var cannotSubmit: Bool {
        if session.isBusy { return true }
        switch mode {
        case .phone: return session.phoneVerificationID == nil ? phone.isEmpty : code.isEmpty
        case .reset, .emailLink: return email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .email, .register: return email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty
        }
    }

    private var submitButton: some View {
        Button {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            switch mode {
            case .email: session.signIn(email: email, password: password)
            case .register: session.createAccount(name: name, email: email, password: password)
            case .reset: session.resetPassword(email: email)
            case .emailLink:
                if emailLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && session.pendingEmailSignInLink == nil {
                    session.sendEmailSignInLink(email: email)
                } else {
                    session.completeEmailSignIn(email: email, pastedLink: emailLink.isEmpty ? nil : emailLink)
                }
            case .phone:
                if session.phoneVerificationID == nil { session.sendPhoneCode(to: phone) }
                else { session.confirmPhoneCode(code) }
            }
        } label: {
            ZStack {
                Text(session.isBusy ? "Un momento…" : submitTitle)
                    .font(.system(size: 17, weight: .semibold))
                HStack {
                    Spacer()
                    if session.isBusy { ProgressView().tint(.black) }
                    else { Image(systemName: "arrow.right").font(.system(size: 20)) }
                }
                .padding(.horizontal, 24)
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(.white, in: Capsule())
            .opacity(cannotSubmit ? 0.65 : 1)
        }
        .disabled(cannotSubmit)
    }

    private var alternatives: some View {
        VStack(spacing: 28) {
            HStack(spacing: 20) {
                Rectangle().fill(.white.opacity(0.2)).frame(height: 1)
                Text("o").font(.system(size: 15)).foregroundStyle(.white.opacity(0.7))
                Rectangle().fill(.white.opacity(0.2)).frame(height: 1)
            }
            HStack(spacing: 28) {
                alternative("phone", label: "Continuar con teléfono") { changeMode(.phone) }
                alternative("google-logo", label: "Continuar con Google") { session.signInWithGoogle() }
                alternative("mail", label: "Continuar con correo") { changeMode(.email) }
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(session.isBusy)
    }

    private func alternative(_ asset: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HavitAuthAsset(name: asset, isTemplate: asset != "google-logo")
                .frame(width: 24, height: 24)
                .frame(width: 54, height: 54)
                .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 1))
                .contentShape(Circle())
        }
        .accessibilityLabel(label)
    }

    private func changeMode(_ value: HavitCredentialMode) {
        mode = value
        password = ""
        passwordVisible = false
        session.statusMessage = nil
    }
}

private struct HavitAuthField<Content: View>: View {
    var symbol: String? = nil
    var asset: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 18) {
            if let asset {
                HavitAuthAsset(name: asset, isTemplate: true).frame(width: 21, height: 21)
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: 19)).frame(width: 21)
            }
            content()
                .font(.system(size: 16))
        }
        .foregroundStyle(.white.opacity(0.8))
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .frame(minHeight: 58)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 23))
        .overlay(RoundedRectangle(cornerRadius: 23).stroke(.white.opacity(0.12), lineWidth: 1))
    }
}

private struct HavitAuthAsset: View {
    let name: String
    var isTemplate = false

    var body: some View {
        if let path = Bundle.module.path(forResource: name, ofType: "png"),
           let image = UIImage(contentsOfFile: path) {
            Image(uiImage: image)
                .renderingMode(isTemplate ? .template : .original)
                .resizable()
                .scaledToFit()
        }
    }
}