import Foundation
import os
import Testing
@testable import PiDurableKit

/// A harness clock and timers the test moves by hand (pi-durable `HarnessOptions.now` and `setTimer`).
final class ManualClock: Sendable {
    private struct Pending {
        let id: Int
        let due: Date
        let fire: @Sendable () -> Void
    }

    private struct State {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var next = 1
        var pending: [Pending] = []
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    var now: Date { state.withLock { $0.now } }

    var clock: @Sendable () -> Date { { [self] in now } }

    var timer: HarnessTimer {
        HarnessTimer { [self] delay, _, fire in
            let id = state.withLock { state -> Int in
                defer { state.next += 1 }
                state.pending.append(Pending(id: state.next, due: state.now.addingTimeInterval(delay.milliseconds / 1000), fire: fire))
                return state.next
            }
            return { [self] in state.withLock { $0.pending.removeAll { $0.id == id } } }
        }
    }

    /// Moves the clock and fires every timer that is due.
    func advance(by seconds: TimeInterval) {
        let due = state.withLock { state -> [Pending] in
            state.now = state.now.addingTimeInterval(seconds)
            let due = state.pending.filter { $0.due <= state.now }
            state.pending.removeAll { $0.due <= state.now }
            return due
        }
        for timer in due { timer.fire() }
    }
}

/// pi-durable 1.4.0: durable sleeps, phase timers, report details, the restart limit, failed runs, per-model
/// compaction, swapping models, the tool clock, telemetry, and the new modules for JavaScript extensions.
@Suite struct PiDurable14Tests {
    @Test func sleepingTasksWakeOnTheHarnessClock() async throws {
        let clock = ManualClock()
        let nap = TaskType<Empty, At, String>("test.nap", version: 1, initial: { _ in At(phase: "sleep") }, abort: abortTask) {
            Phase("sleep") { run in
                try await run.sleep(until: try await run.now().addingTimeInterval(3600), then: At(phase: "again"))
            }
            // Sleeping together with other writes: returned from a commit.
            Phase("again") { run in
                let until = try await run.now().addingTimeInterval(60)
                try await run.commit { _, _ in .sleeping(At(phase: "woke"), until: until) }
            }
            Phase("woke") { run in
                let now = try await run.now()
                try await run.commit { _, _ in .completed("woke at \(Int(now.timeIntervalSince1970))") }
            }
        }
        let wakes = Mutex<[Wake]>([])
        let harness = try await Harness.open(
            models: Models(builtinProviders: false), extensions: [Extension("tasks", tasks: [nap.any])], clock: clock.clock,
            timer: clock.timer, onWake: { wake in wakes.update { $0.append(wake) } })
        let root = try await harness.root()
        let id = try await root.commit { tx in try await tx.createTask(nap, input: Empty()) }
        let until = clock.now.addingTimeInterval(3600)

        try await eventually(10) { if case .sleeping? = try await harness.task(id)?.status { true } else { false } }
        #expect(try await harness.task(id)?.status == .sleeping(until: until))
        #expect(try await harness.inspect().tasks.first { $0.record.id == id }?.state == .sleeping(until: until))
        #expect(try await harness.taskGraph().tasks[id]?.state == .sleeping(phase: "again", until: until))
        // The harness needs a process again at the sleep's end, and says so.
        let wake = try await harness.wake()
        #expect(wake.at == until)
        #expect(wake.active == false)
        try await eventually(5) { wakes.get().contains { $0.at == until } }

        // With `onWake`, the app wakes the harness: once due, the task is active, and `resume()` runs it.
        clock.advance(by: 3600)
        #expect(try await harness.wake().active)
        try await harness.resume()
        try await eventually(10) { if case .sleeping(let at)? = try await harness.task(id)?.status { at > until } else { false } }
        clock.advance(by: 60)
        try await harness.resume()
        let outcome = try await withTimeout(10) { try await harness.waitForTask(id, as: String.self) }
        #expect(outcome.result == "woke at \(Int(until.timeIntervalSince1970) + 60)")
        try await harness.close()
    }

    @Test func withoutOnWakeTheHarnessTimerWakesSleepingTasks() async throws {
        let clock = ManualClock()
        let nap = TaskType<Empty, At, String>("test.timedNap", version: 1, initial: { _ in At(phase: "sleep") }, abort: abortTask) {
            Phase("sleep") { run in
                try await run.sleep(until: try await run.now().addingTimeInterval(600), then: At(phase: "woke"))
            }
            Phase("woke") { run in try await run.commit { _, _ in .completed("woke") } }
        }
        let harness = try await Harness.open(
            models: Models(builtinProviders: false), extensions: [Extension("tasks", tasks: [nap.any])], clock: clock.clock,
            timer: clock.timer)
        let id = try await harness.root().commit { tx in try await tx.createTask(nap, input: Empty()) }
        try await eventually(10) { if case .sleeping? = try await harness.task(id)?.status { true } else { false } }
        clock.advance(by: 600)
        #expect(try await withTimeout(10) { try await harness.waitForTask(id, as: String.self) }.result == "woke")
        try await harness.close()
    }

    @Test func appTimersArmTheHarnessAndSessionTimers() async throws {
        // Dispatch timers that decline the background ones, as a process that should suspend would.
        let armed = Mutex<[Bool]>([])
        let dispatch = HarnessTimer.dispatch(declineBackground: true)
        let timer = HarnessTimer { delay, background, fire in
            armed.update { $0.append(background) }
            return dispatch.arm(delay, background, fire)
        }
        let models = Models(builtinProviders: false)
        let faux = FauxProvider()
        try await models.register(faux)
        try await faux.append(.text("Hello"))
        let harness = try await Harness.open(
            models: models, settings: Settings(documentRetention: .milliseconds(10)), timer: timer)
        let root = try await harness.root(agent: AgentChange(model: faux.model))
        #expect(try await ask(root, "Hi").text == "Hello")
        try await eventually(5) { armed.get().contains(true) }
        try await harness.close()

        let sessionTimers = Mutex(0)
        let session = try await Session.open(
            documentRetention: .milliseconds(10),
            timer: HarnessTimer { delay, background, fire in
                sessionTimers.update { $0 += 1 }
                return HarnessTimer.dispatch().arm(delay, background, fire)
            })
        let counter = Document("test.counter", scope: .session, initial: Counter())
        try await session.update(counter) { $0.count += 1 }
        try await eventually(5) { sessionTimers.get() > 0 }
        try await session.close()
    }

    @Test func phaseTimersFireAndCancel() async throws {
        let paced = TaskType<Empty, At, String>("test.paced", version: 1, initial: { _ in At(phase: "run") }, abort: abortTask) {
            Phase("run") { run in
                let fired = Mutex(false)
                try await run.timer(after: .milliseconds(20)) { fired.set(true) }
                try await eventually(5) { fired.get() }
                let late = Mutex(false)
                let timer = try await run.timer(after: .milliseconds(100)) { late.set(true) }
                await timer.cancel()
                try await Task.sleep(for: .milliseconds(250))
                let result = late.get() ? "fired after cancel" : "fired once"
                try await run.commit { _, _ in .completed(result) }
            }
        }
        let setup = try await FauxSetup.make(extensions: [Extension("tasks", tasks: [paced.any])])
        let root = try await setup.root()
        let id = try await root.commit { tx in try await tx.createTask(paced, input: Empty()) }
        #expect(try await withTimeout(10) { try await setup.harness.waitForTask(id, as: String.self) }.result == "fired once")
    }

    @Test func reportsSayWhatTheyAreAbout() async throws {
        let reporter = TaskType<Empty, At, String>("test.reporter", version: 1, initial: { _ in At(phase: "run") }, abort: abortTask) {
            Phase("run") { run in
                try await run.report("section broke", from: .extension("sections"))
                try await run.report("environment broke", from: .host(.environment))
                try await run.commit { _, _ in .completed("reported") }
            }
        }
        let reports = Mutex<[HarnessReport]>([])
        let harness = try await Harness.open(
            models: Models(builtinProviders: false), extensions: [Extension("tasks", tasks: [reporter.any])],
            onReport: { report in reports.update { $0.append(report) } })
        let root = try await harness.root()
        let id = try await root.commit { tx in try await tx.createTask(reporter, input: Empty()) }
        _ = try await withTimeout { try await harness.waitForTask(id) }
        try await eventually(5) { reports.get().count >= 2 }
        let section = try #require(reports.get().first { $0.message == "section broke" })
        guard case .extensionError(let name, let about?, _) = section.kind else {
            Issue.record("Expected an extension error, got \(section.kind)")
            return
        }
        #expect(name == "sections")
        #expect(about.id == id)
        let environment = try #require(reports.get().first { $0.message == "environment broke" })
        guard case .hostError(let callback, let task?) = environment.kind else {
            Issue.record("Expected a host error, got \(environment.kind)")
            return
        }
        #expect(callback == .environment)
        #expect(task.id == id)
        try await harness.close()
    }

    @Test func aTaskCutOffByCrashesIsParkedUntilRetried() async throws {
        let url = temporaryDirectory().appending(path: "crashes.sqlite")
        let released = Mutex(false)
        let work = TaskType<Empty, At, String>("test.work", version: 1, initial: { _ in At(phase: "work") }, abort: abortTask) {
            Phase("work") { run in
                if !released.get() { try await Task.sleep(for: .seconds(3600)) }
                try await run.commit { _, _ in .completed("done") }
            }
        }
        // A process that crashes with the task running: its runtime is never closed.
        let crashed = Runtime()
        let first = try await Harness.open(
            .sqlite(at: url), models: Models(builtinProviders: false, runtime: crashed), extensions: [Extension("tasks", tasks: [work.any])])
        let id = try await first.root().commit { tx in try await tx.createTask(work, input: Empty()) }
        try await eventually(10) { try await first.task(id)?.status == .running }

        let reports = Mutex<[HarnessReport]>([])
        let harness = try await Harness.open(
            .sqlite(at: url), models: Models(builtinProviders: false, runtime: Runtime()),
            extensions: [Extension("tasks", tasks: [work.any])], settings: Settings(restartLimit: 1),
            onReport: { report in reports.update { $0.append(report) } })
        let record = try #require(try await harness.task(id))
        #expect(record.restarts == 1)
        #expect(try await harness.inspect().tasks.first { $0.record.id == id }?.state == .blocked(reason: "restart_limit", error: nil))
        #expect(try await harness.taskGraph().tasks[id]?.blocked == .restartLimit)
        try await eventually(5) {
            reports.get().contains { if case .taskParked(let task, _) = $0.kind { task.id == id } else { false } }
        }

        released.set(true)
        try await harness.retryTask(id)
        #expect(try await withTimeout(10) { try await harness.waitForTask(id, as: String.self) }.result == "done")
        try await harness.close()
    }

    @Test func aFailedRunKeepsWithdrawsOrContinuesTheInputsQueuedBehindIt() async throws {
        for policy in [Settings.AfterFailedRun.keep, .withdraw, .continue] {
            // The run calls a slow tool, a second input queues behind it meanwhile, and the tool takes the agent's model
            // away, so the run's next request fails (`no_model`, as one whose compaction failed does with `model_error`).
            let breaker = Tool("break", description: "Breaks the agent") { context -> String in
                try await Task.sleep(for: .milliseconds(300))
                try await context.commit { tx in
                    try await tx.configure(context.conversationId, AgentChange(model: ModelRef(provider: "faux", modelId: "missing")))
                }
                return "broken"
            }
            let setup = try await FauxSetup.make(
                extensions: [Extension("break", tools: [breaker])], settings: Settings(afterFailedRun: policy))
            try await setup.faux.append(.toolCall("break", [:]))
            let root = try await setup.root()
            let first = try await root.submit("first")
            try await Task.sleep(for: .milliseconds(100))
            let queued = try await root.submit("second")
            #expect(try await queued.status().status == .queued)
            let failed = try await withTimeout(10) { try await first.wait() }
            #expect(failed.status == .unanswered(entry: failed.status.entry, reason: "no_model", detail: nil), "\(failed.status)")
            switch policy {
            case .keep:
                try await Task.sleep(for: .milliseconds(200))
                #expect(try await queued.status().status == .queued)
            case .withdraw:
                let settled = try await withTimeout(10) { try await queued.wait() }
                #expect(settled.status == .unanswered(entry: nil, reason: "run_failed", detail: nil), "\(settled.status)")
            case .continue:
                // The next run starts with it, and fails the same way.
                let settled = try await withTimeout(10) { try await queued.wait() }
                guard case .unanswered(let entry, let reason, _) = settled.status else {
                    Issue.record("Expected the queued input run, got \(settled.status)")
                    continue
                }
                #expect(entry != nil)
                #expect(reason == "no_model")
            }
        }
    }

    @Test func compactionThresholdsPerModel() async throws {
        let small = FauxProvider.Model(id: "small", contextWindow: 3000)
        let large = FauxProvider.Model(id: "large", contextWindow: 1_000_000)
        let faux = FauxProvider(models: [small, large])
        let smallRef = faux.model("small")
        let models = Models(builtinProviders: false)
        try await models.register(faux)
        try await faux.respond { _, _ in .text("A long enough answer to compact later on, with some padding text.") }
        let settings = Settings(
            retry: .init(enabled: false),
            compaction: .init(enabled: false, modelOverrides: [smallRef: .init(enabled: true, reserveTokens: 2950, keepRecentTokens: 1)]))
        let harness = try await Harness.open(models: models, settings: settings)
        let compacts = try await harness.createConversation(agent: AgentChange(model: smallRef))
        let keeps = try await harness.createConversation(agent: AgentChange(model: faux.model("large")))
        for index in 1...3 {
            _ = try await ask(compacts, "Message \(index) with padding text")
            _ = try await ask(keeps, "Message \(index) with padding text")
        }
        try await withTimeout(20) { try await harness.waitForIdle() }
        @Sendable func compacted(_ conversation: Conversation) async throws -> Bool {
            try await conversation.view().entries.contains { $0.kind == "pi.compaction" }
        }
        try await eventually(10) { try await compacted(compacts) }
        #expect(try await compacted(keeps) == false)
        try await harness.close()
    }

    @Test func settingsRoundTrip() throws {
        let model = ModelRef(provider: "anthropic", modelId: "claude-x")
        let settings = Settings(
            compaction: .init(reserveTokens: 100, modelOverrides: [model: .init(reserveTokens: 4000)]),
            afterFailedRun: .continue, restartLimit: .max)
        let json = try JSONValue(encoding: settings)
        #expect(json["compaction"]?["modelOverrides"]?["anthropic/claude-x"]?["reserveTokens"] == 4000)
        #expect(json["afterFailedRun"] == "continue")
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        // An unlimited restart limit comes back from JavaScript as `null`.
        let unlimited = try JSONDecoder().decode(Settings.self, from: Data(#"{"restartLimit":null}"#.utf8))
        #expect(unlimited.restartLimit == .max)
    }

    @Test func harnessSettingsResolveTheNewDefaults() async throws {
        let setup = try await FauxSetup.make()
        let resolved = try await setup.harness.resolvedSettings()
        #expect(resolved.afterFailedRun == .keep)
        #expect(resolved.restartLimit == 5)
        try await setup.harness.updateSettings(Settings(restartLimit: .max))
        #expect(try await setup.harness.resolvedSettings().restartLimit == .max)
    }

    @Test func modelsCanBeReplacedWithoutReopening() async throws {
        let before = FauxProvider()
        let after = FauxProvider()
        let firstModels = Models(builtinProviders: false)
        try await firstModels.register(before)
        try await before.append(.text("from the first models"))
        let secondModels = Models(builtinProviders: false)
        try await secondModels.register(after)
        try await after.append(.text("from the second models"))

        let harness = try await Harness.open(models: firstModels)
        let root = try await harness.root(agent: AgentChange(model: before.model))
        #expect(try await ask(root, "One").text == "from the first models")
        try await harness.replaceModels(secondModels)
        #expect(harness.models === secondModels)
        #expect(try await ask(root, "Two").text == "from the second models")
        try await harness.close()
    }

    @Test func toolsReadTheHarnessClock() async throws {
        let fixed = Date(timeIntervalSince1970: 1_900_000_000)
        let clock = Tool("clock", description: "The harness clock") { context -> String in
            "\(Int(try await context.now().timeIntervalSince1970))"
        }
        let models = Models(builtinProviders: false)
        let faux = FauxProvider()
        try await models.register(faux)
        try await faux.append(.toolCall("clock", [:]))
        try await faux.append(.text("done"))
        let harness = try await Harness.open(models: models, extensions: [Extension("clock", tools: [clock])], clock: { fixed })
        let root = try await harness.root(agent: AgentChange(model: faux.model))
        _ = try await ask(root, "Time?")
        #expect(try await root.view().entries.compactMap(\.toolResult).first?.text == "1900000000")
        try await harness.close()
    }

    @Test func telemetryRecordsTracesTaskCarriersAndModelRequests() async throws {
        let telemetry = try await Telemetry.memory()
        let setup = try await FauxSetup.make()
        try await setup.harness.close()
        let models = setup.models
        try await setup.faux.append(.text("Hello"))
        let harness = try await Harness.open(
            models: models, extensions: [Extension("tasks", tasks: [quick.any])], telemetry: telemetry)
        let root = try await harness.root(agent: AgentChange(model: setup.faux.model))
        let submission = try await root.submit("Hi")
        _ = try await withTimeout { try await submission.wait() }

        let names = Set(try await telemetry.traces(TraceQuery(limit: 50)).traces.flatMap(\.spans).map(\.name))
        #expect(names.contains("pi.durable.submit"))
        #expect(names.contains("pi.durable.phase"))
        // The in-memory recorder propagates: submissions and tasks keep their trace.
        #expect(try await submission.status().trace != nil)
        // A task created with a carrier continues that trace; one at the root stores none.
        let carrier = try #require(try await submission.status().trace)
        let continued = try await root.commit { tx in try await tx.createTask(quick, input: Empty(), trace: .carrier(carrier)) }
        let rooted = try await root.commit { tx in
            try await tx.createTask(quick, input: Empty(), trace: .root, links: [carrier])
        }
        #expect(try await harness.task(continued)?.trace == carrier)
        #expect(try await harness.task(rooted)?.trace == nil)
        #expect(try await harness.task(rooted)?.links == [carrier])
        try await harness.close()

        // A direct request records in a root span of its own.
        try await setup.faux.append(.text("Direct"))
        _ = try await models.complete(
            setup.faux.model, context: ModelContext(messages: [.user(UserMessage(content: [.text("Hi")]))]), telemetry: telemetry,
            span: "app.summary")
        let direct = try await telemetry.traces(TraceQuery(name: "app.summary"))
        #expect(direct.traces.count == 1)

        let metrics = try await telemetry.metrics(MetricQuery("pi.durable.phase.duration"))
        #expect(!metrics.isEmpty)
        let schemas = try await Telemetry.schemas()
        #expect(schemas.durable["spans"]?["pi.durable.submit"] != nil)
        #expect(schemas.ai["spans"] != nil)
    }

    @Test func telemetryInSQLite() async throws {
        let url = temporaryDirectory().appending(path: "telemetry.sqlite")
        let telemetry = try await Telemetry.sqlite(at: url, retention: .seconds(3600))
        let setup = try await FauxSetup.make()
        try await setup.harness.close()
        try await setup.faux.append(.text("Hello"))
        let harness = try await Harness.open(models: setup.models, telemetry: telemetry)
        let root = try await harness.root(agent: AgentChange(model: setup.faux.model))
        _ = try await ask(root, "Hi")
        try await harness.close()
        try await telemetry.flush()
        let page = try await telemetry.traces(TraceQuery(name: "pi.durable.submit"))
        let trace = try #require(page.traces.first)
        #expect(try await telemetry.trace(trace.traceId)?.spans.isEmpty == false)
        #expect(try await telemetry.dropped() == (0, 0))
        try await telemetry.close()
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test func extensionsCanRequireTheNewModules() async throws {
        let source = #"""
        const { defineExtension, defineTool } = require("@earendil-works/pi-durable");
        const { Type } = require("@earendil-works/pi-ai");
        const sqlite = require("@earendil-works/chord/sqlite");
        const telemetrySqlite = require("@earendil-works/chord/telemetry-sqlite");
        const telemetry = require("@earendil-works/pi-telemetry");
        const { withTelemetry, traceIn } = require("@earendil-works/chord/context");
        module.exports = defineExtension({
            name: "modules",
            tools: [defineTool({
                name: "modules",
                description: "The new modules",
                parameters: Type.Object({}),
                execute: async () => ({
                    output: [{ type: "text", text: [typeof sqlite.validateSqliteSchemaPrefix, typeof telemetrySqlite.createSqliteTelemetry,
                        typeof telemetry.InMemoryTelemetryContext, typeof withTelemetry, typeof traceIn].join(" ") }],
                }),
            })],
        });
        """#
        let setup = try await FauxSetup.make(extensions: [Extension("modules", javaScript: source)])
        try await setup.faux.append(.toolCall("modules", [:]))
        try await setup.faux.append(.text("Done"))
        let root = try await setup.root()
        _ = try await ask(root, "Go")
        let result = try #require(try await root.view().entries.compactMap(\.toolResult).first)
        #expect(result.text == "function function function function function", "\(result.text)")
    }
}

private let quick = TaskType<Empty, At, String>("test.quick", version: 1, initial: { _ in At(phase: "run") }, abort: abortTask) {
    Phase("run") { run in try await run.commit { _, _ in .completed("quick") } }
}

extension SubmissionRecord.Status {
    /// The entry of a placed, done, or unanswered submission.
    var entry: EntryID? {
        switch self {
        case .queued: nil
        case .placed(let entry), .done(let entry, _): entry
        case .unanswered(let entry, _, _): entry
        }
    }
}

extension HarnessReport {
    /// The task a report is about, if any.
    var task: ReportTask? {
        switch kind {
        case .taskFaulted(let task, _, _), .taskParked(let task, _), .migrationFailed(let task, _), .taskOutdated(let task, _, _),
            .taskError(let task, _):
            task
        case .extensionError(_, let task, _), .hostError(_, let task): task
        case .sessionFailed, .listenerError: nil
        }
    }
}
