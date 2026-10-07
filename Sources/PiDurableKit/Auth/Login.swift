import Foundation
import os

/// A question an OAuth sign-in asks.
public enum LoginPrompt: Sendable, Hashable {
    public struct Option: Sendable, Hashable, Identifiable {
        public let id: String
        public let label: String
    }

    case text(message: String, placeholder: String?)
    case secret(message: String, placeholder: String?)
    case select(message: String, options: [Option])
    /// Paste a code or redirect URL by hand. Sign-ins that also listen on a loopback redirect cancel this prompt as
    /// soon as the browser reaches it, so the usual answer is to wait.
    case manualCode(message: String, placeholder: String?)

    public var message: String {
        switch self {
        case .text(let message, _), .secret(let message, _), .select(let message, _), .manualCode(let message, _): message
        }
    }

    init(json: JSONValue) {
        let message = json["message"]?.stringValue ?? ""
        let placeholder = json["placeholder"]?.stringValue
        switch json["type"]?.stringValue {
        case "secret": self = .secret(message: message, placeholder: placeholder)
        case "select":
            let options = (json["options"]?.arrayValue ?? []).map {
                Option(id: $0["id"]?.stringValue ?? "", label: $0["label"]?.stringValue ?? $0["id"]?.stringValue ?? "")
            }
            self = .select(message: message, options: options)
        case "manual_code": self = .manualCode(message: message, placeholder: placeholder)
        default: self = .text(message: message, placeholder: placeholder)
        }
    }

    /// The answer an app without custom UI gives: the browser method of a select, an empty text (for example
    /// "GitHub Enterprise domain, blank for github.com"), and waiting for the loopback redirect instead of a pasted code.
    public func defaultAnswer() async throws -> String {
        switch self {
        case .select(_, let options):
            guard let option = options.first(where: { $0.id.localizedCaseInsensitiveContains("browser") }) ?? options.first else {
                throw PiDurableError.runtime("No sign-in option to choose")
            }
            return option.id
        case .text:
            return ""
        case .secret(let message, _):
            throw PiDurableError.runtime("Sign-in needs input this app cannot provide: \(message)")
        case .manualCode:
            // Wait until the sign-in completes through its redirect, which cancels this prompt.
            try await Task.sleep(for: .seconds(60 * 60 * 24))
            throw CancellationError()
        }
    }
}

/// Something an OAuth sign-in reports.
public enum LoginEvent: Sendable, Hashable {
    case info(message: String, links: [URL])
    /// The page to sign in on; ``LoginInteraction/presentSignInPage`` shows it.
    case authorizationURL(URL, instructions: String?)
    /// A device-code sign-in: enter `userCode` at `verificationURL`.
    case deviceCode(userCode: String, verificationURL: URL)
    case progress(String)

    init?(json: JSONValue) {
        switch json["type"]?.stringValue {
        case "info":
            let links = (json["links"]?.arrayValue ?? []).compactMap { $0["url"]?.stringValue.flatMap(URL.init(string:)) }
            self = .info(message: json["message"]?.stringValue ?? "", links: links)
        case "auth_url":
            guard let url = json["url"]?.stringValue.flatMap(URL.init(string:)) else { return nil }
            self = .authorizationURL(url, instructions: json["instructions"]?.stringValue)
        case "device_code":
            guard let url = json["verificationUri"]?.stringValue.flatMap(URL.init(string:)) else { return nil }
            self = .deviceCode(userCode: json["userCode"]?.stringValue ?? "", verificationURL: url)
        case "progress":
            self = .progress(json["message"]?.stringValue ?? "")
        default:
            return nil
        }
    }
}

/// How an OAuth sign-in talks to the user (pi-ai `AuthInteraction`).
///
/// Most apps use ``webAuthenticationSession(prefersEphemeralWebBrowserSession:presentationAnchor:onDeviceCode:)``.
public struct LoginInteraction: Sendable {
    /// Shows a provider's sign-in page and returns (or throws) when the user dismisses it. It is cancelled when the
    /// sign-in completes, and should then dismiss the page. Provider redirects reach a loopback server inside the
    /// app, so the page needs no callback URL scheme.
    public var presentSignInPage: @Sendable (URL) async throws -> Void
    /// Answers a question. Defaults to ``LoginPrompt/defaultAnswer()``.
    public var prompt: @Sendable (LoginPrompt) async throws -> String
    /// Observes progress. Device-code sign-ins report the code to enter here.
    public var notify: @Sendable (LoginEvent) -> Void

    public init(
        presentSignInPage: @escaping @Sendable (URL) async throws -> Void,
        prompt: @escaping @Sendable (LoginPrompt) async throws -> String = { try await $0.defaultAnswer() },
        notify: @escaping @Sendable (LoginEvent) -> Void = { _ in }
    ) {
        self.presentSignInPage = presentSignInPage
        self.prompt = prompt
        self.notify = notify
    }
}

/// A provider that supports OAuth sign-in, such as a Claude or ChatGPT subscription.
public struct OAuthInfo: Decodable, Sendable, Hashable {
    /// The sign-in's display name, such as "Anthropic (Claude Pro/Max)".
    public let name: String
    /// The provider's preferred button title, such as "Sign in with ChatGPT".
    public let label: String?
    /// Whether it signs in to a subscription rather than minting an API key.
    public let isSubscription: Bool
}

/// One running sign-in: routes prompts and events, and owns the sign-in page.
final class LoginSession: Sendable {
    private struct State {
        var page: Task<Void, Never>?
        var finished = false
        var abandon: (@Sendable () -> Void)?
    }

    let interaction: LoginInteraction
    private let loopbackRequests: @Sendable () -> Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(interaction: LoginInteraction, loopbackRequests: @escaping @Sendable () -> Int) {
        self.interaction = interaction
        self.loopbackRequests = loopbackRequests
    }

    func onAbandon(_ abandon: @escaping @Sendable () -> Void) {
        state.withLock { $0.abandon = abandon }
    }

    func notify(_ event: LoginEvent) {
        interaction.notify(event)
        switch event {
        case .authorizationURL(let url, _): present(url, abandonOnDismiss: true)
        case .deviceCode(_, let url): present(url, abandonOnDismiss: false)
        default: break
        }
    }

    private func present(_ url: URL, abandonOnDismiss: Bool) {
        let interaction = interaction
        let requestsBefore = loopbackRequests()
        let task = Task { [weak self] in
            do {
                try await interaction.presentSignInPage(url)
            } catch {}
            guard let self, abandonOnDismiss, !Task.isCancelled else { return }
            // The redirect may still be landing when the user taps Done on the success page.
            try? await Task.sleep(for: .seconds(1))
            guard self.loopbackRequests() == requestsBefore else { return }
            let abandon = self.state.withLock { $0.finished ? nil : $0.abandon }
            abandon?()
        }
        let previous = state.withLock { state -> Task<Void, Never>? in
            defer { state.page = task }
            return state.page
        }
        previous?.cancel()
    }

    /// Ends the sign-in and dismisses its page.
    func finish() {
        let page = state.withLock { state -> Task<Void, Never>? in
            state.finished = true
            return state.page
        }
        page?.cancel()
    }
}
