import FirebaseAuth
import FirebaseCore
import GoogleSignIn
import UIKit
import Combine

@MainActor
final class HavitAuthSession: ObservableObject {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isBusy = false
    @Published private(set) var phoneVerificationID: String?
    @Published var statusMessage: String?
    @Published private(set) var pendingPhoneNumber = ""
    @Published private(set) var emailLinkWasSent = false
    @Published private(set) var pendingEmailSignInLink: String?
    var savedEmailForLink: String { UserDefaults.standard.string(forKey: "havit.auth.emailForLink") ?? "" }

    private var authListener: AuthStateDidChangeListenerHandle?

    init() {
        FirebaseAppDelegate.configureFirebase()
        guard FirebaseApp.app() != nil else {
            statusMessage = "No se pudo cargar la configuración de acceso."
            return
        }
        Auth.auth().languageCode = "es"
        let defaults = UserDefaults.standard
        if let sentAt = defaults.object(forKey: "havit.auth.smsSentAt") as? Date,
           Date().timeIntervalSince(sentAt) < 600 {
            phoneVerificationID = defaults.string(forKey: "havit.auth.smsVerificationID")
            pendingPhoneNumber = defaults.string(forKey: "havit.auth.smsPhone") ?? ""
        } else {
            resetPhoneVerification()
        }
        isAuthenticated = Auth.auth().currentUser != nil
        authListener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            self?.isAuthenticated = user != nil
        }
    }

    deinit {
        if let authListener {
            Auth.auth().removeStateDidChangeListener(authListener)
        }
    }

    @discardableResult
    func signOut() -> Bool {
        do {
            try Auth.auth().signOut()
            GIDSignIn.sharedInstance.signOut()
            isAuthenticated = false
            phoneVerificationID = nil
            statusMessage = nil
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    func resetPhoneVerification() {
        phoneVerificationID = nil
        pendingPhoneNumber = ""
        for key in ["havit.auth.smsVerificationID", "havit.auth.smsPhone", "havit.auth.smsSentAt"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        statusMessage = nil
    }

    func sendEmailSignInLink(email: String) {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.contains("@"), address.contains(".") else {
            statusMessage = "Escribe un correo válido para recibir tu enlace de acceso."
            return
        }
        guard let options = FirebaseApp.app()?.options,
              let projectID = options.projectID else {
            statusMessage = "Falta la configuración de Firebase para enviar el enlace."
            return
        }
        let settings = ActionCodeSettings()
        settings.url = URL(string: "https://\(projectID).firebaseapp.com/auth/complete")
        settings.handleCodeInApp = true
        settings.setIOSBundleID(options.bundleID)
        begin()
        Auth.auth().sendSignInLink(toEmail: address, actionCodeSettings: settings) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                if let error {
                    self.statusMessage = error.localizedDescription
                } else {
                    UserDefaults.standard.set(address, forKey: "havit.auth.emailForLink")
                    self.emailLinkWasSent = true
                    self.statusMessage = "Enviamos un enlace de uso único a tu correo. En esta versión de desarrollo, cópialo del mensaje y pégalo aquí para continuar."
                }
            }
        }
    }

    @discardableResult
    func handleEmailSignInURL(_ url: URL) -> Bool {
        guard Auth.auth().isSignIn(withEmailLink: url.absoluteString) else { return false }
        pendingEmailSignInLink = url.absoluteString
        if !savedEmailForLink.isEmpty { completeEmailSignIn(email: savedEmailForLink) }
        return true
    }

    func completeEmailSignIn(email: String, pastedLink: String? = nil) {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.contains("@"), address.contains(".") else {
            statusMessage = "Confirma el correo al que enviamos el enlace."
            return
        }
        let link = (pastedLink ?? pendingEmailSignInLink ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard Auth.auth().isSignIn(withEmailLink: link) else {
            statusMessage = "Pega el enlace completo del correo de acceso de HAVIT."
            return
        }
        begin()
        Auth.auth().signIn(withEmail: address, link: link) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                if let error {
                    self.statusMessage = error.localizedDescription
                } else {
                    self.clearEmailSignInLink()
                    self.statusMessage = nil
                }
            }
        }
    }

    func clearEmailSignInLink() {
        pendingEmailSignInLink = nil
        emailLinkWasSent = false
        UserDefaults.standard.removeObject(forKey: "havit.auth.emailForLink")
    }

    func resetPassword(email: String) {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.contains("@"), address.contains(".") else {
            statusMessage = "Escribe un correo válido para restablecer tu contraseña."
            return
        }
        begin()
        Auth.auth().sendPasswordReset(withEmail: address) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                self.statusMessage = error?.localizedDescription ?? "Si existe una cuenta con ese correo, recibirás un enlace para cambiar tu contraseña."
            }
        }
    }

    func signIn(email: String, password: String) {
        guard validate(email: email, password: password) else { return }
        begin()
        Auth.auth().signIn(withEmail: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password) { [weak self] _, error in
            self?.finish(error)
        }
    }

    func createAccount(name: String, email: String, password: String) {
        guard validate(email: email, password: password) else { return }
        guard password.count >= 6 else {
            statusMessage = "La contraseña debe tener al menos 6 caracteres."
            return
        }
        begin()
        Auth.auth().createUser(withEmail: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password) { [weak self] result, error in
            guard let self else { return }
            if let error {
                self.finish(error)
                return
            }
            let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !displayName.isEmpty, let user = result?.user else {
                self.finish(nil)
                return
            }
            let request = user.createProfileChangeRequest()
            request.displayName = displayName
            request.commitChanges { profileError in
                self.finish(profileError)
            }
        }
    }

    func signInWithGoogle() {
        guard let clientID = FirebaseApp.app()?.options.clientID, !clientID.isEmpty else {
            statusMessage = "Falta el CLIENT_ID de Google en GoogleService-Info.plist."
            return
        }
        guard let presenter = Self.presentingViewController() else {
            statusMessage = "No se pudo abrir el inicio de sesión de Google."
            return
        }

        begin()
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.signIn(withPresenting: presenter) { [weak self] result, error in
            guard let self else { return }
            if let error {
                self.finish(error)
                return
            }
            guard let user = result?.user, let idToken = user.idToken?.tokenString else {
                self.finishMessage("No se recibió el token de Google.")
                return
            }
            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: user.accessToken.tokenString
            )
            Auth.auth().signIn(with: credential) { [weak self] _, authError in
                self?.finish(authError)
            }
        }
    }

    func sendPhoneCode(to phoneNumber: String) {
        let phone = phoneNumber.filter { $0 == "+" || $0.isNumber }
        guard phone.hasPrefix("+"), phone.dropFirst().allSatisfy({ $0.isNumber }),
              (8...16).contains(phone.count) else {
            statusMessage = "Escribe tu número con código de país, por ejemplo +52 seguido de 10 dígitos."
            return
        }
        resetPhoneVerification()
        pendingPhoneNumber = phone
        begin()
        PhoneAuthProvider.provider().verifyPhoneNumber(phone, uiDelegate: nil) { [weak self] verificationID, error in
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                if let error {
                    self.statusMessage = Self.phoneErrorMessage(error)
                } else if let verificationID {
                    self.phoneVerificationID = verificationID
                    let defaults = UserDefaults.standard
                    defaults.set(verificationID, forKey: "havit.auth.smsVerificationID")
                    defaults.set(phone, forKey: "havit.auth.smsPhone")
                    defaults.set(Date(), forKey: "havit.auth.smsSentAt")
                    self.statusMessage = "Enviamos un código por SMS a \(phone)."
                } else {
                    self.statusMessage = "No pudimos solicitar el código. Inténtalo nuevamente."
                }
            }
        }
    }

    private static func phoneErrorMessage(_ error: Error) -> String {
        switch AuthErrorCode(rawValue: (error as NSError).code) {
        case .invalidPhoneNumber: return "El número no es válido. Incluye el código de país, por ejemplo +52."
        case .operationNotAllowed: return "El acceso por teléfono todavía no está habilitado para esta app en Firebase."
        case .appNotAuthorized, .invalidAppCredential, .missingAppCredential:
            return "Firebase no pudo verificar HAVIT. Revisa el registro de iOS y la configuración de verificación de la app."
        case .quotaExceeded: return "Se alcanzó la cuota de SMS del proyecto. Inténtalo después."
        case .tooManyRequests: return "Hay demasiados intentos. Espera unos minutos antes de volver a solicitar el código."
        case .networkError: return "No hay conexión con Firebase. Revisa tu conexión e inténtalo nuevamente."
        default: return error.localizedDescription
        }
    }
    func confirmPhoneCode(_ code: String) {
        guard let verificationID = phoneVerificationID else {
            statusMessage = "Primero solicita el código por SMS."
            return
        }
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            statusMessage = "Escribe el código que recibiste."
            return
        }
        begin()
        let credential = PhoneAuthProvider.provider().credential(withVerificationID: verificationID, verificationCode: value)
        Auth.auth().signIn(with: credential) { [weak self] _, error in
            self?.finish(error)
        }
    }

    private func validate(email: String, password: String) -> Bool {
        guard email.contains("@"), email.contains(".") else {
            statusMessage = "Escribe un correo válido."
            return false
        }
        guard !password.isEmpty else {
            statusMessage = "Escribe tu contraseña."
            return false
        }
        return true
    }

    private func begin() {
        isBusy = true
        statusMessage = nil
    }

    private func finish(_ error: Error?) {
        isBusy = false
        if error == nil { resetPhoneVerification() }
        statusMessage = error?.localizedDescription
    }

    private func finishMessage(_ message: String) {
        isBusy = false
        statusMessage = message
    }

    private static func presentingViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let root = scenes.flatMap { $0.windows }.first(where: { $0.isKeyWindow })?.rootViewController
        var presenter = root
        while let presented = presenter?.presentedViewController {
            presenter = presented
        }
        return presenter
    }
}
