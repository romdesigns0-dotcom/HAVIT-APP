import ActivityKit
import Foundation

public struct FocusActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var timerEnd: Date
        public var pendingTasks: Int
        public var focusActive: Bool

        public init(timerEnd: Date, pendingTasks: Int, focusActive: Bool = false) {
            self.timerEnd = timerEnd
            self.pendingTasks = pendingTasks
            self.focusActive = focusActive
        }

        private enum CodingKeys: String, CodingKey { case timerEnd, pendingTasks, focusActive }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            timerEnd = try values.decode(Date.self, forKey: .timerEnd)
            pendingTasks = try values.decode(Int.self, forKey: .pendingTasks)
            focusActive = try values.decodeIfPresent(Bool.self, forKey: .focusActive) ?? false
        }
    }

    public var startedAt: Date
    public var sessionLength: Int
    public var projectTitle: String
    public var projectSubtitle: String

    public init(
        startedAt: Date = .now,
        sessionLength: Int = 300,
        projectTitle: String = "Diseño CAD",
        projectSubtitle: String = "Joyería 1"
    ) {
        self.startedAt = startedAt
        self.sessionLength = sessionLength
        self.projectTitle = projectTitle
        self.projectSubtitle = projectSubtitle
    }

    private enum CodingKeys: String, CodingKey {
        case startedAt, sessionLength, projectTitle, projectSubtitle
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        sessionLength = try values.decode(Int.self, forKey: .sessionLength)
        projectTitle = try values.decodeIfPresent(String.self, forKey: .projectTitle) ?? "Diseño CAD"
        projectSubtitle = try values.decodeIfPresent(String.self, forKey: .projectSubtitle) ?? "Joyería 1"
    }
}
