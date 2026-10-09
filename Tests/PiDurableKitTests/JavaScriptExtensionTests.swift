import Foundation
import Testing
@testable import PiDurableKit

/// A pi-durable extension as a Node app would write it: a tool with a TypeBox schema, a section, and a hook.
let diceSource = #"""
const { defineExtension, defineTool, section, hook, ToolTask } = require("@earendil-works/pi-durable");
const { Type } = require("@earendil-works/pi-ai");

module.exports = defineExtension({
    name: "dice",
    tools: [
        defineTool({
            name: "roll",
            description: "Roll a die with the given number of sides",
            parameters: Type.Object({ sides: Type.Number() }),
            execute: async (args, api) => {
                api.output("rolling\n");
                return { content: [{ type: "text", text: `rolled a d${args.sides}: ${args.sides}` }], details: { sides: args.sides } };
            },
        }),
        defineTool({
            name: "inspect_globals",
            description: "Report what the extension can see",
            parameters: Type.Object({}),
            execute: async () => ({
                content: [{ type: "text", text: [typeof __native, typeof __bridge, typeof __runtime, typeof fetch].join(" ") }],
            }),
        }),
    ],
    sections: [section("dice", () => "Use the roll tool for dice.")],
    hooks: [hook(ToolTask, { beforeTool: (call) => (call.arguments.sides > 100 ? { block: "Too many sides" } : undefined) })],
});
"""#

@Suite struct JavaScriptExtensionTests {
    @Test func javaScriptExtensionsWorkLikeInNode() async throws {
        let setup = try await FauxSetup.make(extensions: [Extension("dice", javaScript: diceSource)])
        try await setup.faux.append(.toolCall("roll", ["sides": 20]))
        try await setup.faux.append(.toolCall("roll", ["sides": 1000]))
        try await setup.faux.append(.text("Done"))
        let root = try await setup.root()
        #expect(try await root.agent().tools == ["roll", "inspect_globals"])
        _ = try await ask(root, "Roll some dice")

        let results = try await root.view().entries.compactMap(\.toolResult)
        #expect(results.first?.text == "rolled a d20: 20")
        #expect(results.first?.details == ["sides": 20])
        #expect(results.last?.isError == true)
        #expect(results.last?.text.contains("Too many sides") == true)

        let (_, messages) = try await root.context()
        let prompt = messages.compactMap { message -> String? in
            guard case .system(let system) = message else { return nil }
            return ([system.text] + system.sections.values.compactMap { $0 }).joined(separator: "\n")
        }.joined()
        #expect(prompt.contains("Use the roll tool for dice."))
    }

    @Test func timersAcceptDelaysNodeAccepts() async throws {
        let source = #"""
        const { defineExtension, defineTool } = require("@earendil-works/pi-durable");
        const { Type } = require("@earendil-works/pi-ai");
        module.exports = defineExtension({
            name: "timers",
            tools: [defineTool({
                name: "arm",
                description: "Arm timers with extreme delays",
                parameters: Type.Object({}),
                execute: async () => {
                    for (const delay of [Infinity, NaN, -1, 1e300]) clearTimeout(setTimeout(() => {}, delay));
                    return { content: [{ type: "text", text: "armed" }] };
                },
            })],
        });
        """#
        let setup = try await FauxSetup.make(extensions: [Extension("timers", javaScript: source)])
        try await setup.faux.append(.toolCall("arm", [:]))
        try await setup.faux.append(.text("Done"))
        let root = try await setup.root()
        _ = try await ask(root, "Arm the timers")
        let results = try await root.view().entries.compactMap(\.toolResult)
        #expect(results.first?.text == "armed")
        try await setup.harness.close()
    }

    @Test func outOfRangeTimerDelaysFireAtOnceAsInNode() async throws {
        // Node runs a timer whose delay isn't 1 to 2³¹−1 ms after 1 ms, Infinity included.
        let source = #"""
        const { defineExtension, defineTool } = require("@earendil-works/pi-durable");
        const { Type } = require("@earendil-works/pi-ai");
        module.exports = defineExtension({
            name: "timers",
            tools: [defineTool({
                name: "wait",
                description: "Wait for timers with out-of-range delays",
                parameters: Type.Object({}),
                execute: async () => {
                    await Promise.all([Infinity, NaN, -1, 1e300].map((delay) => new Promise((resolve) => setTimeout(resolve, delay))));
                    return { content: [{ type: "text", text: "fired" }] };
                },
            })],
        });
        """#
        let setup = try await FauxSetup.make(extensions: [Extension("timers", javaScript: source)])
        try await setup.faux.append(.toolCall("wait", [:]))
        try await setup.faux.append(.text("Done"))
        let root = try await setup.root()
        try await withTimeout(5) { _ = try await ask(root, "Wait for the timers") }
        #expect(try await root.view().entries.compactMap(\.toolResult).first?.text == "fired")
        try await setup.harness.close()
    }

    @Test func timerDelaysAreClampedToWhatSwiftAccepts() {
        // The JavaScript side follows Node, so out-of-range delays never reach the host; its own guard is tested
        // directly.
        #expect(Engine.timerDelay(.nan) == 0)
        #expect(Engine.timerDelay(-1) == 0)
        #expect(Engine.timerDelay(250) == 250)
        #expect(Engine.timerDelay(.infinity) == Double(Int32.max))
        #expect(Engine.timerDelay(1e300) == Double(Int32.max))
    }

    @Test func extensionsCannotReachTheHostBridge() async throws {
        let setup = try await FauxSetup.make(extensions: [Extension("dice", javaScript: diceSource)])
        try await setup.faux.append(.toolCall("inspect_globals", [:]))
        try await setup.faux.append(.text("Done"))
        let root = try await setup.root()
        _ = try await ask(root, "Inspect")
        let result = try #require(try await root.view().entries.first { $0.kind == .toolResult }?.toolResult)
        #expect(result.text == "undefined undefined undefined function")
    }

    @Test func invalidModulesFailToInstall() async throws {
        let setup = try await FauxSetup.make()
        await #expect(throws: (any Error).self) {
            try await setup.harness.install(Extension("dice", javaScript: "module.exports = { tools: [] };"))
        }
        await #expect(throws: (any Error).self) {
            try await setup.harness.install(Extension("other", javaScript: diceSource))
        }
        await #expect(throws: (any Error).self) {
            try await setup.harness.install(Extension("x", javaScript: #"require("node:fs");"#))
        }
        await #expect(throws: (any Error).self) {
            try await setup.harness.install(Extension("x", javaScript: "this is not javascript"))
        }
        #expect(try await setup.harness.installedExtensions().isEmpty)
    }

    /// The app-level flow: the agent writes an extension with the coding tools, a Swift tool installs it, and the next
    /// request of the same run already offers its tools.
    @Test func agentWrittenExtensionsLoadInTheSameRun() async throws {
        let directory = temporaryDirectory()
        struct LoadArguments: Codable, Sendable { var path: String; var name: String }
        let loader = Tool(
            "load_extension", description: "Load a pi-durable extension from a JavaScript file",
            parameters: .object(["path": .string, "name": .string])
        ) { (arguments: LoadArguments, call) -> String in
            let file = directory.appending(path: String(arguments.path.drop { $0 == "/" }))
            let source = try String(contentsOf: file, encoding: .utf8)
            try await call.harness.install(Extension(arguments.name, javaScript: source, sourceURL: file))
            return "Loaded \(arguments.name)"
        }
        let models = Models(builtinProviders: false)
        let faux = FauxProvider()
        try await models.register(faux)
        let harness = try await Harness.open(
            models: models, extensions: [.codingTools(), Extension("loader", tools: [loader])],
            environment: .directory(directory))
        let root = try await harness.root(agent: AgentChange(model: faux.model))

        let greeter = #"""
        const { defineExtension, defineTool } = require("@earendil-works/pi-durable");
        module.exports = defineExtension({
            name: "greeter",
            tools: [defineTool({
                name: "greet",
                description: "Greet someone",
                parameters: { type: "object", properties: { who: { type: "string" } }, required: ["who"] },
                execute: async (args, api, context) => {
                    const note = await api.env.readTextFile("/note.txt", context);
                    return { content: [{ type: "text", text: `Hello, ${args.who}! ${note.ok ? note.value : ""}` }] };
                },
            })],
        });
        """#
        try await faux.append(.toolCall("write", ["path": "/note.txt", "content": "(from the sandbox)"]))
        try await faux.append(.toolCall("write", ["path": "/extensions/greeter.js", "content": .string(greeter)]))
        try await faux.append(.toolCall("load_extension", ["path": "/extensions/greeter.js", "name": "greeter"]))
        try await faux.append(.toolCall("greet", ["who": "Ada"]))
        try await faux.append(.text("Done"))
        _ = try await withTimeout { try await ask(root, "Write and use a greeting extension") }

        let results = try await root.view().entries.compactMap(\.toolResult)
        #expect(results.map(\.isError) == [false, false, false, false], "\(results.map(\.text))")
        #expect(results.last?.text == "Hello, Ada! (from the sandbox)")
        #expect(try await harness.installedExtensions().contains("greeter"))
        try await harness.close()
    }
}
