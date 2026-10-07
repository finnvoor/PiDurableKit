import Foundation
import PiDurableKit
import QuartzCore
import SwiftUI

/// Benchmark mode for long conversations: `-demo -bench 2000` seeds that many exchanges, streams a long reply, then
/// scrolls to the top and back, logging how long transcript updates take and how many frames were late in each phase.
@MainActor
enum PerformanceLog {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-bench")
    static let scrollRequest = Notification.Name("PiChat.benchmarkScroll")
    static let focusRequest = Notification.Name("PiChat.benchmarkFocus")
    /// Balloon bodies evaluated, to see how much of the transcript a change re-renders.
    static var balloonRenders = 0

    private static var updates: [Duration] = []
    private static var attributedTimes: [Duration] = []

    static func rebuild(_ duration: Duration, rows: Int) {
        guard enabled else { return }
        print(String(format: "PiChat bench: built %d rows in %.1f ms", rows, duration.milliseconds))
    }

    static func attributed(_ duration: Duration) {
        guard enabled else { return }
        attributedTimes.append(duration)
    }
    private static var monitor: HitchMonitor?

    static func transcriptUpdate(_ duration: Duration, rows: Int) {
        guard enabled else { return }
        updates.append(duration)
    }

    /// The number of exchanges to seed, from `-bench <count>`.
    static var exchanges: Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-bench") else { return nil }
        return arguments.indices.contains(index + 1) ? Int(arguments[index + 1]) ?? 1000 : 1000
    }

    static func run(_ conversation: Conversation, faux: FauxProvider, exchanges: Int) async throws {
        let sentence = "The quick brown fox jumps over the **lazy dog** while the agent explains https://example.com durable state. "
        let clock = ContinuousClock()
        let seeded = try await clock.measure {
            var remaining = exchanges
            while remaining > 0 {
                let batch = min(remaining, 250)
                try await conversation.commit { tx in
                    for index in 0..<batch {
                        let user = UserMessage(content: [.text("Question \(index)? \(sentence)")])
                        try await tx.append(EntryDraft(kind: .user, model: [.user(user)]), to: conversation.id)
                        let answer = AssistantMessage(content: [.text(String(repeating: sentence, count: index % 4 + 1))])
                        try await tx.append(EntryDraft(kind: .assistant, model: [.assistant(answer)]), to: conversation.id)
                    }
                }
                remaining -= batch
            }
        }
        print("PiChat bench: seeded \(exchanges * 2) messages in \(seeded)")
        try await Task.sleep(for: .seconds(2))
        await phase("idle", seconds: 1)
        try await faux.append(.text(String(repeating: sentence, count: 30)))
        updates = []
        let monitor = HitchMonitor()
        monitor.start()
        _ = try await conversation.submit("Tell me more").wait()
        let streaming = monitor.stop()
        report("streaming", streaming)
        NotificationCenter.default.post(name: scrollRequest, object: Edge.top)
        await phase("scroll to top", seconds: 2)
        NotificationCenter.default.post(name: scrollRequest, object: Edge.bottom)
        await phase("scroll to bottom", seconds: 2)
        for round in 1...2 {
            NotificationCenter.default.post(name: focusRequest, object: true)
            await phase("keyboard up \(round)", seconds: 1.5)
            NotificationCenter.default.post(name: focusRequest, object: false)
            await phase("keyboard down \(round)", seconds: 1.5)
        }
        print("PiChat bench: done")
    }

    private static func phase(_ name: String, seconds: Double) async {
        updates = []
        balloonRenders = 0
        let monitor = HitchMonitor()
        monitor.start()
        try? await Task.sleep(for: .seconds(seconds))
        report(name, monitor.stop())
    }

    private static func report(_ name: String, _ frames: HitchMonitor.Result) {
        let parse = attributedTimes.sorted()
        if !parse.isEmpty {
            print(String(format: "PiChat bench: %@ — %d Markdown parses, median %.2f ms, worst %.2f ms", name, parse.count,
                parse[parse.count / 2].milliseconds, parse.last!.milliseconds))
        }
        attributedTimes = []
        print("PiChat bench: \(name) — \(balloonRenders) balloon renders")
        let sorted = updates.sorted()
        let median = sorted.isEmpty ? Duration.zero : sorted[sorted.count / 2]
        print(String(
            format: "PiChat bench: %@ — %d frames, %d late (%.1f ms/s hitch time, worst %.1f ms); %d transcript updates, median %.2f ms, worst %.2f ms",
            name, frames.frames, frames.late, frames.hitchRatio, frames.worst, updates.count,
            median.milliseconds, (sorted.last ?? .zero).milliseconds))
    }
}

/// Counts frames that missed their deadline, from `CADisplayLink` timestamps.
@MainActor
final class HitchMonitor: NSObject {
    struct Result {
        var frames = 0
        var late = 0
        /// Milliseconds of lateness per second (the hitch time ratio).
        var hitchRatio = 0.0
        var worst = 0.0
    }

    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private var result = Result()
    private var hitchTime = 0.0
    private var started = CACurrentMediaTime()

    func start() {
        started = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        // Measure at the display's full rate (120 Hz on ProMotion), as scrolling runs.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { last = link.timestamp }
        guard let last else { return }
        result.frames += 1
        let interval = link.timestamp - last
        let expected = link.targetTimestamp - link.timestamp
        if interval > expected * 1.5 {
            result.late += 1
            let lateness = (interval - expected) * 1000
            hitchTime += lateness
            result.worst = max(result.worst, lateness)
        }
    }

    func stop() -> Result {
        link?.invalidate()
        link = nil
        let elapsed = CACurrentMediaTime() - started
        result.hitchRatio = elapsed > 0 ? hitchTime / elapsed : 0
        return result
    }
}

extension Duration {
    var milliseconds: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}
