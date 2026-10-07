import SwiftUI

/// Setting up the bridge, and choosing which shortcuts the agent may run.
struct ShortcutsView: View {
    @State private var bridge = ShortcutBridge.shared
    @State private var loading = false
    @State private var error: String?
    @State private var search = ""
    @Environment(\.scenePhase) private var scenePhase

    private var ready: Bool { bridge.notificationsAllowed && bridge.connected && bridge.notificationsQuiet }

    private var matches: [String] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return bridge.shortcuts }
        return bridge.shortcuts.filter { $0.localizedStandardContains(query) }
    }

    var body: some View {
        List {
            if !ready || bridge.shortcuts.isEmpty {
                setup
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            if search.isEmpty, !bridge.allowed.isEmpty {
                Section {
                    ForEach(bridge.allowed.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) {
                        ShortcutRow(name: $0, allowed: binding(for: $0))
                    }
                } header: {
                    Text("Allowed")
                } footer: {
                    Text("The agent can run these with input it chooses, and reads what they return.")
                }
            }
            if !bridge.shortcuts.isEmpty {
                Section {
                    ForEach(matches, id: \.self) { ShortcutRow(name: $0, allowed: binding(for: $0)) }
                } header: {
                    Text(search.isEmpty ? "All Shortcuts" : "Results")
                }
            }
        }
        .overlay {
            if !search.isEmpty, matches.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .navigationTitle("Shortcuts")
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Shortcuts")
        .refreshable { await load() }
        .toolbar {
            if ready {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
                        ShareLink(item: ShortcutBridge.bridgeShortcut, preview: SharePreview("PiChat Bridge")) {
                            Label("Reinstall PiChat Bridge", systemImage: "square.and.arrow.down")
                        }
                        if !bridge.allowed.isEmpty {
                            Button("Disallow All", systemImage: "xmark.circle", role: .destructive) { bridge.allowed = [] }
                        }
                    } label: {
                        if loading { ProgressView() } else { Image(systemName: "ellipsis") }
                    }
                }
            }
        }
        .task(id: scenePhase) {
            await bridge.refreshNotificationStatus()
            if ready, bridge.shortcuts.isEmpty, !loading { await load() }
        }
    }

    private var setup: some View {
        Section {
            SetupStep(number: 1, title: "Allow notifications", done: bridge.notificationsAllowed) {
                Button("Allow") { Task { await bridge.requestNotifications() } }
            }
            SetupStep(
                number: 2, title: "Hide them from the Lock Screen", done: bridge.notificationsQuiet,
                detail: "In PiChat's notification settings, turn off Lock Screen and Banners and leave Notification Center on. Requests to run shortcuts then never show up."
            ) {
                Button("Open") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .disabled(!bridge.notificationsAllowed)
            }
            SetupStep(number: 3, title: "Add PiChat Bridge to Shortcuts", done: bridge.connected) {
                ShareLink(item: ShortcutBridge.bridgeShortcut, preview: SharePreview("PiChat Bridge")) {
                    Text("Add")
                }
            }
            SetupStep(
                number: 4, title: "Turn on its automation", done: bridge.connected,
                detail: "In Shortcuts, open PiChat Bridge, turn on the notification automation and set it to Run Immediately. Run the shortcut once and allow it to access PiChat."
            ) { EmptyView() }
            SetupStep(number: 5, title: "Load your shortcuts", done: !bridge.shortcuts.isEmpty) {
                Button {
                    Task { await load() }
                } label: {
                    if loading { ProgressView() } else { Text("Load") }
                }
                .disabled(loading || !bridge.notificationsAllowed)
            }
        } header: {
            Text("Set Up")
        } footer: {
            Text("PiChat runs shortcuts through the PiChat Bridge shortcut's notification automation: it posts a quiet notification, the automation runs the shortcut, and PiChat removes the notification right away.")
        }
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { bridge.allowed.contains(name) },
            set: { allowed in
                withAnimation {
                    if allowed { bridge.allowed.insert(name) } else { bridge.allowed.remove(name) }
                }
            }
        )
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            try await bridge.refreshShortcuts()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ShortcutRow: View {
    let name: String
    @Binding var allowed: Bool

    var body: some View {
        Toggle(isOn: $allowed) {
            Label {
                Text(name).lineLimit(2)
            } icon: {
                Image(systemName: "square.2.layers.3d.fill")
                    .foregroundStyle(allowed ? Color.accentColor : .secondary)
            }
        }
    }
}

private struct SetupStep<Action: View>: View {
    let number: Int
    let title: String
    let done: Bool
    var detail: String?
    @ViewBuilder let action: Action

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title3)
                .foregroundStyle(done ? Color.green : .secondary)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(done ? .secondary : .primary)
                if let detail, !done {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if !done {
                action.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
            }
        }
    }
}
