import AppIntents

// The App Intents the "PiChat Bridge" shortcut calls. They are hidden from the Shortcuts action list; the bridge
// shortcut refers to them by type name (Shortcuts/make-bridge-shortcut.py), so keep the names and parameters in sync.

/// Called at the start of every bridge run, and by running the shortcut once by hand to grant it access to PiChat.
struct BridgeConnectedIntent: AppIntent {
    static let title: LocalizedStringResource = "PiChat Bridge Connected"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .background

    @MainActor func perform() async throws -> some IntentResult {
        ShortcutBridge.shared.markConnected()
        return .result()
    }
}

/// The input of a pending request to run a shortcut.
struct ShortcutInputIntent: AppIntent {
    static let title: LocalizedStringResource = "PiChat Shortcut Input"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Request")
    var request: String

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: ShortcutBridge.shared.input(for: request))
    }
}

/// The output of a shortcut PiChat asked to run.
struct ShortcutOutputIntent: AppIntent {
    static let title: LocalizedStringResource = "PiChat Shortcut Output"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Request")
    var request: String

    @Parameter(title: "Output")
    var output: String?

    @MainActor func perform() async throws -> some IntentResult {
        ShortcutBridge.shared.complete(request, output: output ?? "")
        return .result()
    }
}

/// The person's shortcuts, from "Get My Shortcuts".
struct ShortcutListIntent: AppIntent {
    static let title: LocalizedStringResource = "PiChat Shortcut List"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Shortcuts")
    var shortcuts: [String]

    @MainActor func perform() async throws -> some IntentResult {
        ShortcutBridge.shared.receive(shortcuts)
        return .result()
    }
}
