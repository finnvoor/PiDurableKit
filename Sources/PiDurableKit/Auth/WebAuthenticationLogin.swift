#if canImport(AuthenticationServices) && !os(tvOS)
import AuthenticationServices
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension LoginInteraction {
    /// Signs in with `ASWebAuthenticationSession`: the provider's page appears in a secure in-app browser sheet, and
    /// the sheet closes by itself once the provider redirects back to the app.
    ///
    /// ```swift
    /// try await models.login(to: .anthropic, interaction: .webAuthenticationSession())
    /// ```
    ///
    /// - Parameters:
    ///   - prefersEphemeralWebBrowserSession: Don't share cookies with Safari, so the user always signs in afresh.
    ///   - presentationAnchor: The window to present over; defaults to the key window.
    ///   - onDeviceCode: Called with the code of a device-code sign-in (GitHub Copilot). Defaults to copying it to the
    ///     pasteboard, so the user can paste it into the page.
    @MainActor
    public static func webAuthenticationSession(
        prefersEphemeralWebBrowserSession: Bool = false,
        presentationAnchor: ASPresentationAnchor? = nil,
        onDeviceCode: (@Sendable (String) -> Void)? = nil
    ) -> LoginInteraction {
        let anchor = WeakAnchor(presentationAnchor)
        return LoginInteraction(
            presentSignInPage: { url in
                try await WebAuthenticationPresenter.present(
                    url, prefersEphemeral: prefersEphemeralWebBrowserSession, anchor: anchor)
            },
            notify: { event in
                guard case .deviceCode(let code, _) = event else { return }
                if let onDeviceCode {
                    onDeviceCode(code)
                } else {
                    Task { @MainActor in copyToPasteboard(code) }
                }
            }
        )
    }
}

/// Holds the running session for cancellation; only touched on the main actor.
private final class SessionHolder: @unchecked Sendable {
    var session: ASWebAuthenticationSession?
}

private final class WeakAnchor: @unchecked Sendable {
    weak var window: ASPresentationAnchor?
    init(_ window: ASPresentationAnchor?) { self.window = window }
}

@MainActor
private func copyToPasteboard(_ text: String) {
    #if canImport(UIKit) && !os(visionOS)
    UIPasteboard.general.string = text
    #elseif canImport(UIKit)
    UIPasteboard.general.string = text
    #elseif canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}

@MainActor
private final class WebAuthenticationPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: WeakAnchor

    private init(anchor: WeakAnchor) {
        self.anchor = anchor
    }

    /// Never matched: provider redirects go to a loopback server inside the app, which ends the session.
    private static let callbackScheme = "pidurablekit-oauth"

    static func present(_ url: URL, prefersEphemeral: Bool, anchor: WeakAnchor) async throws {
        let presenter = WebAuthenticationPresenter(anchor: anchor)
        let holder = SessionHolder()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let completion: ASWebAuthenticationSession.CompletionHandler = { _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
                let created: ASWebAuthenticationSession
                if #available(iOS 17.4, macOS 14.4, visionOS 1.1, *) {
                    created = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme), completionHandler: completion)
                } else {
                    created = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme, completionHandler: completion)
                }
                created.presentationContextProvider = presenter
                created.prefersEphemeralWebBrowserSession = prefersEphemeral
                holder.session = created
                if Task.isCancelled || !created.start() {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            Task { @MainActor in holder.session?.cancel() }
        }
        _ = presenter
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            if let window = anchor.window { return window }
            #if canImport(UIKit)
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            if let window = active?.windows.first(where: \.isKeyWindow) ?? active?.windows.first { return window }
            return ASPresentationAnchor()
            #else
            return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
            #endif
        }
    }
}
#endif
