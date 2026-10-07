import BackgroundTasks
import PiDurableKit

/// Keeps the agent working after the person leaves the app, while a reply they asked for is in progress.
///
/// Sending a message starts a `BGContinuedProcessingTask`: the system keeps the app running in the background and
/// shows the run's progress in a Live Activity, where it can be cancelled. The task only buys time. The agent's work is
/// committed as it happens, so when the system ends the task early (or the person cancels it, or force-quits the app),
/// nothing is lost: the run continues the next time the app is in the foreground, or `harness.resume()` picks it up at
/// the next launch. Use Stop in the app to actually abort a run.
@MainActor
final class BackgroundRun {
    /// Matches the wildcard `<bundle ID>.run.*` in `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    private static let prefix = "\(Bundle.main.bundleIdentifier ?? "com.finnvoorhees.PiChat").run"

    /// The task covering the current run; later messages of the same run are covered by it too.
    private var active: BGContinuedProcessingTask?

    /// Starts covering the run that settles `submission`. Call it right after the person sends a message.
    func cover(_ submission: Submission, in conversation: Conversation, prompt: String) {
        guard active == nil else { return }
        let identifier = "\(Self.prefix).\(UUID().uuidString)"
        // Continued-processing handlers are registered when needed, not at launch.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            guard let task = task as? BGContinuedProcessingTask else { return task.setTaskCompleted(success: false) }
            MainActor.assumeIsolated { self.run(task, submission: submission, conversation: conversation) }
        }
        guard registered else { return print("PiChat could not register \(identifier)") }
        print("PiChat requesting background run: \(identifier)")
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: "Replying", subtitle: String(prompt.prefix(80)))
        // Running later in the background is pointless for a reply the person is waiting on: start now or not at all.
        request.strategy = .fail
        Task {
            do {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            } catch {
                // The run continues in the foreground regardless.
                print("PiChat could not start background run: \(error)")
            }
        }
    }

    private func run(_ task: BGContinuedProcessingTask, submission: Submission, conversation: Conversation) {
        print("PiChat background run started: \(task.identifier)")
        active = task
        task.progress.totalUnitCount = Self.scale
        let work = Task {
            // The system expires tasks whose progress looks stalled, and a single long response can stream for minutes
            // without committing an entry, so progress follows the streamed text too.
            let progress = Task {
                var first: Int?
                var reported: Int64 = 0
                for try await view in conversation.views() {
                    let start = first ?? view.entries.count
                    first = start
                    let completed = Self.completed(work: Self.work(in: view, since: start))
                    if completed > reported {
                        reported = completed
                        task.progress.completedUnitCount = completed
                    }
                    task.updateTitle(task.title, subtitle: Self.activity(in: view))
                }
            }
            defer { progress.cancel() }
            // Wait for the message's run, then for any follow-ups queued behind it.
            _ = try await submission.wait()
            for try await view in conversation.views() where !view.isBusy && view.inbox.isEmpty { break }
        }
        task.expirationHandler = {
            // Stop waiting, not working: the run is durable and continues later.
            print("PiChat background run expired: \(task.identifier)")
            work.cancel()
        }
        Task {
            let finished = (try? await work.value) != nil
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: finished)
            print("PiChat background run \(finished ? "finished" : "stopped"): \(task.identifier)")
            active = nil
        }
    }

    private static let scale: Int64 = 10_000

    /// The run's work so far in characters: the committed entries since it started, and the response streaming now.
    private static func work(in view: ConversationView, since start: Int) -> Int {
        let committed = view.entries.dropFirst(start).reduce(0) { total, entry in
            // Each entry is a step; a tool result often has little text.
            total + 500 + (entry.message.map(characters) ?? 0)
        }
        return committed + (view.streamingMessage.map { characters(in: .assistant($0)) } ?? 0)
    }

    private static func characters(in message: Message) -> Int {
        guard case .assistant(let message) = message else { return message.text.count }
        return message.content.reduce(0) { total, block in
            switch block {
            case .text(let text), .thinking(let text, _): total + text.count
            case .toolCall(let call): total + call.name.count + 200
            default: total
            }
        }
    }

    /// The length of a run is unknown, so progress approaches the end without reaching it: half way after about a
    /// typical long response, and always moving while text streams.
    private static func completed(work: Int) -> Int64 {
        let fraction = 1 - pow(0.5, Double(work) / 4_000)
        return min(Int64(fraction * Double(scale)), scale - 1)
    }

    private static func activity(in view: ConversationView) -> String {
        if let tool = view.live.tools.first(where: { $0.status == .running }) { return "Running \(tool.name)" }
        if view.streamingMessage != nil { return "Writing" }
        if !view.live.compactions.isEmpty { return "Compacting the conversation" }
        return "Thinking"
    }
}
