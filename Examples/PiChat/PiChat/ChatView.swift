import PiDurableKit
import SwiftUI

/// The conversation as a chat transcript: balloons with tails, a blue gradient that follows a balloon's place on screen,
/// grouping and spacing by sender, a thinking bubble, swiping left for times, big emoji, and a Liquid Glass entry bar.
struct ChatView: View {
    let conversation: Conversation
    @State private var transcript = Transcript()
    @State private var keyboard = KeyboardState()

    var body: some View {
        TranscriptView(transcript: transcript, keyboardRises: keyboard.rises)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                EntryBar(conversation: conversation, busy: transcript.busy)
                    .padding(.bottom, keyboard.overlap)
            }
            // The keyboard is avoided by hand, from its live position, so the transcript follows it while it's swiped
            // away too (the built-in avoidance only catches up once it's gone, in one jump).
            .ignoresSafeArea(.keyboard)
            .background { KeyboardTracker(state: $keyboard) }
            .task(id: conversation.id) {
                do {
                    for try await view in conversation.views() { transcript.update(view) }
                } catch {}
            }
    }
}

/// The transcript's rows. Entries never change once committed, so each one's rows are made once; and the rows before
/// the last committed message only change when entries are added, so while a reply streams in only the few rows at
/// the end (`liveRows`) are rebuilt, and a long conversation costs nothing extra per update.
@MainActor @Observable
final class Transcript {
    /// Every row but the last few; changed only when entries are added or removed. (One flat `ForEach` keeps
    /// `LazyVStack` lazy; splitting it into nested pages made it realize whole pages while scrolling.)
    private(set) var settledRows: [ChatRow] = []
    /// The last committed message onward (its tail depends on what follows), plus what is happening now.
    private(set) var liveRows: [ChatRow] = []
    private(set) var busy = false
    /// Changes when rows are added, removed, or reordered (not when one changes), to animate only those.
    private(set) var layoutRevision = 0

    @ObservationIgnored private var cache: [EntryID: [ChatItem]] = [:]
    @ObservationIgnored private var committed: [ChatItem] = []
    @ObservationIgnored private var entryIDs: [EntryID] = []
    @ObservationIgnored private var lastDate: Date?
    /// Where `liveRows` begins in `committed`: the last committed message.
    @ObservationIgnored private var split = 0

    func update(_ view: ConversationView) {
        let started = ContinuousClock.now
        let entries = view.entries
        let appended = !entryIDs.isEmpty && entries.count >= entryIDs.count
            && entries.first?.id == entryIDs.first && entries[entryIDs.count - 1].id == entryIDs.last
        if appended, entries.count > entryIDs.count {
            // The usual case: entries were added. Rows before the old split never change, so only extend.
            let added = entries[entryIDs.count...]
            entryIDs += added.map(\.id)
            committed += items(for: added)
            let oldSplit = split
            split = committed.lastIndex { $0.sender != nil } ?? committed.count
            if split > oldSplit {
                settledRows += ChatRow.rows(
                    for: Array(committed[oldSplit..<split]), nextAfterEnd: committed[split], startsTranscript: oldSplit == 0)
                layoutRevision += 1
            }

        } else if !appended {
            // First view, a reset, or a compaction: start over.
            entryIDs = entries.map(\.id)
            lastDate = nil
            committed = items(for: entries[...])
            split = committed.lastIndex { $0.sender != nil } ?? committed.count
            settledRows = split > 0 ? ChatRow.rows(for: Array(committed.prefix(split)), nextAfterEnd: committed[split]) : []
            layoutRevision += 1
            PerformanceLog.rebuild(ContinuousClock.now - started, rows: split)
        }
        let tail = Array(committed[split...]) + ChatItem.liveItems(for: view, after: committed)
        let live = ChatRow.rows(for: tail, startsTranscript: split == 0)
        if live.map(\.id) != liveRows.map(\.id) { layoutRevision += 1 }
        if live != liveRows { liveRows = live }
        if busy != view.isBusy { busy = view.isBusy }
        PerformanceLog.transcriptUpdate(ContinuousClock.now - started, rows: split + live.count)
    }

    private func items(for entries: ArraySlice<Entry>) -> [ChatItem] {
        var items: [ChatItem] = []
        items.reserveCapacity(entries.count + 8)
        for entry in entries {
            let made = cache[entry.id] ?? ChatItem.items(for: entry)
            cache[entry.id] = made
            for item in made {
                // A timestamp before the first message of each burst more than 15 minutes after the last.
                if let date = item.date {
                    if lastDate.map({ date.timeIntervalSince($0) > 15 * 60 }) ?? true {
                        items.append(.timestamp(item.id, date))
                    }
                    lastDate = date
                }
                items.append(item)
            }
        }
        return items
    }
}

/// One row of the transcript with the spacing that depends on its neighbours.
struct ChatRow: Identifiable, Hashable {
    let item: ChatItem
    let first: Bool
    /// The last message of its sender's group, which gets the tail.
    let tail: Bool
    let bottomSpacing: CGFloat

    var id: String { item.id }

    /// Rows for `items`; `nextAfterEnd` is the item after the last when `items` is only part of the transcript.
    static func rows(for items: [ChatItem], nextAfterEnd: ChatItem? = nil, startsTranscript: Bool = true) -> [ChatRow] {
        items.indices.map { index in
            let item = items[index]
            let next = items.indices.contains(index + 1) ? items[index + 1] : nextAfterEnd
            var tail = false
            var spacing: CGFloat = 0
            if case .message(let message) = item {
                tail = next?.sender != message.sender
                spacing = next == nil ? 0 : (next?.sender == message.sender ? Metrics.contiguousSpace : Metrics.nonContiguousSpace)
            }
            return ChatRow(item: item, first: startsTranscript && index == 0, tail: tail, bottomSpacing: spacing)
        }
    }
}

struct TranscriptView: View {
    let transcript: Transcript
    /// Counts the keyboard rising (not following a finger), to bring the latest message up above it.
    var keyboardRises = 0
    /// How far the transcript is pulled left to show times (0 to -Metrics.drawerWidth).
    @State private var drawer: CGFloat = 0
    @State private var draggingDrawer: Bool?
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var windowSize = CGSize(width: 402, height: 874)
    /// Whether the end of the transcript is in view (always, for one too short to scroll).
    @State private var atEnd = true
    /// Keeping the end in view while the keyboard rises.
    @State private var followingEnd = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                SettledRows(transcript: transcript, drawer: drawer)
                ForEach(transcript.liveRows) { row in
                    RowView(row: row, drawer: drawer).equatable()
                }
            }
            .padding(.top, Metrics.topSpace)
            .padding(.bottom, Metrics.bottomSpace)
            .animation(.spring(response: 0.38, dampingFraction: 0.82), value: transcript.layoutRevision)
        }
        .scrollPosition($position)
        // Opens at the latest message and keeps it in view as the transcript grows or the keyboard rises, but a
        // conversation too short to fill the screen starts at the top (and only moves up once the keyboard reaches it).
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .defaultScrollAnchor(.top, for: .alignment)
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: EndGeometry.self) { geometry in
            // Measured from the top of the content (`contentOffset` starts at minus the top inset, and
            // `containerSize` excludes the insets).
            EndGeometry(
                offset: geometry.contentOffset.y + geometry.contentInsets.top,
                end: max(0, geometry.contentSize.height - geometry.containerSize.height))
        } action: { _, geometry in
            if followingEnd, geometry.offset < geometry.end {
                position.scrollTo(y: geometry.end)
            } else {
                atEnd = geometry.offset >= geometry.end - Metrics.bottomSpace
            }
        }
        .onChange(of: keyboardRises) {
            // The size-change anchor keeps the end in view only for a transcript that already scrolled; one that fit
            // the screen but not the space above the keyboard is moved up with it, frame by frame as it rises.
            guard atEnd else { return }
            followingEnd = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.6))
                followingEnd = false
            }
        }
        .simultaneousGesture(drawerGesture)
        // From the whole window (ignoring the keyboard), so neither changes while the keyboard moves.
        .environment(\.transcriptHeight, windowSize.height)
        .environment(\.balloonMaxWidth, (windowSize.width - 2 * Metrics.margin) * Metrics.maxWidthFraction)
        .background {
            Color.clear
                .ignoresSafeArea()
                .onGeometryChange(for: CGSize.self, of: \.size) { windowSize = $0 }
        }
        .onReceive(NotificationCenter.default.publisher(for: PerformanceLog.scrollRequest)) { note in
            // Benchmark mode (`-bench`): scroll to an edge, as a person flicking through the history would.
            withAnimation(.smooth(duration: 1.2)) { position.scrollTo(edge: note.object as? Edge ?? .top) }
        }
    }

    /// Swiping left slides your balloons over and reveals each message's time.
    private var drawerGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if draggingDrawer == nil {
                    draggingDrawer = abs(value.translation.width) > abs(value.translation.height) && value.translation.width < 0
                }
                guard draggingDrawer == true else { return }
                let pull = min(0, value.translation.width)
                // Follows the finger up to the drawer's width, then resists.
                drawer = pull > -Metrics.drawerWidth
                    ? pull : -Metrics.drawerWidth - pow(-pull - Metrics.drawerWidth, 0.7)
            }
            .onEnded { _ in
                draggingDrawer = nil
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { drawer = 0 }
            }
    }
}

private struct EndGeometry: Equatable {
    /// The scroll offset, and the largest it can be (where the end of the transcript is in view).
    var offset, end: CGFloat
}

/// The settled rows in their own view, so a streaming update (which only changes `liveRows`) never re-diffs them.
struct SettledRows: View {
    let transcript: Transcript
    let drawer: CGFloat

    var body: some View {
        ForEach(transcript.settledRows) { row in
            RowView(row: row, drawer: drawer).equatable()
        }
    }
}

/// One row; equatable, so unchanged rows skip re-rendering when the transcript updates.
struct RowView: View, Equatable {
    let row: ChatRow
    let drawer: CGFloat

    var body: some View {
        switch row.item {
        case .timestamp(_, let date):
            TimestampView(date: date)
                .padding(.top, row.first ? 0 : Metrics.largeSpace)
                .padding(.bottom, 6)
        case .message(let message):
            MessageRow(message: message, tail: row.tail, drawer: drawer)
                .padding(.bottom, row.bottomSpacing)
                .transition(message.sender == .me ? .sent : .received)
        case .tool(let tool):
            ToolNote(tool: tool)
                .padding(.horizontal, Metrics.margin)
                .padding(.bottom, Metrics.nonContiguousSpace)
        case .typing:
            TypingIndicator()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, Metrics.margin)
                .transition(.typing)
        case .delivered:
            Text("Delivered")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, Metrics.margin + 4)
                .padding(.top, -Metrics.nonContiguousSpace + 2)
                .padding(.bottom, Metrics.nonContiguousSpace)
                .offset(x: drawer)
                .transition(.opacity)
        }
    }
}

/// The Liquid Glass entry bar, kept apart from the transcript so typing never re-renders it.
struct EntryBar: View {
    @Environment(AppModel.self) private var app
    let conversation: Conversation
    let busy: Bool
    @State private var draft = ""
    @FocusState private var composing: Bool

    var body: some View {
        GlassEffectContainer(spacing: Metrics.plusToField) {
            HStack(alignment: .bottom, spacing: Metrics.plusToField) {
                Menu {
                    Button("New Conversation", systemImage: "square.and.pencil") { Task { await app.newChat() } }
                    Button("Settings", systemImage: "gearshape") { app.showingSettings = true }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .medium))
                        .frame(width: Metrics.entryHeight, height: Metrics.entryHeight)
                }
                .tint(.secondary)
                .glassEffect(.regular.interactive(), in: .circle)

                HStack(alignment: .bottom, spacing: 0) {
                    TextField("Message", text: $draft, axis: .vertical)
                        .font(.system(size: 17))
                        .lineLimit(1...8)
                        .focused($composing)
                        .padding(.leading, Metrics.entryTextInset)
                        .padding(.trailing, 6)
                        .padding(.vertical, (Metrics.entryHeight - Metrics.lineHeight) / 2)
                        .onSubmit(send)
                    sendButton
                        .padding(.trailing, 4)
                        .padding(.bottom, 4)
                }
                .frame(minHeight: Metrics.entryHeight)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Metrics.entryHeight / 2))
            }
        }
        .padding(.horizontal, Metrics.entryMargin)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .onReceive(NotificationCenter.default.publisher(for: PerformanceLog.focusRequest)) { note in
            composing = note.object as? Bool ?? false
        }
        .task {
            // `-keyboardLoop`: show and hide the keyboard every two seconds, for recording its animation.
            guard ProcessInfo.processInfo.arguments.contains("-keyboardLoop") else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                composing.toggle()
            }
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasText {
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.messageBlue, in: .circle)
            }
            .transition(.scale(scale: 0.5).combined(with: .opacity))
        } else if busy {
            Button {
                Task { try? await conversation.abort() }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.secondary, in: .circle)
            }
            .transition(.scale(scale: 0.5).combined(with: .opacity))
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        withAnimation(.snappy(duration: 0.2)) { draft = "" }
        Task { await app.send(text) }
    }
}

// MARK: - Metrics

/// The transcript's layout values.
enum Metrics {
    /// How far a balloon sits from the screen edge.
    static let margin: CGFloat = 16
    static let contiguousSpace: CGFloat = 4
    static let nonContiguousSpace: CGFloat = 10
    static let largeSpace: CGFloat = 20
    static let topSpace: CGFloat = 15.67
    static let bottomSpace: CGFloat = 16
    static let maxWidthFraction: CGFloat = 0.85
    static let textVertical: CGFloat = 10
    /// The text's inset from the balloon's sides (the tail stays within the body's width).
    static let textHorizontal: CGFloat = 14
    static let minBalloonWidth: CGFloat = 46
    static let lineHeight: CGFloat = 20.29
    static let entryHeight: CGFloat = 40
    static let plusToField: CGFloat = 12
    static let entryTextInset: CGFloat = 14
    static let entryMargin: CGFloat = 16
    static let drawerWidth: CGFloat = 47.3
    static let bigEmojiSize: CGFloat = 48
}

private struct TranscriptHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 874
}

private struct BalloonMaxWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 316
}

extension EnvironmentValues {
    /// The window's height, for the blue gradient that runs from the top of the screen to the bottom.
    var transcriptHeight: CGFloat {
        get { self[TranscriptHeightKey.self] }
        set { self[TranscriptHeightKey.self] = newValue }
    }

    /// `balloonMaxWidthPercent` of the transcript's width, excluding the tail.
    var balloonMaxWidth: CGFloat {
        get { self[BalloonMaxWidthKey.self] }
        set { self[BalloonMaxWidthKey.self] = newValue }
    }
}

// MARK: - Items

/// What the transcript shows, in order.
enum ChatItem: Identifiable, Hashable {
    case timestamp(String, Date)
    case message(ChatMessage)
    case tool(ChatTool)
    case typing
    case delivered

    var id: String {
        switch self {
        case .timestamp(let id, _): "time-\(id)"
        case .message(let message): message.id
        case .tool(let tool): tool.id
        case .typing: "typing"
        case .delivered: "delivered"
        }
    }

    var sender: ChatMessage.Sender? {
        if case .message(let message) = self { return message.sender }
        return nil
    }

    /// When a committed message was sent, for timestamps.
    var date: Date? {
        if case .message(let message) = self, message.id != "streaming" { return message.date }
        return nil
    }

    /// The rows of one committed entry; computed once per entry.
    static func items(for entry: Entry) -> [ChatItem] {
        let id = "\(entry.id.rawValue)"
        switch entry.message {
        case .user(let message):
            return [.message(ChatMessage(id: id, sender: .me, text: message.text, date: message.timestamp))]
        case .assistant(let message):
            guard !message.text.isEmpty || message.errorMessage != nil else { return [] }
            return [.message(ChatMessage(
                id: id, sender: .agent, text: message.text, date: message.timestamp, error: message.errorMessage))]
        case .toolResult(let result):
            return [.tool(ChatTool(id: id, name: result.toolName, output: result.text, failed: result.isError, running: false))]
        default:
            return []
        }
    }

    /// The rows for what is happening now: running tools, the reply streaming in or the thinking bubble, and
    /// "Delivered" under your last message while the reply is on its way.
    static func liveItems(for view: ConversationView, after committed: [ChatItem]) -> [ChatItem] {
        var items: [ChatItem] = []
        for slot in view.live.tools where slot.status != .done {
            items.append(.tool(ChatTool(
                id: "live-\(slot.callId)", name: slot.name, output: slot.output ?? "", failed: false, running: true)))
        }
        if let partial = view.streamingMessage, !partial.text.isEmpty {
            items.append(.message(ChatMessage(id: "streaming", sender: .agent, text: partial.text, date: .now)))
        } else if view.isBusy, !view.live.tools.contains(where: { $0.status != .done }) {
            items.append(.typing)
        }
        if view.isBusy, items.isEmpty || items.allSatisfy({ if case .typing = $0 { true } else { false } }),
            case .message(let last)? = committed.last(where: { $0.sender != nil }), last.sender == .me,
            case .message(let final)? = committed.last, final.id == last.id
        {
            items.insert(.delivered, at: 0)
        }
        return items
    }
}

struct ChatMessage: Hashable {
    enum Sender { case me, agent }

    let id: String
    let sender: Sender
    let text: String
    let date: Date
    var error: String?

    /// One to three emoji and nothing else, shown large and without a balloon.
    var isBigEmoji: Bool {
        let characters = text.trimmingCharacters(in: .whitespaces)
        return !characters.isEmpty && characters.count <= 3
            && characters.allSatisfy { character in
                let scalars = character.unicodeScalars
                return scalars.contains { $0.properties.isEmojiPresentation }
                    || (scalars.count > 1 && scalars.first?.properties.isEmoji == true)
            }
    }
}

struct ChatTool: Hashable {
    let id: String
    let name: String
    let output: String
    let failed: Bool
    let running: Bool
}

// MARK: - Messages

/// One message, with its time waiting off the right edge for the swipe-left drawer.
struct MessageRow: View {
    let message: ChatMessage
    let tail: Bool
    let drawer: CGFloat
    @Environment(\.balloonMaxWidth) private var maxWidth

    private var mine: Bool { message.sender == .me }

    var body: some View {
        ZStack(alignment: .trailing) {
            Group {
                if message.isBigEmoji {
                    Text(message.text)
                        .font(.system(size: Metrics.bigEmojiSize))
                        .padding(.horizontal, 4)
                } else {
                    MessageBubble(message: message, tail: tail)
                }
            }
            .frame(maxWidth: maxWidth, alignment: mine ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
            .padding(.horizontal, Metrics.margin)
            .offset(x: mine ? drawer : 0)

            // The time, slid in from the right edge as the drawer opens.
            Text(message.date, format: .dateTime.hour().minute())
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize()
                .padding(.trailing, Metrics.margin)
                .offset(x: Metrics.drawerWidth + Metrics.margin + drawer)
                .opacity(drawer < 0 ? 1 : 0)
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    let tail: Bool
    @Environment(\.transcriptHeight) private var transcriptHeight
    @Environment(\.colorScheme) private var colorScheme

    private var mine: Bool { message.sender == .me }

    var body: some View {
        let _ = PerformanceLog.enabled ? PerformanceLog.balloonRenders += 1 : ()
        VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            if !message.text.isEmpty {
                Text(message.id == "streaming" ? StreamingMarkdown.shared.attributed(message.text) : Self.attributed(message.text))
                    .font(.system(size: 17))
                    .foregroundStyle(mine ? .white : .primary)
                    .tint(mine ? .white : .balloonLink)
                    .padding(.vertical, Metrics.textVertical)
                    .padding(.horizontal, Metrics.textHorizontal)
                    .frame(minWidth: Metrics.minBalloonWidth)
                    .padding(.bottom, tail ? BubbleShape.tailHeight : 0)
                    .background { fill }
                    .contentShape(.contextMenuPreview, BubbleShape(mine: mine, tail: tail))
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
                        ShareLink(item: message.text) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
            }
            if let error = message.error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.horizontal, 6)
            }
        }
    }

    @ViewBuilder
    private var fill: some View {
        let shape = BubbleShape(mine: mine, tail: tail)
        if mine {
            // The blue is a gradient pinned to the screen: balloons near the top are lighter. It is built from three
            // fills of the balloon's own shape, so nothing can slide out of place while the layout animates; only two
            // opacities follow the balloon's position. With the balloon spanning a fraction `h` of the window from a
            // fraction `p` down, the top colour, the bottom colour at opacity `p`, and a clear-to-bottom gradient at
            // opacity `h / (1 - p)` give exactly the window-wide gradient's colour at every point of the balloon.
            let height = max(transcriptHeight, 1)
            let (top, bottom): (Color, Color) = colorScheme == .dark ? (.blueTopDark, .blueBottomDark) : (.blueTop, .blueBottom)
            ZStack {
                shape.fill(top)
                shape.fill(bottom)
                    .visualEffect { content, proxy in
                        content.opacity(min(max(proxy.frame(in: .global).minY / height, 0), 1))
                    }
                shape.fill(LinearGradient(colors: [bottom.opacity(0), bottom], startPoint: .top, endPoint: .bottom))
                    .visualEffect { content, proxy in
                        let frame = proxy.frame(in: .global)
                        let start = min(max(frame.minY / height, 0), 1)
                        return content.opacity(start >= 1 ? 0 : min(frame.height / height / (1 - start), 1))
                    }
            }
        } else {
            shape.fill(Color.balloonGray)
        }
    }

    /// Inline Markdown (bold, italic, code, links), with links and phone numbers detected; links are underlined in
    /// white on blue.
    static func attributed(_ text: String) -> AttributedString {
        let key = text as NSString
        if let cached = attributedCache.object(forKey: key) { return cached.value }
        let started = ContinuousClock.now
        let value = makeAttributed(text, detectLinks: true)
        PerformanceLog.attributed(ContinuousClock.now - started)
        attributedCache.setObject(AttributedBox(value), forKey: key)
        return value
    }

    nonisolated static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue | NSTextCheckingResult.CheckingType.phoneNumber.rawValue)

    /// Parsing Markdown and detecting links is the costliest part of showing a balloon; each text is done once.
    nonisolated(unsafe) static let attributedCache: NSCache<NSString, AttributedBox> = {
        let cache = NSCache<NSString, AttributedBox>()
        cache.countLimit = 2000
        return cache
    }()

    nonisolated static func makeAttributed(_ text: String, detectLinks: Bool) -> AttributedString {
        var string = (try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        let plain = String(string.characters)
        if detectLinks, let detector {
            for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                guard let range = Range(match.range, in: plain),
                    let lower = AttributedString.Index(range.lowerBound, within: string),
                    let upper = AttributedString.Index(range.upperBound, within: string)
                else { continue }
                let url = match.url ?? match.phoneNumber.flatMap { URL(string: "tel:\($0.filter { !$0.isWhitespace })") }
                if string[lower..<upper].link == nil, let url { string[lower..<upper].link = url }
            }
        }
        for run in string.runs where run.link != nil {
            string[run.range].underlineStyle = .single
        }
        // Resolve Markdown's presentation intents to fonts once here, rather than leaving SwiftUI to interpret them
        // on every layout of the balloon.
        for run in string.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            var font = Font.system(
                size: 17, weight: intent.contains(.stronglyEmphasized) ? .semibold : .regular,
                design: intent.contains(.code) ? .monospaced : .default)
            if intent.contains(.emphasized) { font = font.italic() }
            string[run.range].font = font
            if intent.contains(.strikethrough) { string[run.range].strikethroughStyle = .single }
            string[run.range].inlinePresentationIntent = nil
        }
        return string
    }
}

/// Markdown for the reply streaming in, parsed off the main thread: parsing a long reply takes milliseconds, and doing
/// it on every update would drop frames. The balloon shows the latest parsed text, a few milliseconds behind the
/// stream. Each parse also detects links and fills the balloon cache, so the committed reply shows without parsing.
@MainActor @Observable
final class StreamingMarkdown {
    static let shared = StreamingMarkdown()

    private var parsed: (source: String, value: AttributedString)?
    @ObservationIgnored private var parsing = false
    @ObservationIgnored private var wanted: String?

    func attributed(_ text: String) -> AttributedString {
        if parsed?.source != text { request(text) }
        // Showing the last parse (rather than appending the newest text unformatted) keeps the balloon's runs stable,
        // which is much cheaper to lay out.
        guard let parsed, text.hasPrefix(parsed.source) else { return AttributedString(text) }
        return parsed.value
    }

    private func request(_ text: String) {
        wanted = text
        guard !parsing else { return }
        parsing = true
        Task {
            while let text = wanted, text != parsed?.source {
                wanted = nil
                let value = await Task.detached(priority: .userInitiated) {
                    let value = MessageBubble.makeAttributed(text, detectLinks: true)
                    MessageBubble.attributedCache.setObject(AttributedBox(value), forKey: text as NSString)
                    return value
                }.value
                parsed = (text, value)
            }
            parsing = false
        }
    }
}

nonisolated final class AttributedBox: Sendable {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}

/// The balloon outline: a body with 20.14pt continuous corners, and on the sender's side a tail that curls down out
/// of the bottom corner, hanging 6.83pt below the body. Without a tail it is just the body.
nonisolated struct BubbleShape: Shape {
    static let cornerRadius: CGFloat = 20.14
    static let tailHeight: CGFloat = 6.8342
    let mine: Bool
    let tail: Bool

    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let frameBottom = rect.height
        let bodyHeight = tail ? rect.height - Self.tailHeight : rect.height
        let body = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .path(in: CGRect(x: 0, y: 0, width: width, height: bodyHeight))
        var path = body
        if tail {
            // The continuous rectangle runs clockwise from the middle of the right edge: down the edge, round the bottom
            // corner (three curves), then along the bottom. Swap that corner for the tail, whose points are fixed
            // relative to the frame's bottom corner.
            func at(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: width + dx, y: frameBottom + dy) }
            var outline = Path()
            var skip = 0
            var replaced = false
            body.forEach { element in
                switch element {
                case .move(let point):
                    outline.move(to: point)
                case .line(let point):
                    outline.addLine(to: point)
                    if !replaced, abs(point.x - width) < 0.01, point.y > bodyHeight / 2 - 0.01 {
                        outline.addLine(to: CGPoint(x: width, y: max(point.y, frameBottom - 37.6292)))
                        outline.addCurve(to: at(-4.0571, -14.9686), control1: at(0, -22.6418), control2: at(-1.4252, -18.4194))
                        outline.addCurve(to: at(-7.7155, -11.2897), control1: at(-5.1236, -13.5704), control2: at(-6.3549, -12.3381))
                        outline.addCurve(to: at(-10.4935, -6.4277), control1: at(-9.6545, -9.7778), control2: at(-10.4935, -8.2004))
                        outline.addCurve(to: at(-8.5717, -1.8104), control1: at(-10.4935, -5.2361), control2: at(-10.2830, -4.0586))
                        outline.addCurve(to: at(-9.8579, -0.1203), control1: at(-7.7508, -0.7327), control2: at(-8.5747, 0.3672))
                        outline.addCurve(to: at(-18.1355, -4.8936), control1: at(-12.4969, -1.1225), control2: at(-15.5026, -2.9466))
                        outline.addCurve(to: at(-22.2300, -6.8215), control1: at(-20.4945, -6.6382), control2: at(-21.1230, -6.8145))
                        skip = 3
                        replaced = true
                    }
                case .curve(let point, let control1, let control2):
                    if skip > 0 { skip -= 1 } else { outline.addCurve(to: point, control1: control1, control2: control2) }
                case .quadCurve(let point, let control):
                    outline.addQuadCurve(to: point, control: control)
                case .closeSubpath:
                    outline.closeSubpath()
                }
            }
            if replaced { path = outline }
        }
        let placed = mine ? path : path.applying(CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -width, y: 0))
        return placed.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

// MARK: - Thinking

/// The thinking bubble: a 57.5 × 35 balloon with three 8.5pt dots that brighten in turn, and two small bubbles
/// trailing from its corner. It grows in when it appears.
struct TypingIndicator: View {
    @State private var shown = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Circle()
                .fill(Color.balloonGray)
                .frame(width: 5.5, height: 5.5)
                .offset(x: -5, y: 8)
                .scaleEffect(shown ? 1 : 0.2, anchor: .center)
            Circle()
                .fill(Color.balloonGray)
                .frame(width: 11.5, height: 11.5)
                .offset(x: -1.5, y: 3)
                .scaleEffect(shown ? 1 : 0.2, anchor: .center)
            TimelineView(.animation) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                HStack(spacing: 12.5 - 8.5) {
                    ForEach(0..<3) { index in
                        // A wave across the dots, about 1.4s around.
                        let phase = (sin((time / 1.4) * 2 * .pi - Double(index) * 0.75) + 1) / 2
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 8.5, height: 8.5)
                            .opacity(0.35 + 0.55 * phase)
                    }
                }
                .frame(width: 57.5, height: 35)
                .background(Color.balloonGray, in: .capsule)
                // A slow breath.
                .scaleEffect(1 + 0.03 * sin(time / 1.4 * 2 * .pi))
            }
            .scaleEffect(shown ? 1 : 0.3, anchor: .bottomLeading)
        }
        .padding(.bottom, 8)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7).delay(0.04)) { shown = true }
        }
    }
}

// MARK: - Transcript notes

/// A tool call, as a small note in the transcript; tap to see its output.
struct ToolNote: View {
    let tool: ChatTool
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 6) {
            Button {
                withAnimation(.smooth(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    if tool.running {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: tool.failed ? "exclamationmark.triangle.fill" : Self.symbol(for: tool.name))
                            .foregroundStyle(tool.failed ? .orange : .secondary)
                    }
                    Text(Self.title(for: tool))
                    if !tool.output.isEmpty {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(tool.output.isEmpty)

            if expanded {
                Text(tool.output.prefix(4000))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.balloonGray.opacity(0.6), in: .rect(cornerRadius: 14))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity)
    }

    static func title(for tool: ChatTool) -> String {
        let name = tool.name.replacingOccurrences(of: "_", with: " ")
        if tool.running { return "Running \(name)…" }
        return tool.failed ? "\(name.capitalized) failed" : "Used \(name)"
    }

    static func symbol(for name: String) -> String {
        switch name {
        case "run_shortcut", "list_shortcuts": "square.2.layers.3d"
        case "read", "ls", "find", "grep": "doc.text.magnifyingglass"
        case "write", "edit": "square.and.pencil"
        case "load_extension": "puzzlepiece.extension"
        case "current_time": "clock"
        default: "wrench.and.screwdriver"
        }
    }
}

/// "Today 13:06", centred, with the day in semibold.
struct TimestampView: View {
    let date: Date

    var body: some View {
        Text("\(Text(Self.day(date)).fontWeight(.semibold)) \(Text(date, format: .dateTime.hour().minute()))")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
    }

    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

// MARK: - Transitions

extension AnyTransition {
    /// A sent message rises from the entry bar into place.
    static var sent: AnyTransition {
        .asymmetric(
            insertion: .offset(y: 44).combined(with: .scale(scale: 0.92, anchor: .bottomTrailing)).combined(with: .opacity),
            removal: .opacity)
    }

    /// A reply grows out of the thinking bubble's corner.
    static var received: AnyTransition {
        .asymmetric(insertion: .scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity), removal: .opacity)
    }

    static var typing: AnyTransition {
        .asymmetric(insertion: .identity, removal: .scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity))
    }
}

// MARK: - Colours

extension Color {
    /// The blue balloon gradient, top to bottom, light and dark.
    static let blueTop = Color(red: 0.353, green: 0.784, blue: 0.980)
    static let blueBottom = Color(red: 0.0, green: 0.533, blue: 1.0)
    static let blueTopDark = Color(red: 0.251, green: 0.612, blue: 1.0)
    static let blueBottomDark = Color(red: 0.0, green: 0.569, blue: 1.0)
    /// The solid blue of the send button.
    static let messageBlue = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.0, green: 0.569, blue: 1.0, alpha: 1) : UIColor(red: 0.0, green: 0.533, blue: 1.0, alpha: 1)
    })
    /// The gray balloon.
    static let balloonGray = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.151, green: 0.151, blue: 0.161, alpha: 1) : UIColor(red: 0.915, green: 0.915, blue: 0.920, alpha: 1)
    })
    /// Links in gray balloons.
    static let balloonLink = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.035, green: 0.518, blue: 1.0, alpha: 1) : UIColor(red: 0.0, green: 0.478, blue: 1.0, alpha: 1)
    })
}

struct KeyboardState: Equatable {
    /// How far the keyboard rises above the bottom safe area.
    var overlap: CGFloat = 0
    /// How many times the keyboard has risen in its own animation (not following a finger).
    var rises = 0
}

/// How far the keyboard rises above the bottom safe area, kept current frame by frame: while it slides in or out (in
/// the keyboard's own animation) and while it follows a finger swiping it away.
private struct KeyboardTracker: UIViewRepresentable {
    @Binding var state: KeyboardState

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        updateUIView(probe, context: context)
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.onChange = { overlap, rose in
            if state.overlap != overlap { state.overlap = overlap }
            if rose { state.rises += 1 }
        }
    }

    /// Shows and hides follow the keyboard's frame-change notification, which comes just before the keyboard starts
    /// moving (as SwiftUI's own keyboard avoidance does); drags follow the keyboard's layout guide, which re-lays
    /// this view out on every frame while a finger moves the keyboard (and sends no notifications).
    final class Probe: UIView {
        var onChange: (_ overlap: CGFloat, _ rose: Bool) -> Void = { _, _ in }
        private let marker = UIView()
        private var last: CGFloat = 0

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            keyboardLayoutGuide.usesBottomSafeArea = false
            marker.isHidden = true
            marker.translatesAutoresizingMaskIntoConstraints = false
            addSubview(marker)
            NSLayoutConstraint.activate([
                marker.leadingAnchor.constraint(equalTo: leadingAnchor),
                marker.widthAnchor.constraint(equalToConstant: 1),
                marker.heightAnchor.constraint(equalToConstant: 1),
                marker.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
            ])
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyboardWillMove), name: UIResponder.keyboardWillChangeFrameNotification, object: nil
            )
        }

        required init?(coder: NSCoder) { fatalError() }

        @objc private func keyboardWillMove(_ note: Notification) {
            guard let window, let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let top = window.convert(end, from: window.screen.coordinateSpace).minY
            // The keyboard's own curve, so the transcript and entry bar move with it.
            update(overlap(keyboardTop: top), animation: .interpolatingSpring(mass: 3, stiffness: 1000, damping: 500))
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Animated changes were already handled by the notification.
            guard let window, UIView.inheritedAnimationDuration == 0 else { return }
            // In the window's space, so the result doesn't depend on where SwiftUI has put this view.
            update(overlap(keyboardTop: convert(marker.frame, to: window).minY), animation: nil)
        }

        private func overlap(keyboardTop: CGFloat) -> CGFloat {
            guard let window else { return 0 }
            return max(0, (window.bounds.maxY - window.safeAreaInsets.bottom - keyboardTop).rounded())
        }

        private func update(_ overlap: CGFloat, animation: Animation?) {
            guard overlap != last else { return }
            let rose = animation != nil && overlap > last
            last = overlap
            var transaction = Transaction(animation: animation)
            transaction.disablesAnimations = animation == nil
            withTransaction(transaction) { onChange(overlap, rose) }
        }
    }
}
