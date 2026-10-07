import PiDurableKit
import SwiftUI

@main
struct PiChatApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

extension ProviderInfo {
    /// The sign-in button title, such as "Sign in with ChatGPT".
    var signInTitle: String { oauth?.label ?? "Sign in to \(name)" }
}

/// The app's agent: models with Keychain credentials, and a harness on SQLite.
@MainActor @Observable
final class AppModel {
    let models = Models(credentials: .keychain)
    private(set) var conversation: Conversation?
    private(set) var signedIn: [ProviderID: Credential.Kind] = [:]
    private(set) var availableModels: [ModelInfo] = []
    /// Every provider pi can sign in to with OAuth, from pi-ai's catalog.
    private(set) var loginProviders: [ProviderInfo] = []
    private(set) var signingIn: ProviderID?
    var model: ModelRef?
    var status: String?
    var showingSettings = false
    /// `-demo`: a scripted model and in-memory storage, for trying the UI without an account.
    let demo = ProcessInfo.processInfo.arguments.contains("-demo")

    private let backgroundRun = BackgroundRun()
    private static let modelKey = "PiChat.model"

    static let assistant = Extension("assistant") {
        PromptSection("preamble", tag: false, text: "You are a concise assistant in an iPhone app.")
        Tool("current_time", description: "The current date and time") { _ in
            Date.now.formatted(date: .complete, time: .standard)
        }
    }

    init() {
        ShortcutBridge.shared.start()
        if let stored = UserDefaults.standard.string(forKey: Self.modelKey)?.split(separator: "/", maxSplits: 1),
            stored.count == 2
        {
            model = ModelRef(provider: ProviderID(String(stored[0])), modelId: String(stored[1]))
        }
    }

    func start() async {
        do {
            let clock = ContinuousClock()
            let load = try await clock.measure { _ = try await Runtime.shared.bundledVersions() }
            print("PiChat startup: pi-durable \(PiDurable.version) loaded in \(load)")
            await refreshAccounts()
            let directory = URL.applicationSupportDirectory.appending(path: "PiChat")
            let agentExtensions = AgentExtensions(directory: directory)
            try agentExtensions.installDocumentation()
            if demo { return try await startDemo(extensions: [Self.assistant]) }
            let harness = try await Harness.open(
                .sqlite(at: directory.appending(path: "agent.sqlite")), models: models,
                extensions: [Self.assistant, .codingTools(), agentExtensions.loader, ShortcutBridge.agentExtension],
                environment: .directory(agentExtensions.workspace), resume: false)
            // Reinstall the agent's extensions before resuming, so their pending tool calls can continue. One that no
            // longer loads (the agent may have rewritten its file) is skipped rather than blocking the app.
            for agentExtension in agentExtensions.installed() {
                try? await harness.install(agentExtension)
            }
            try await harness.resume()
            conversation = try await harness.root(agent: AgentChange(model: model))
        } catch {
            status = error.localizedDescription
        }
    }

    private func startDemo(extensions: [Extension]) async throws {
        let faux = FauxProvider(models: [.init(id: "faux-1", contextWindow: 100_000_000)], tokensPerSecond: PerformanceLog.enabled ? 200 : 30)
        try await models.register(faux)
        model = faux.model
        let harness = try await Harness.open(.memory, models: models, extensions: extensions)
        let conversation = try await harness.root(agent: AgentChange(model: faux.model))
        self.conversation = conversation
        if let exchanges = PerformanceLog.exchanges {
            try await PerformanceLog.run(conversation, faux: faux, exchanges: exchanges)
            return
        }
        try await faux.append(
            .thinking("The user wants today's schedule. I'll check the time first, then look at what's coming up."),
            .toolCall("current_time", [:]))
        try await faux.append(.text(
            "It's a quiet afternoon: nothing until **4 pm**, when you're meeting Sam for coffee at *Blue Bottle*."))
        try await faux.append(.text("Done. I sent Sam: “Running about 10 minutes late, see you soon!”"))
        try await faux.append(.text("Here's the café: https://bluebottlecoffee.com"))
        try await faux.append(.text("☕️"))
        for text in ["What's on my calendar today?", "Can you text Sam that I'll be 10 minutes late?", "Where is it again?", "Thanks!"] {
            try await Task.sleep(for: .seconds(1.5))
            _ = try await conversation.submit(text).wait()
        }
    }

    func refreshAccounts() async {
        if loginProviders.isEmpty {
            loginProviders = ((try? await models.providers()) ?? [])
                .filter { $0.oauth != nil }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        var result: [ProviderID: Credential.Kind] = [:]
        for provider in (try? await models.credentials.providers()) ?? [] {
            result[provider] = try? await models.credential(for: provider)?.kind
        }
        signedIn = result
        var available: [ModelInfo] = []
        for provider in result.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            available += (try? await models.models(for: provider)) ?? []
        }
        availableModels = available
    }

    func signIn(to provider: ProviderInfo) async {
        signingIn = provider.id
        status = "Signing in to \(provider.name)…"
        defer { signingIn = nil }
        do {
            try await models.login(
                to: provider.id,
                interaction: LoginInteraction.webAuthenticationSession().logging { event in
                    // Visible with `xcrun devicectl device process launch --console`.
                    print("PiChat login event: \(event)")
                })
            status = "Signed in to \(provider.name)"
            await refreshAccounts()
            // Switch to the provider's flagship: its priciest model (pi-ai has no per-provider default).
            let catalog = availableModels.filter { $0.provider == provider.id }
            if model?.provider != provider.id,
                let flagship = catalog.max(by: { $0.cost.output < $1.cost.output }) ?? catalog.first
            {
                await use(flagship.ref)
            }
        } catch is CancellationError {
            status = nil
        } catch PiDurableError.cancelled {
            status = nil
        } catch {
            // pi-ai's messages can carry a JavaScript stack; show the first part.
            status = "Sign-in failed: \(error.localizedDescription.prefix(240))"
        }
        print("PiChat login finished: \(status ?? "cancelled")")
    }

    func signOut(of provider: ProviderID) async {
        try? await models.logout(from: provider)
        await refreshAccounts()
    }

    func setAPIKey(_ key: String, for provider: ProviderID) async {
        do {
            try await models.setAPIKey(key, for: provider)
            await refreshAccounts()
            print("PiChat stored API key for \(provider): \(signedIn[provider].map { "\($0)" } ?? "missing")")
        } catch {
            status = error.localizedDescription
            print("PiChat could not store API key: \(error)")
        }
    }

    func use(_ model: ModelRef) async {
        self.model = model
        UserDefaults.standard.set("\(model.provider)/\(model.modelId)", forKey: Self.modelKey)
        do {
            try await conversation?.configure(AgentChange(model: model))
        } catch {
            status = error.localizedDescription
        }
    }

    /// Sends a message, and keeps the app running in the background until the reply is done.
    func send(_ text: String) async {
        guard let conversation else { return }
        do {
            let submission = try await conversation.submit(text)
            backgroundRun.cover(submission, in: conversation, prompt: text)
        } catch {
            status = error.localizedDescription
        }
    }

    func newChat() async {
        try? await conversation?.reset()
    }
}

extension LoginInteraction {
    /// The same interaction, also reporting events to `log`.
    func logging(_ log: @escaping @Sendable (LoginEvent) -> Void) -> LoginInteraction {
        var copy = self
        let notify = notify
        copy.notify = { event in
            log(event)
            notify(event)
        }
        return copy
    }
}
