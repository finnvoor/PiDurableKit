import PiDurableKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Group {
                if let conversation = app.conversation {
                    ChatView(conversation: conversation)
                } else {
                    ProgressView()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Button { app.showingSettings = true } label: { ContactHeader(title: app.availableModels.first { $0.ref == app.model }?.name ?? app.model?.modelId) }
                        .buttonStyle(.plain)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Conversation", systemImage: "square.and.pencil") { Task { await app.newChat() } }
                }
            }
            .sheet(isPresented: $app.showingSettings) { AccountsView() }
            .safeAreaInset(edge: .top) {
                if let status = app.status {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(in: .capsule)
                        .padding(.horizontal)
                        .onTapGesture { app.status = nil }
                }
            }
            .overlay {
                if app.conversation != nil, app.signedIn.isEmpty, !app.demo {
                    ContentUnavailableView {
                        Label("No Account", systemImage: "person.crop.circle.badge.questionmark")
                    } description: {
                        Text("Sign in to a model provider to start chatting.")
                    } actions: {
                        Button("Sign In") { app.showingSettings = true }.buttonStyle(.glassProminent)
                    }
                }
            }
        }
        .task {
            await app.start()
            let arguments = ProcessInfo.processInfo.arguments
            // Development shortcuts: `-apiKey <provider> <key>`, `-signIn <provider>`.
            if let index = arguments.firstIndex(of: "-apiKey"), arguments.indices.contains(index + 2) {
                await app.setAPIKey(arguments[index + 2], for: ProviderID(arguments[index + 1]))
            }
            if let index = arguments.firstIndex(of: "-signIn"), arguments.indices.contains(index + 1),
                let account = app.loginProviders.first(where: { $0.id.rawValue == arguments[index + 1] })
            {
                await app.signIn(to: account)
            }
        }
    }
}

struct AccountsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(app.loginProviders) { provider in
                        AccountRow(provider: provider)
                    }
                } header: {
                    Text("Accounts")
                } footer: {
                    Text("Every provider pi can sign in to. Tokens are kept in the Keychain and refresh automatically.")
                }

                Section("Agent") {
                    NavigationLink {
                        ShortcutsView()
                    } label: {
                        Label("Shortcuts", systemImage: "square.2.layers.3d")
                    }
                }

                if !app.availableModels.isEmpty {
                    Section("Model") {
                        NavigationLink {
                            ModelPickerView()
                        } label: {
                            LabeledContent("Model") {
                                Text(app.availableModels.first { $0.ref == app.model }?.name ?? app.model?.modelId ?? "None")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

struct AccountRow: View {
    @Environment(AppModel.self) private var app
    let provider: ProviderInfo

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if app.signingIn == provider.id {
                ProgressView()
            } else if app.signedIn[provider.id] != nil {
                Button("Sign Out", role: .destructive) { Task { await app.signOut(of: provider.id) } }
                    .buttonStyle(.borderless)
            } else {
                Button("Sign In") { Task { await app.signIn(to: provider) } }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(app.signingIn != nil)
            }
        }
    }

    private var status: String {
        switch app.signedIn[provider.id] {
        case .oauth?: "Signed in"
        case .some: "API key"
        case nil: provider.oauth?.name ?? provider.name
        }
    }
}

/// The agent as a Messages contact: a monogram and its name, with the model underneath.
struct ContactHeader: View {
    /// The model's display name, such as "Claude Opus 4.8".
    let title: String?

    var body: some View {
        VStack(spacing: 3) {
            Text("Pi")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(
                    LinearGradient(colors: [Color(white: 0.66), Color(white: 0.52)], startPoint: .top, endPoint: .bottom),
                    in: .circle)
            HStack(spacing: 2) {
                Text(title ?? "PiChat")
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .glassEffect(in: .capsule)
        }
        .padding(.top, 14)
    }
}

/// Every model of the signed-in providers, grouped by provider in catalog order, searched with pi's fuzzy match.
struct ModelPickerView: View {
    @Environment(AppModel.self) private var app
    @State private var search = ""

    private var groups: [(provider: ProviderID, models: [ModelInfo])] {
        let matches = ModelSelection.search(app.availableModels, for: search)
        let ordered = search.trimmingCharacters(in: .whitespaces).isEmpty
            ? app.availableModels : app.availableModels.filter { matches.contains($0) }
        return Dictionary(grouping: ordered, by: \.provider)
            .map { (provider: $0.key, models: $0.value) }
            .sorted { $0.provider.rawValue < $1.provider.rawValue }
    }

    var body: some View {
        List {
            ForEach(groups, id: \.provider) { group in
                Section(providerName(group.provider)) {
                    ForEach(group.models) { info in
                        Button {
                            Task { await app.use(info.ref) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(info.name).foregroundStyle(.primary)
                                    Text(details(info)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if info.ref == app.model {
                                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint)
                                }
                            }
                            .contentShape(.rect)
                        }
                    }
                }
            }
        }
        .overlay {
            if !search.isEmpty, groups.isEmpty { ContentUnavailableView.search(text: search) }
        }
        .navigationTitle("Model")
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Models")
    }

    private func providerName(_ id: ProviderID) -> String {
        app.loginProviders.first { $0.id == id }?.name ?? id.rawValue
    }

    private func details(_ info: ModelInfo) -> String {
        var parts = [info.modelId]
        if info.contextWindow > 0 { parts.append("\(info.contextWindow / 1000)K context") }
        if info.reasoning { parts.append("reasoning") }
        return parts.joined(separator: " · ")
    }
}
