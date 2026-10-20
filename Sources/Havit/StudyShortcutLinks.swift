import Foundation

enum StudyShortcutLinks {
    static let startName = "Estudio Havit"
    static let stopName = "Finalizar Estudio Havit"

    static func start(until endDate: Date) -> URL {
        let formatter = ISO8601DateFormatter()
        return shortcut(name: startName, text: formatter.string(from: endDate), action: "enabled")
    }

    static var stop: URL { shortcut(name: stopName, text: nil, action: "disabled") }

    private static func shortcut(name: String, text: String?, action: String) -> URL {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"
        var items = [URLQueryItem(name: "name", value: name)]
        if let text {
            items += [URLQueryItem(name: "input", value: "text"), URLQueryItem(name: "text", value: text)]
        }
        items += [
            URLQueryItem(name: "x-success", value: "havit://focus/\(action)"),
            URLQueryItem(name: "x-error", value: "havit://focus/error"),
            URLQueryItem(name: "x-cancel", value: "havit://focus/cancelled")
        ]
        components.queryItems = items
        // All URL components are constants; query values are percent-encoded by Foundation.
        return components.url!
    }
}
