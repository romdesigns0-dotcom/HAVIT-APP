import AVFoundation
import Foundation
import MusicKit
import UserNotifications

struct SessionAlertTone: Identifiable, Hashable {
    let id: String
    let title: String
    let fileName: String?

    static let all: [SessionAlertTone] = [
        SessionAlertTone(id: "system", title: "Sonido del sistema", fileName: nil),
        SessionAlertTone(id: "soft-bell", title: "Campana suave", fileName: "SoftBell.wav"),
        SessionAlertTone(id: "warm-chime", title: "Campanillas", fileName: "WarmChime.wav"),
        SessionAlertTone(id: "wood-block", title: "Madera", fileName: "WoodBlock.wav")
    ]

    static func notificationSound(for id: String) -> UNNotificationSound {
        guard let tone = all.first(where: { $0.id == id }), let fileName = tone.fileName else {
            return .default
        }
        installBundledSounds()
        return UNNotificationSound(named: UNNotificationSoundName(rawValue: fileName))
    }

    static func bundledSound(named fileName: String) -> URL? {
        let url = URL(fileURLWithPath: fileName)
        return Bundle.module.url(
            forResource: url.deletingPathExtension().lastPathComponent,
            withExtension: url.pathExtension
        )
    }

    static func installBundledSounds() {
        let manager = FileManager.default
        guard let library = manager.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let directory = library.appendingPathComponent("Sounds", isDirectory: true)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            for tone in all {
                guard let fileName = tone.fileName else { continue }
                let destination = directory.appendingPathComponent(fileName)
                guard !manager.fileExists(atPath: destination.path),
                      let source = bundledSound(named: fileName) else { continue }
                try manager.copyItem(at: source, to: destination)
            }
        } catch {
            NSLog("Could not prepare focus notification sounds: %@", error.localizedDescription)
        }
    }
}

@MainActor
final class FocusAudioController: ObservableObject {
    @Published private(set) var songs: [Song] = []
    @Published private(set) var isLoadingLibrary = false
    @Published private(set) var selectedAudioTitle: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var message = "Elige una canción de tu biblioteca o importa un audio desde Archivos."
    @Published var selectedAlertToneID: String {
        didSet { UserDefaults.standard.set(selectedAlertToneID, forKey: "study.notificationSound") }
    }

    private let player = ApplicationMusicPlayer.shared
    private var selectedSong: Song?
    private var localPlayer: AVAudioPlayer?
    private var tonePreviewPlayer: AVAudioPlayer?
    private var importedFileName: String?

    init() {
        let defaults = UserDefaults.standard
        selectedAlertToneID = defaults.string(forKey: "study.notificationSound") ?? "system"
        selectedAudioTitle = defaults.string(forKey: "study.selectedAudioTitle")
        importedFileName = defaults.string(forKey: "study.localAudioFile")
        SessionAlertTone.installBundledSounds()
    }

    func connectLibrary() async {
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }
        let status = await MusicAuthorization.request()
        guard status == .authorized else {
            message = "No se autorizó el acceso a Música. Puedes importar un audio desde Archivos."
            return
        }

        do {
            let response = try await MusicLibraryRequest<Song>().response()
            songs = Array(response.items)
            let savedID = UserDefaults.standard.string(forKey: "study.appleMusicSongID")
            selectedSong = savedID.flatMap { id in songs.first(where: { $0.id.rawValue == id }) }
            if let selectedSong {
                selectedAudioTitle = "\(selectedSong.title) — \(selectedSong.artistName)"
            }
            message = songs.isEmpty
                ? "La biblioteca no devolvió canciones. Revisa el permiso de Música o usa Archivos."
                : "Biblioteca cargada: \(songs.count) canciones."
        } catch {
            songs = []
            message = "No se pudo abrir la biblioteca. Puede faltar Apple Music en la firma de esta app: \(error.localizedDescription)"
        }
    }

    func setMessage(_ value: String) { message = value }

    func select(_ song: Song) {
        selectedSong = song
        importedFileName = nil
        selectedAudioTitle = "\(song.title) — \(song.artistName)"
        let defaults = UserDefaults.standard
        defaults.set(song.id.rawValue, forKey: "study.appleMusicSongID")
        defaults.set(selectedAudioTitle, forKey: "study.selectedAudioTitle")
        defaults.removeObject(forKey: "study.localAudioFile")
        message = "Canción seleccionada. Se reproducirá al iniciar una sesión."
    }

    func importAudio(from source: URL) {
        let didAccess = source.startAccessingSecurityScopedResource()
        defer { if didAccess { source.stopAccessingSecurityScopedResource() } }

        do {
            let manager = FileManager.default
            let directory = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("StudyAudio", isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let safeName = source.lastPathComponent
            let destination = directory.appendingPathComponent(safeName)
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try manager.copyItem(at: source, to: destination)

            selectedSong = nil
            importedFileName = safeName
            selectedAudioTitle = safeName
            let defaults = UserDefaults.standard
            defaults.set(safeName, forKey: "study.localAudioFile")
            defaults.set(safeName, forKey: "study.selectedAudioTitle")
            defaults.removeObject(forKey: "study.appleMusicSongID")
            message = "Audio guardado en HAVIT. Se reproducirá durante la sesión."
        } catch {
            message = "No se pudo importar el audio: \(error.localizedDescription)"
        }
    }

    func previewSelection() async {
        if isPlaying {
            stop()
        } else {
            await playSelection()
        }
    }

    func startForFocusSession(enabled: Bool) async {
        guard enabled, !isPlaying else { return }
        await playSelection()
    }

    func stop() {
        localPlayer?.stop()
        localPlayer = nil
        player.stop()
        isPlaying = false
    }

    func previewAlertTone() {
        guard let tone = SessionAlertTone.all.first(where: { $0.id == selectedAlertToneID }),
              let fileName = tone.fileName,
              let url = SessionAlertTone.bundledSound(named: fileName) else {
            message = "Se usará el sonido estándar de iOS para el aviso."
            return
        }
        do {
            tonePreviewPlayer?.stop()
            tonePreviewPlayer = try AVAudioPlayer(contentsOf: url)
            tonePreviewPlayer?.prepareToPlay()
            tonePreviewPlayer?.play()
        } catch {
            message = "No se pudo reproducir el tono: \(error.localizedDescription)"
        }
    }

    private func playSelection() async {
        do {
            if selectedSong == nil, importedFileName == nil,
               MusicAuthorization.currentStatus == .authorized,
               let savedID = UserDefaults.standard.string(forKey: "study.appleMusicSongID") {
                let response = try await MusicLibraryRequest<Song>().response()
                selectedSong = response.items.first(where: { $0.id.rawValue == savedID })
            }
            if let selectedSong {
                localPlayer?.stop()
                localPlayer = nil
                player.queue = .init(for: [selectedSong])
                try await player.play()
                isPlaying = true
                message = "Reproduciendo \(selectedSong.title)."
                return
            }

            guard let importedFileName else {
                message = "Primero elige una canción de la biblioteca o importa un audio."
                return
            }
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("StudyAudio", isDirectory: true)
                .appendingPathComponent(importedFileName)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            localPlayer = try AVAudioPlayer(contentsOf: url)
            localPlayer?.numberOfLoops = -1
            guard localPlayer?.play() == true else { throw AudioError.couldNotStart }
            isPlaying = true
            message = "Reproduciendo \(importedFileName)."
        } catch {
            isPlaying = false
            message = "No se pudo reproducir. Comprueba el archivo o la suscripción a Apple Music: \(error.localizedDescription)"
        }
    }

    private enum AudioError: LocalizedError {
        case couldNotStart
        var errorDescription: String? { "iOS no pudo iniciar la reproducción." }
    }
}
