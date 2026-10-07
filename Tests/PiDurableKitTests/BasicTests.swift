import Foundation
import Testing
@testable import PiDurableKit

@Suite struct BasicTests {
    @Test func bundledVersions() async throws {
        let versions = try await Runtime.shared.bundledVersions()
        #expect(versions["piDurable"] == PiDurable.version)
    }

    @Test func promptWithFauxProvider() async throws {
        let models = Models(builtinProviders: false)
        let faux = FauxProvider()
        try await models.register(faux)
        try await faux.append(.text("Paris"))

        let harness = try await Harness.open(models: models)
        let root = try await harness.root(agent: AgentChange(model: faux.model))
        let answer = try await ask(root, "What is the capital of France?")
        #expect(answer.text == "Paris")
        try await harness.close()
    }
}

@Suite struct DocumentationTests {
    @Test func bundledDocumentationDescribesTheBundledVersion() throws {
        let readme = try String(contentsOf: PiDurable.documentation.appending(path: "README.md"), encoding: .utf8)
        #expect(readme.contains("defineExtension"))
        let types = try String(contentsOf: PiDurable.documentation.appending(path: "dist/harness/types.d.ts"), encoding: .utf8)
        #expect(types.contains("export interface ToolExecutionApi"))
        #expect(!types.contains("sourceMappingURL"))
    }
}

@Suite struct NoticesTests {
    @Test func noticesCoverTheBundledPackages() {
        let notices = PiDurable.thirdPartyNotices
        for package in ["@earendil-works/pi-durable@\(PiDurable.version)", "@earendil-works/pi-ai@", "openai@", "@anthropic-ai/sdk@", "@google/genai@", "typebox@"] {
            #expect(notices.contains(package), "\(package)")
        }
        #expect(notices.contains("Apache License"))
        #expect(notices.contains("Permission is hereby granted"))
    }
}

@Suite struct LaunchCostTests {
    /// Reports how long a fresh runtime takes to load the bundle and answer its first call, and to open a harness.
    @Test func measureStartup() async throws {
        let clock = ContinuousClock()
        let runtime = Runtime()
        let load = try await clock.measure { _ = try await runtime.bundledVersions() }
        let models = Models(builtinProviders: true, runtime: runtime)
        let open = try await clock.measure { _ = try await Harness.open(models: models) }
        print("PiDurableKit startup: bundle \(load), harness with built-in providers \(open)")
        #expect(load < .seconds(5))
    }
}
