import Foundation
import Testing
@testable import PiDurableKit

struct Empty: Codable, Sendable, Equatable {}

/// A checkpoint that only names its phase.
struct At: TaskCheckpoint, Equatable {
    var phase: String
}

/// Ends the task as aborted, pi-durable's usual abort handler.
func abortTask<I, C, R>(_ run: TaskRun<I, C, R>) async throws {
    try await run.commit { _, _ in .aborted(nil) }
}

/// Doubles its input.
let doubler = TaskType<Int, At, Int>("test.doubler", version: 1, initial: { _ in At(phase: "run") }, abort: abortTask) {
    Phase("run") { run in try await run.commit { _, _ in .completed(run.input * 2) } }
}

struct Counter: TaskCheckpoint, Equatable {
    var phase = "count"
    var count = 0
}

/// Counts to its input through repeated phase transitions.
let countTo = TaskType<Int, Counter, String>("test.countTo", version: 1, initial: { _ in Counter() }, abort: abortTask) {
    Phase("count") { run in
        var next = run.checkpoint
        next.count += 1
        let done = next.count >= run.input
        try await run.commit { [next] _, _ in done ? .completed("counted to \(next.count)") : .running(next) }
    }
}

/// Fails for card "declined", succeeds otherwise.
let payment = TaskType<String, At, String>("test.payment", version: 1, initial: { _ in At(phase: "charge") }, abort: abortTask) {
    Phase("charge") { run in
        try await run.commit { _, _ in
            run.input == "declined"
                ? .failed("Card declined", detail: ["card": .string(run.input)]) : .completed("charged \(run.input)")
        }
    }
}

struct Checkout: TaskCheckpoint {
    var phase = "pay"
    var payments: [TaskID] = []
}

/// Creates one child payment per card, waits for all of them, and reports the outcomes.
func checkout(policy: JoinPolicy) -> TaskType<[String], Checkout, [String]> {
    TaskType("test.checkout.\(policy.rawValue)", version: 1, initial: { _ in Checkout() }, abort: abortTask) {
        Phase("pay") { run in
            try await run.commit { tx, current in
                var payments: [TaskID] = []
                for card in run.input {
                    payments.append(try await tx.createTask(payment, input: card, ownedBy: current.id))
                }
                return .waiting(Checkout(phase: "decide", payments: payments), on: payments, policy: policy)
            }
        }
        Phase("decide") { run in
            let outcomes = try await run.outcomes(of: run.checkpoint.payments, as: String.self)
            let summary = outcomes.map { outcome in
                switch outcome {
                case .completed(let text): text
                case .failed(let message, _): "failed: \(message)"
                case .aborted: "aborted"
                default: "other"
                }
            }
            try await run.commit { _, _ in .completed(summary) }
        }
    }
}

/// Parks in "wait" until released, so tests can observe a live task.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var open = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if open { continuation.resume() } else { continuations.append(continuation) }
            }
        }
    }

    func release() {
        let waiting = lock.withLock {
            open = true
            defer { continuations = [] }
            return continuations
        }
        for continuation in waiting { continuation.resume() }
    }
}

func parked(_ gate: Gate, name: String = "test.parked") -> TaskType<Empty, At, String> {
    TaskType(name, version: 1, initial: { _ in At(phase: "wait") }, abort: { run in
        try await run.commit { _, _ in .aborted("stopped by test") }
    }) {
        Phase("wait") { run in
            await withTaskCancellationHandler { await gate.wait() } onCancel: { gate.release() }
            try Task.checkCancellation()
            try await run.commit { _, _ in .completed("released") }
        }
    }
}

@Suite struct TaskTests {
    @Test func tasksRunPhasesToCompletion() async throws {
        let setup = try await FauxSetup.make(extensions: [Extension("tasks") { countTo }])
        let root = try await setup.root()
        let id = try await root.commit { tx in try await tx.createTask(countTo, input: 3) }
        let outcome = try await withTimeout { try await setup.harness.waitForTask(id, as: String.self) }
        #expect(outcome.result == "counted to 3")
        let record = try #require(try await setup.harness.task(id))
        #expect(record.kind == "test.countTo")
        #expect(record.conversationId == root.id)
        #expect(record.isTerminal)
    }

    @Test func childTasksWithAllSettled() async throws {
        let parent = checkout(policy: .allSettled)
        let setup = try await FauxSetup.make(extensions: [Extension("shop") {
            parent
            payment
        }])
        let root = try await setup.root()
        let id = try await root.commit { tx in try await tx.createTask(parent, input: ["visa", "declined", "amex"]) }
        let outcome = try await withTimeout { try await setup.harness.waitForTask(id, as: [String].self) }
        #expect(outcome.result == ["charged visa", "failed: Card declined", "charged amex"])
    }

    @Test func failFastAbortsTheRest() async throws {
        let gate = Gate()
        let slow = parked(gate, name: "test.slowPayment")
        let parent = TaskType<Empty, Checkout, String>("test.failFast", version: 1, initial: { _ in Checkout() }, abort: abortTask) {
            Phase("pay") { run in
                try await run.commit { tx, current in
                    let ids = [
                        try await tx.createTask(slow, input: Empty(), ownedBy: current.id),
                        try await tx.createTask(payment, input: "declined", ownedBy: current.id),
                    ]
                    return .waiting(Checkout(phase: "decide", payments: ids), on: ids, policy: .failFast)
                }
            }
            Phase("decide") { run in
                let outcomes = try await run.outcomes(of: run.checkpoint.payments, as: String.self)
                let slowAborted = if case .aborted = outcomes[0] { true } else { false }
                try await run.commit { _, _ in .completed(slowAborted ? "slow payment aborted" : "slow payment not aborted") }
            }
        }
        let setup = try await FauxSetup.make(extensions: [Extension("shop") {
            parent
            slow
            payment
        }])
        let root = try await setup.root()
        let id = try await root.commit { tx in try await tx.createTask(parent, input: Empty()) }
        let outcome = try await withTimeout { try await setup.harness.waitForTask(id, as: String.self) }
        #expect(outcome.result == "slow payment aborted")
    }

    @Test func abortRunsTheAbortHandler() async throws {
        let gate = Gate()
        let task = parked(gate)
        let setup = try await FauxSetup.make(extensions: [Extension("tasks") { task }])
        let root = try await setup.root()
        let id = try await root.commit { tx in try await tx.createTask(task, input: Empty()) }
        try await withTimeout {
            while try await setup.harness.task(id)?.status != TaskRecord.Status.running { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(try await setup.harness.abortTask(id) == "marked")
        let outcome = try await withTimeout { try await setup.harness.waitForTask(id, as: String.self) }
        guard case .aborted(let reason) = outcome else {
            Issue.record("Expected aborted, got \(outcome)")
            return
        }
        #expect(reason == "stopped by test")
    }

    @Test func taskGraphAndInspectionShowLiveTasks() async throws {
        let gate = Gate()
        let task = parked(gate)
        let setup = try await FauxSetup.make(extensions: [Extension("tasks") { task }])
        let root = try await setup.root()

        let updates = Task {
            try await withTimeout {
                for try await graph in setup.harness.taskGraphs() where graph.tasks.values.contains(where: { $0.kind == "test.parked" }) {
                    return graph
                }
                throw CancellationError()
            }
        }
        let id = try await root.commit { tx in try await tx.createTask(task, input: Empty(), background: true) }
        let streamed = try await updates.value
        #expect(streamed.tasks[id]?.background == true)

        let graph = try await setup.harness.taskGraph()
        let node = try #require(graph.tasks[id])
        #expect(node.kind == "test.parked")
        #expect(node.conversationId == root.id)
        #expect(graph.roots.contains { $0.id == id })

        let inspection = try await setup.harness.inspect()
        #expect(inspection.scheduling == "running")
        #expect(inspection.tasks.contains { $0.record.id == id })

        gate.release()
        #expect(try await setup.harness.waitForTask(id, as: String.self).result == "released")
        #expect(try await setup.harness.taskGraph().tasks[id] == nil)
    }

    @Test func memosDocumentsAndClockInsideTasks() async throws {
        let progress = Document("test.progress", scope: .task, initial: Counter())
        let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
        let reports = Mutex<[String]>([])
        let task = TaskType<Empty, At, String>("test.memo", version: 1, initial: { _ in At(phase: "run") }, abort: abortTask) {
            Phase("run") { run in
                let key = try await run.memo("key", default: "first")
                let again = try await run.memo("key", default: "second")
                try await run.commit { tx, current in
                    try await tx.updateDocument(progress, of: .task(current.id)) { $0.count = 7 }
                    return nil
                }
                let stored = try await run.document(progress)
                let now = try await run.now()
                try await run.report("progress \(stored.count)")
                try await run.commit { _, _ in .completed("\(key) \(again) \(stored.count) \(Int(now.timeIntervalSince1970))") }
            }
        }
        let models = Models(builtinProviders: false)
        let harness = try await Harness.open(
            models: models, extensions: [Extension("tasks") { task }], clock: { fixedDate },
            onReport: { message in reports.update { $0.append(message) } })
        let root = try await harness.root()
        let id = try await root.commit { tx in try await tx.createTask(task, input: Empty()) }
        let outcome = try await withTimeout { try await harness.waitForTask(id, as: String.self) }
        #expect(outcome.result == "first first 7 1800000000")
        #expect(reports.get().contains { $0.contains("progress 7") })
    }

    @Test func taskHooksLetOtherExtensionsWeighIn() async throws {
        struct Charge: Codable, Sendable { var amount: Int }
        let charge = TaskType<Charge, At, String>("test.charge", version: 1, initial: { _ in At(phase: "run") }, abort: abortTask) {
            Phase("run") { run in
                let verdicts = try await run.hooks("beforeCharge", arguments: run.input)
                let block = verdicts.compactMap { $0["block"]?.stringValue }.first
                try await run.commit { _, _ in
                    block.map { .failed($0) } ?? .completed("charged \(run.input.amount) after \(verdicts.count) checks")
                }
            }
        }
        let seen = Mutex<[Int]>([])
        let limits = Extension("limits") {
            Hook.task(charge, "beforeCharge") { arguments, context in
                seen.update { $0.append(context.taskId.rawValue) }
                return (arguments["amount"]?.intValue ?? 0) > 100 ? ["block": "Over the limit"] : ["ok": true]
            }
        }
        let audit = Extension("audit") { Hook.task(charge, "beforeCharge") { _, _ in nil } }
        let setup = try await FauxSetup.make(extensions: [Extension("shop") { charge }, limits, audit])
        let root = try await setup.root()

        let small = try await root.commit { tx in try await tx.createTask(charge, input: Charge(amount: 20)) }
        #expect(try await withTimeout { try await setup.harness.waitForTask(small, as: String.self) }.result == "charged 20 after 2 checks")
        let large = try await root.commit { tx in try await tx.createTask(charge, input: Charge(amount: 500)) }
        let largeOutcome = try await withTimeout { try await setup.harness.waitForTask(large, as: String.self) }
        guard case .failed(let message, _) = largeOutcome else {
            Issue.record("Expected the large charge to fail")
            return
        }
        #expect(message == "Over the limit")
        #expect(seen.get() == [small.rawValue, large.rawValue])
    }

    @Test func tasksResumeAndMigrateAfterReopen() async throws {
        let url = temporaryDirectory().appending(path: "tasks.sqlite")
        let gate = Gate()
        let id: TaskID

        do {
            let v1 = TaskType<Int, Counter, String>("test.migrating", version: 1, initial: { start in
                Counter(phase: "wait", count: start)
            }, abort: abortTask) {
                Phase("wait") { run in
                    await withTaskCancellationHandler { await gate.wait() } onCancel: { gate.release() }
                    try Task.checkCancellation()
                    try await run.commit { _, _ in .completed("v1") }
                }
            }
            let models = Models(builtinProviders: false)
            let harness = try await Harness.open(.sqlite(at: url), models: models, extensions: [Extension("tasks") { v1 }])
            let root = try await harness.root()
            id = try await root.commit { tx in try await tx.createTask(v1, input: 5) }
            try await withTimeout {
                while try await harness.task(id)?.status != TaskRecord.Status.running { try await Task.sleep(for: .milliseconds(10)) }
            }
            try await harness.close()
        }

        struct Total: TaskCheckpoint { var phase: String; var total: Int }
        let v2 = TaskType<Int, Total, String>(
            "test.migrating", version: 2, initial: { start in Total(phase: "wait", total: start) }, abort: abortTask,
            migrate: { input, checkpoint, version in
                // The stored checkpoint has pi-durable's shape: the phase beside the task's own fields.
                #expect(checkpoint["phase"] == "wait")
                let count = checkpoint["count"]?.intValue ?? 0
                return (try input.decode(as: Int.self), Total(phase: "wait", total: count * 10 + version))
            }
        ) {
            Phase("wait") { run in try await run.commit { _, _ in .completed("v2 total \(run.checkpoint.total)") } }
        }
        let models = Models(builtinProviders: false)
        let harness = try await Harness.open(.sqlite(at: url), models: models, extensions: [Extension("tasks") { v2 }])
        let outcome = try await withTimeout { try await harness.waitForTask(id, as: String.self) }
        #expect(outcome.result == "v2 total 51")
        try await harness.close()
    }
}
