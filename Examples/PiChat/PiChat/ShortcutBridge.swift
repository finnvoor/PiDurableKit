import Foundation
import Observation
import PiDurableKit
import UserNotifications

/// Runs the person's shortcuts for the agent, through the "PiChat Bridge" shortcut and its notification automation.
///
/// Apps can't run shortcuts themselves, but in iOS 27 a Shortcuts automation can run when an app posts a notification
/// (the approach of Deflector, https://github.com/Cizzuk/Deflector). PiChat posts a notification whose title is the
/// command, whose subtitle is a request ID, and whose body is the shortcut's name. The automation runs that shortcut
/// with the request's input (fetched with an App Intent) and hands the output back with another App Intent, which
/// resumes the waiting tool call. Listing shortcuts works the same way with "Get My Shortcuts".
///
/// The agent can only run the shortcuts the person allowed in the Shortcuts settings.
@MainActor @Observable
final class ShortcutBridge: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ShortcutBridge()

    /// The notification titles the automation responds to; they must match the shortcut (Shortcuts/make-bridge-shortcut.py).
    enum Command: String {
        case run = "Run Shortcut"
        case list = "List Shortcuts"
    }

    /// The person's shortcuts, as of the last refresh.
    private(set) var shortcuts: [String] = UserDefaults.standard.stringArray(forKey: Keys.shortcuts) ?? [] {
        didSet { UserDefaults.standard.set(shortcuts, forKey: Keys.shortcuts) }
    }
    /// The shortcuts the agent may run.
    var allowed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: Keys.allowed) ?? []) {
        didSet { UserDefaults.standard.set(allowed.sorted(), forKey: Keys.allowed) }
    }
    /// Whether the bridge shortcut has called PiChat at least once (it does at every run).
    private(set) var connected = UserDefaults.standard.bool(forKey: Keys.connected) {
        didSet { UserDefaults.standard.set(connected, forKey: Keys.connected) }
    }
    private(set) var notificationsAllowed = false
    /// Whether PiChat's notifications skip the Lock Screen and banners (Notification Center only), so bridge requests
    /// stay out of sight. Only the person can change this, in Settings.
    private(set) var notificationsQuiet = false

    /// The signed shortcut to add to the Shortcuts app.
    static let bridgeShortcut = Bundle.main.url(forResource: "PiChat Bridge", withExtension: "shortcut")!

    private struct Request {
        let name: String
        let input: String
        let continuation: CheckedContinuation<String, Error>
    }

    private var requests: [String: Request] = [:]
    private var listRequests: [CheckedContinuation<[String], Error>] = []
    private static let timeout: Duration = .seconds(120)

    nonisolated private enum Keys {
        static let shortcuts = "PiChat.shortcuts"
        static let allowed = "PiChat.allowedShortcuts"
        static let connected = "PiChat.bridgeConnected"
    }

    /// Call at launch, before any notification arrives.
    func start() {
        UNUserNotificationCenter.current().delegate = self
        Task { await refreshNotificationStatus() }
    }

    func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsAllowed = settings.authorizationStatus == .authorized
        notificationsQuiet = notificationsAllowed && settings.lockScreenSetting != .enabled && settings.alertStyle == .none
    }

    func requestNotifications() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
        await refreshNotificationStatus()
    }

    /// Runs a shortcut and returns its output as text.
    func run(_ name: String, input: String) async throws -> String {
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                requests[id] = Request(name: name, input: input, continuation: continuation)
                Task {
                    do {
                        try await post(.run, subtitle: id, body: name)
                    } catch {
                        finish(id, with: .failure(error))
                        return
                    }
                    try? await Task.sleep(for: Self.timeout)
                    finish(id, with: .failure(BridgeError.noAnswer(name)))
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(id, with: .failure(CancellationError())) }
        }
    }

    /// Asks the bridge for the list of shortcuts.
    func refreshShortcuts() async throws {
        let list = try await withCheckedThrowingContinuation { continuation in
            listRequests.append(continuation)
            Task {
                do {
                    try await post(.list, subtitle: UUID().uuidString, body: "")
                } catch {
                    finishList(with: .failure(error))
                    return
                }
                try? await Task.sleep(for: .seconds(20))
                finishList(with: .failure(BridgeError.noList))
            }
        }
        shortcuts = list.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        allowed.formIntersection(shortcuts)
    }

    // MARK: Called by the bridge shortcut's App Intents

    func markConnected() {
        print("PiChat bridge: connected")
        connected = true
        // The automation has read the request by now (it calls this first), so clear it from Notification Center.
        Task { await removeDeliveredRequests() }
    }

    func input(for id: String) -> String {
        print("PiChat bridge: input requested for \(id) (\(requests[id] == nil ? "unknown" : "pending"))")
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        return requests[id]?.input ?? ""
    }

    func complete(_ id: String, output: String) {
        print("PiChat bridge: output for \(id): \(output.prefix(200))")
        finish(id, with: .success(output))
    }

    func receive(_ list: [String]) {
        print("PiChat bridge: \(list.count) shortcuts")
        finishList(with: .success(list))
    }

    // MARK: Notifications

    private func post(_ command: Command, subtitle: String, body: String) async throws {
        guard await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized else {
            throw BridgeError.notificationsOff
        }
        let content = UNMutableNotificationContent()
        content.title = command.rawValue
        content.subtitle = subtitle
        content.body = body
        content.sound = nil
        // Passive: no sound, and it doesn't light up the screen. It is still delivered, which is all the automation needs.
        content.interruptionLevel = .passive
        print("PiChat bridge: posting \(command.rawValue) \(subtitle) \(body)")
        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: subtitle, content: content, trigger: nil))
    }

    /// Removes delivered bridge requests, which have served their purpose once the automation is running.
    private func removeDeliveredRequests() async {
        let center = UNUserNotificationCenter.current()
        let titles = Set([Command.run.rawValue, Command.list.rawValue])
        let delivered = await center.deliveredNotifications()
        center.removeDeliveredNotifications(
            withIdentifiers: delivered.filter { titles.contains($0.request.content.title) }.map(\.request.identifier))
    }

    private func finish(_ id: String, with result: Result<String, Error>) {
        guard let request = requests.removeValue(forKey: id) else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        request.continuation.resume(with: result)
    }

    private func finishList(with result: Result<[String], Error>) {
        let waiting = listRequests
        listRequests = []
        for continuation in waiting { continuation.resume(with: result) }
        if case .success = result { connected = true }
    }

    /// Bridge notifications are delivered to Notification Center (where the automation sees them) without a banner,
    /// also while PiChat is open.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.list]
    }

    enum BridgeError: LocalizedError {
        case notificationsOff
        case noAnswer(String)
        case noList
        case notAllowed(String)

        var errorDescription: String? {
            switch self {
            case .notificationsOff:
                "PiChat can't run shortcuts: notifications are off. Turn them on in PiChat's Shortcuts settings."
            case .noAnswer(let name):
                "\"\(name)\" did not answer within two minutes. The PiChat Bridge automation may be off, or the shortcut failed or is waiting for input."
            case .noList:
                "The PiChat Bridge shortcut did not answer. Check that it is installed and its automation is on."
            case .notAllowed(let name):
                "The user has not allowed \"\(name)\". They can allow it in PiChat's Shortcuts settings."
            }
        }
    }
}

extension ShortcutBridge {
    /// The agent's tools for shortcuts. The allowed list is read at each use, so changes apply to the next step.
    nonisolated static var agentExtension: Extension {
        Extension("shortcuts") {
            PromptSection("shortcuts") { _ in
                let allowed = allowedNames()
                guard !allowed.isEmpty else { return nil }
                return """
                    You can run the user's Shortcuts on their device with run_shortcut. They allowed these: \
                    \(allowed.map { "\"\($0)\"" }.joined(separator: ", ")). A shortcut receives the input text you \
                    pass and returns its output as text. Shortcuts can read and change things on the device and in \
                    other apps, so run one only when it helps with what the user asked.
                    """
            }
            Tool("list_shortcuts", description: "The user's Shortcuts that you are allowed to run", replay: .safe) { _ in
                let allowed = allowedNames()
                return allowed.isEmpty ? "The user has not allowed any shortcuts." : allowed.joined(separator: "\n")
            }
            Tool(
                "run_shortcut",
                description: "Run one of the user's Shortcuts and return its output",
                parameters: .object([
                    "name": .string("The shortcut's exact name, from list_shortcuts"),
                    "input": .string("Text passed to the shortcut as its input").optional,
                ])
            ) { (arguments: RunArguments, _) -> String in
                guard allowedNames().contains(arguments.name) else { throw BridgeError.notAllowed(arguments.name) }
                let output = try await ShortcutBridge.shared.run(arguments.name, input: arguments.input ?? "")
                return output.isEmpty ? "\(arguments.name) finished with no output." : output
            }
        }
    }

    nonisolated struct RunArguments: Decodable, Sendable {
        var name: String
        var input: String?
    }

    nonisolated static func allowedNames() -> [String] {
        UserDefaults.standard.stringArray(forKey: Keys.allowed) ?? []
    }
}
