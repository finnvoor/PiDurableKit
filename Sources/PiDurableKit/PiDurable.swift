import Foundation

/// Information about the bundled pi-durable.
public enum PiDurable {
    /// pi-durable's documentation for the bundled ``version``, as its npm package ships it: `README.md` and the
    /// TypeScript declarations under `dist/` (start with `dist/index.d.ts`).
    ///
    /// Give it to an agent that writes JavaScript extensions, for example by copying it into its workspace and pointing
    /// a prompt section at it, the way pi points its agent at pi's own docs.
    public static let documentation: URL = Bundle.module.url(forResource: "Documentation", withExtension: nil)!
        .appending(path: "pi-durable", directoryHint: .isDirectory)

    /// The license notices of every open source package bundled in PiDurableKit's JavaScript (pi-durable, pi-ai, the
    /// provider SDKs, and their dependencies). Their licenses require shipping these notices with your app, for
    /// example on an acknowledgements screen.
    public static let thirdPartyNotices: String = {
        let url = Bundle.module.url(forResource: "ThirdPartyNotices", withExtension: "txt")!
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()
}
