import Foundation
import PiDurableKit

/// Lets the agent write its own pi-durable extensions in JavaScript and load them into the running session.
///
/// This is app policy, built on `Extension(_:javaScript:)`: the files live in the agent's workspace, a `load_extension`
/// tool installs them, and the list of loaded extensions is kept so they are installed again at launch (pending tool
/// calls of an extension resume only once it is installed). The code is not sandboxed, as in pi-durable itself.
nonisolated struct AgentExtensions: Sendable {
    /// The agent's sandboxed workspace; it sees this directory as `/`.
    let workspace: URL
    /// Loaded extensions by name, with their workspace paths.
    let manifest: URL

    init(directory: URL) {
        workspace = directory.appending(path: "Workspace")
        manifest = directory.appending(path: "extensions.json")
    }

    /// The extensions loaded in earlier launches.
    func installed() -> [Extension] {
        loaded().compactMap { name, path in
            let file = file(at: path)
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return Extension(name, javaScript: source, sourceURL: file)
        }
    }

    /// Copies the bundled pi-durable documentation to `/docs/pi-durable` in the workspace, matching the running version.
    func installDocumentation() throws {
        let target = workspace.appending(path: "docs/pi-durable")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: PiDurable.documentation, to: target)
    }

    /// The `load_extension` tool, and a pointer to the documentation, the way pi points its agent at pi's docs.
    var loader: Extension {
        let extensions = self
        return Extension("extension-loader") {
            PromptSection("extensions", text: """
                You can give yourself new tools, hooks, and prompt sections by writing pi-durable \(PiDurable.version) \
                extensions in JavaScript. Before writing one, read /docs/pi-durable/README.md (Extensions, Tools, Hooks, \
                Your Own State) and the type declarations it refers to under /docs/pi-durable/dist (start with \
                index.d.ts and harness/types.d.ts). The README's links to test/examples point to files that are not \
                included; the README and types are all there is.

                Write a CommonJS module to /extensions/<name>.js whose module.exports is defineExtension({ name, … }). \
                It can require "@earendil-works/pi-durable", "@earendil-works/pi-durable/tools", \
                "@earendil-works/pi-durable/env", "@earendil-works/pi-ai" (for Type), and \
                "@earendil-works/chord/context". fetch() is available; files go through api.env (this workspace). \
                Then call load_extension; its tools are available from your next step on.
                """)
            Tool(
                "load_extension",
                description: "Load (or reload) a pi-durable extension from a JavaScript file in the workspace",
                parameters: .object([
                    "path": .string("Workspace path of the module, such as /extensions/weather.js"),
                    "name": .string("The extension name the module defines"),
                ])
            ) { (arguments: LoadArguments, call) -> ToolResult in
                let file = extensions.file(at: arguments.path)
                let source = try String(contentsOf: file, encoding: .utf8)
                try await call.harness.install(Extension(arguments.name, javaScript: source, sourceURL: file))
                try extensions.record(arguments.name, path: arguments.path)
                // Resolve the conversation's agent again, so the result shows what the extension added.
                let agent = try await call.harness.conversation(call.conversationId)?.agent()
                let selected = agent?.extensions.contains(arguments.name) == true
                return .text(
                    "Loaded \(arguments.name). " + (selected
                        ? "Tools now offered: \(agent?.tools.joined(separator: ", ") ?? "")."
                        : "This conversation does not select it; configure its extensions to use it."))
            }
        }
    }

    struct LoadArguments: Codable, Sendable {
        var path: String
        var name: String
    }

    private func file(at path: String) -> URL {
        workspace.appending(path: String(path.drop { $0 == "/" }))
    }

    private func loaded() -> [String: String] {
        guard let data = try? Data(contentsOf: manifest) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func record(_ name: String, path: String) throws {
        var all = loaded()
        all[name] = path
        try JSONEncoder().encode(all).write(to: manifest)
    }
}
