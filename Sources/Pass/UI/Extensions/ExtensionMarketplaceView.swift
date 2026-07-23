import AppKit
import SwiftUI

/// App-only marketplace: Cloudflare stores discovery metadata, while executable content stays
/// in its public Git repository and still enters Pass through the normal disabled/review flow.
struct ExtensionMarketplaceView: View {
    private enum Scope: String, CaseIterable, Identifiable {
        case discover = "Discover"
        case mine = "My listings"
        var id: Self { self }
    }

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var scope: Scope = .discover
    @State private var query = ""
    @State private var items: [MarketplaceExtension] = []
    @State private var selectedID: String?
    @State private var nextCursor: String?
    @State private var loading = false
    @State private var loadingMore = false
    @State private var listTask: Task<Void, Never>?
    @State private var loadRevision = 0
    @State private var appliedQuery = ""
    @State private var appliedScope: Scope = .discover
    @State private var message: String?
    @State private var messageIsError = false
    @State private var editorSeed: MarketplaceEditorSeed?
    @State private var deleting: MarketplaceExtension?
    @State private var reporting: MarketplaceExtension?
    @State private var installingID: String?

    private var selected: MarketplaceExtension? {
        items.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            marketContent
        }
        .frame(width: 900, height: 680)
        .onAppear { startLoad(reset: true) }
        .onChange(of: appModel.remoteUsesPublicCredentials) { _, isSignedIn in
            if !isSignedIn && scope == .mine { scope = .discover }
            else { startLoad(reset: true) }
        }
        .onDisappear { cancelListLoad() }
        .sheet(item: $editorSeed) { seed in
            MarketplaceEditorView(seed: seed, installed: appModel.extensions?.loaded ?? []) { draft in
                try await save(seed: seed, draft: draft)
            }
        }
        .alert("Remove marketplace listing?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), presenting: deleting) { item in
            Button("Remove", role: .destructive) { Task { await delete(item) } }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { item in
            Text("\(item.name) will disappear from the market. Installed copies and the Git repository are not deleted.")
        }
        .confirmationDialog("Report extension", isPresented: Binding(
            get: { reporting != nil }, set: { if !$0 { reporting = nil } }
        ), titleVisibility: .visible) {
            ForEach(["malware", "spam", "misleading", "copyright", "other"], id: \.self) { reason in
                Button(reason.capitalized) { Task { await report(reason: reason) } }
            }
            Button("Cancel", role: .cancel) { reporting = nil }
        } message: {
            Text("Reports are tied to your account and visible only to marketplace moderators.")
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.teal.opacity(0.14))
                Image(systemName: "shippingbox.and.arrow.backward.fill")
                    .foregroundStyle(.teal)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("Extension Market").font(.system(size: 17, weight: .semibold))
                Text("Source-visible tools, shared by Pass users")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if appModel.remoteUsesPublicCredentials {
                Button {
                    startPublishing()
                } label: {
                    Label("Publish", systemImage: "plus")
                }
                .disabled(appModel.extensions?.loaded.isEmpty ?? true)
            } else {
                Button("Sign in") { appModel.signInForRemoteAccess() }
            }
            Button("Done") { dismiss() }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var marketContent: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    Picker("Scope", selection: $scope) {
                        Text(Scope.discover.rawValue).tag(Scope.discover)
                        if appModel.remoteUsesPublicCredentials {
                            Text(Scope.mine.rawValue).tag(Scope.mine)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    TextField("Search names, descriptions, and tags", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { startLoad(reset: true) }
                }
                .padding(12)
                Divider()
                if loading && items.isEmpty {
                    Spacer(); ProgressView(); Spacer()
                } else if items.isEmpty {
                    ContentUnavailableView {
                        Label(scope == .mine ? "No published extensions" : "No extensions found",
                              systemImage: scope == .mine ? "shippingbox" : "magnifyingglass")
                    } description: {
                        Text(messageIsError
                             ? (message ?? "The marketplace could not be loaded.")
                             : (scope == .mine
                                ? "Publish an installed Git extension to list it here."
                                : "Try a different search."))
                    } actions: {
                        if messageIsError {
                            Button("Retry") { startLoad(reset: true) }
                        }
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(items) { item in
                                marketRow(item)
                            }
                            if nextCursor != nil {
                                Button {
                                    startLoad(reset: false)
                                } label: {
                                    if loadingMore { ProgressView().controlSize(.small) }
                                    else { Text("Load more") }
                                }
                                .buttonStyle(.borderless).padding(10).disabled(loadingMore)
                            }
                        }
                        .padding(8)
                    }
                }
            }
            .frame(width: 330)
            .background(Color.primary.opacity(0.018))
            Divider()
            Group {
                if let selected { detail(selected) }
                else {
                    ContentUnavailableView("Choose an extension", systemImage: "puzzlepiece.extension",
                                           description: Text("Inspect its permissions and source before installing."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: scope) { _, _ in startLoad(reset: true) }
    }

    private func marketRow(_ item: MarketplaceExtension) -> some View {
        Button {
            selectedID = item.id
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text(item.version).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Text(item.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 7) {
                    if let category = item.category {
                        Text(category.uppercased()).font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.teal)
                    }
                    Label("\(item.installCount)", systemImage: "arrow.down.circle")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                    if item.isOwner {
                        Text("YOURS").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                    }
                    if item.isHidden {
                        Text("HIDDEN").font(.system(size: 8, weight: .bold)).foregroundStyle(.orange)
                    }
                    if item.canModerate, let reportCount = item.reportCount, reportCount > 0 {
                        Label("\(reportCount)", systemImage: "flag.fill")
                            .font(.system(size: 8, weight: .bold)).foregroundStyle(.red)
                    }
                }
            }
            .padding(10)
            .background(selectedID == item.id ? Color.accentColor.opacity(0.13) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func detail(_ item: MarketplaceExtension) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.system(size: 24, weight: .semibold))
                        Text("v\(item.version) · by \(item.owner.displayName ?? "Pass user")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if item.isOwner || item.canModerate {
                        Menu {
                            if item.isOwner {
                                Button("Edit listing", systemImage: "pencil") { editorSeed = .init(item: item) }
                            }
                            if item.isOwner || item.canModerate {
                                Button("Remove listing", systemImage: "trash", role: .destructive) { deleting = item }
                            }
                            if item.canModerate {
                                Divider()
                                Button(item.isHidden ? "Restore to market" : "Hide from market",
                                       systemImage: item.isHidden ? "eye" : "eye.slash") {
                                    Task { await moderate(item, hidden: !item.isHidden) }
                                }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                    if appModel.remoteUsesPublicCredentials && !item.isOwner {
                        Button { reporting = item } label: { Image(systemName: "flag") }
                            .buttonStyle(.borderless).help("Report this extension")
                    }
                    if appModel.remoteUsesPublicCredentials {
                        Button {
                            Task { await install(item) }
                        } label: {
                            if installingID == item.id { ProgressView().controlSize(.small) }
                            else { Label("Install", systemImage: "square.and.arrow.down") }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(installingID != nil)
                    } else {
                        Button("Sign in to install") { appModel.signInForRemoteAccess() }
                            .buttonStyle(.borderedProminent)
                    }
                }

                // The market's visual anchor: provenance and execution risk remain adjacent,
                // so popularity can never visually outrank trust.
                HStack(spacing: 10) {
                    Label("Git source", systemImage: "chevron.left.forwardslash.chevron.right")
                    Divider().frame(height: 18)
                    Label("Disabled after install", systemImage: "shield.lefthalf.filled")
                    Divider().frame(height: 18)
                    Label("\(item.installCount) installs", systemImage: "arrow.down.circle")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color.teal.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if item.canModerate, let reportCount = item.reportCount, reportCount > 0 {
                    Label("\(reportCount) unresolved report\(reportCount == 1 ? "" : "s") — inspect the source and hide the listing if needed.",
                          systemImage: "flag.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.summary).font(.system(size: 14, weight: .medium))
                    if let description = item.description, !description.isEmpty {
                        Text(description).font(.system(size: 12)).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                detailGroup("Permissions") {
                    let permissions = item.manifest.permissions ?? []
                    if permissions.isEmpty { Text("No permissions declared").foregroundStyle(.secondary) }
                    else {
                        ForEach(permissions.sorted(), id: \.self) { permission in
                            Label(permission, systemImage: permission.hasPrefix("run:") ? "terminal" : "checkmark.shield")
                                .font(.system(size: 11, design: .monospaced))
                        }
                    }
                }

                detailGroup("Source") {
                    Text(item.repositoryURL).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        Button("Copy URL") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.repositoryURL, forType: .string)
                        }
                        if let url = ExtensionSharingService.webURL(for: item.repositoryURL) {
                            Button("View repository") { NSWorkspace.shared.open(url) }
                        }
                    }
                }

                if !item.tags.isEmpty {
                    detailGroup("Tags") {
                        Text(item.tags.map { "#\($0)" }.joined(separator: "  "))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }

                if let message {
                    Label(message, systemImage: messageIsError ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(messageIsError ? Color.orange : Color.green)
                }
            }
            .padding(24)
        }
    }

    private func detailGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @discardableResult
    private func startLoad(reset: Bool) -> Task<Void, Never>? {
        let revision: Int
        let requestedQuery: String
        let requestedScope: Scope
        let requestedCursor: String?
        if reset {
            listTask?.cancel()
            loadRevision += 1
            revision = loadRevision
            requestedQuery = query
            requestedScope = scope
            requestedCursor = nil
            loading = true
            loadingMore = false
        } else {
            guard !loading, !loadingMore, let nextCursor else { return nil }
            revision = loadRevision
            requestedQuery = appliedQuery
            requestedScope = appliedScope
            requestedCursor = nextCursor
            loadingMore = true
        }

        let task = Task { @MainActor in
            await performLoad(
                reset: reset,
                revision: revision,
                query: requestedQuery,
                scope: requestedScope,
                cursor: requestedCursor)
        }
        listTask = task
        return task
    }

    private func performLoad(
        reset: Bool,
        revision: Int,
        query requestedQuery: String,
        scope requestedScope: Scope,
        cursor requestedCursor: String?
    ) async {
        defer {
            if revision == loadRevision {
                if reset { loading = false } else { loadingMore = false }
            }
        }
        do {
            let page = try await appModel.extensionMarketplace.list(
                query: requestedQuery, ownedOnly: requestedScope == .mine, cursor: requestedCursor)
            guard !Task.isCancelled, revision == loadRevision else { return }
            items = reset ? page.extensions : items + page.extensions
            nextCursor = page.nextCursor
            if reset {
                appliedQuery = requestedQuery
                appliedScope = requestedScope
                if !items.contains(where: { $0.id == selectedID }) {
                    selectedID = items.first?.id
                }
            }
            message = nil
            messageIsError = false
        } catch {
            guard !Task.isCancelled, revision == loadRevision else { return }
            if reset { items = []; selectedID = nil }
            message = error.localizedDescription
            messageIsError = true
        }
    }

    private func cancelListLoad() {
        loadRevision += 1
        listTask?.cancel()
        listTask = nil
        loading = false
        loadingMore = false
    }

    private func reloadList() async {
        if let task = startLoad(reset: true) {
            await task.value
        }
    }

    private func startPublishing() {
        guard let ext = appModel.extensions?.loaded.first else { return }
        editorSeed = .init(local: ext)
    }

    private func save(seed: MarketplaceEditorSeed, draft: MarketplaceExtensionDraft) async throws {
        if let marketID = seed.marketID {
            _ = try await appModel.extensionMarketplace.update(id: marketID, draft: draft)
        } else {
            _ = try await appModel.extensionMarketplace.publish(draft)
        }
        editorSeed = nil
        if scope == .mine {
            await reloadList()
        } else {
            // The scope change starts exactly one reset through its onChange handler.
            scope = .mine
        }
    }

    private func install(_ item: MarketplaceExtension) async {
        installingID = item.id
        defer { installingID = nil }
        let root = appModel.extensions?.revealDirectory() ?? ExtensionStore.defaultDirectory
        let result = await Task.detached {
            ExtensionSharingService.install(
                repository: item.repositoryURL, into: root, expectedManifest: item.manifest)
        }.value
        switch result {
        case .success(let installed):
            appModel.extensions?.prepareNewInstallation(installed.id)
            appModel.extensions?.reload()
            try? await appModel.extensionMarketplace.recordInstall(id: item.id)
            await reloadList()
            message = "Installed \(installed.name) — review its files and permissions in Settings before enabling."
            messageIsError = false
        case .failure(let error):
            message = error.message
            messageIsError = true
        }
    }

    private func delete(_ item: MarketplaceExtension) async {
        deleting = nil
        do {
            try await appModel.extensionMarketplace.delete(id: item.id)
            await reloadList()
        } catch { message = error.localizedDescription; messageIsError = true }
    }

    private func report(reason: String) async {
        guard let item = reporting else { return }
        reporting = nil
        do {
            try await appModel.extensionMarketplace.report(id: item.id, reason: reason)
            message = "Report submitted. Thank you."
            messageIsError = false
        } catch { message = error.localizedDescription; messageIsError = true }
    }

    private func moderate(_ item: MarketplaceExtension, hidden: Bool) async {
        do {
            let updated = try await appModel.extensionMarketplace.setHidden(id: item.id, hidden: hidden)
            if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = updated }
            message = hidden ? "Extension hidden from public discovery." : "Extension restored to public discovery."
            messageIsError = false
        } catch { message = error.localizedDescription; messageIsError = true }
    }
}

private struct MarketplaceEditorSeed: Identifiable {
    var marketID: String?
    var manifest: ExtensionManifest
    var repositoryURL: String
    var summary: String
    var description: String
    var category: String
    var tags: [String]
    var id: String { marketID ?? "new-\(manifest.id)" }

    init(local: ExtensionStore.Loaded) {
        marketID = nil
        manifest = local.manifest
        repositoryURL = ""
        summary = local.manifest.description ?? ""
        description = ""
        category = "Productivity"
        tags = []
    }

    init(item: MarketplaceExtension) {
        marketID = item.id
        manifest = item.manifest
        repositoryURL = item.repositoryURL
        summary = item.summary
        description = item.description ?? ""
        category = item.category ?? ""
        tags = item.tags
    }
}

private struct MarketplaceEditorView: View {
    let seed: MarketplaceEditorSeed
    let installed: [ExtensionStore.Loaded]
    let onSave: (MarketplaceExtensionDraft) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedLocalID: String
    @State private var manifest: ExtensionManifest
    @State private var repositoryURL: String
    @State private var summary: String
    @State private var description: String
    @State private var category: String
    @State private var tags: String
    @State private var saving = false
    @State private var message: String?

    init(seed: MarketplaceEditorSeed, installed: [ExtensionStore.Loaded],
         onSave: @escaping (MarketplaceExtensionDraft) async throws -> Void) {
        self.seed = seed
        self.installed = installed
        self.onSave = onSave
        _selectedLocalID = State(initialValue: seed.manifest.id)
        _manifest = State(initialValue: seed.manifest)
        _repositoryURL = State(initialValue: seed.repositoryURL)
        _summary = State(initialValue: seed.summary)
        _description = State(initialValue: seed.description)
        _category = State(initialValue: seed.category)
        _tags = State(initialValue: seed.tags.joined(separator: ", "))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(seed.marketID == nil ? "Publish extension" : "Edit listing")
                        .font(.system(size: 17, weight: .semibold))
                    Text("The Git repository remains the downloadable source of truth.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button(seed.marketID == nil ? "Publish" : "Save") { save() }
                    .buttonStyle(.borderedProminent).disabled(!canSave || saving)
            }
            .padding(18)
            Divider()
            Form {
                if seed.marketID == nil {
                    Picker("Installed extension", selection: $selectedLocalID) {
                        ForEach(installed) { Text($0.manifest.name).tag($0.id) }
                    }
                    .onChange(of: selectedLocalID) { _, id in selectLocal(id) }
                }
                Section("Listing") {
                    LabeledContent("Name", value: manifest.name)
                    LabeledContent("Version", value: manifest.version ?? "Missing in manifest")
                    if seed.marketID != nil, let local = matchingInstalled {
                        if local.manifest == manifest {
                            Label("Listing matches the installed manifest", systemImage: "checkmark.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            HStack {
                                Label("Installed v\(local.manifest.version ?? "unknown") is available",
                                      systemImage: "arrow.triangle.2.circlepath")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Use installed manifest") { manifest = local.manifest }
                            }
                        }
                    }
                    TextField("One-line summary", text: $summary)
                    TextField("Category", text: $category)
                    TextField("Tags, comma separated", text: $tags)
                    TextEditor(text: $description).frame(minHeight: 90)
                }
                Section("Git source") {
                    TextField("https://github.com/you/extension.git", text: $repositoryURL)
                        .font(.system(size: 11, design: .monospaced))
                        .disabled(seed.marketID != nil)
                    Text("The repository root must contain the same extension.json. Pass validates it again after installation.")
                        .font(.caption).foregroundStyle(.secondary)
                    if seed.marketID != nil {
                        Text("Repository and extension id are fixed after publishing so install history cannot be transferred to different code.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Your Pass account is shown as the publisher. Repository ownership is community-moderated; publish only sources you control or are authorized to distribute.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Declared permissions") {
                    Text((manifest.permissions ?? []).sorted().joined(separator: ", ").ifEmpty("None"))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                if let message {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 570, height: 610)
        .task(id: selectedLocalID) {
            if seed.marketID == nil { await loadRemoteURL(for: selectedLocalID) }
        }
    }

    private var canSave: Bool {
        let version = manifest.version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !version.isEmpty
    }

    private var matchingInstalled: ExtensionStore.Loaded? {
        installed.first { $0.id == seed.manifest.id }
    }

    private func selectLocal(_ id: String) {
        guard let local = installed.first(where: { $0.id == id }) else { return }
        manifest = local.manifest
        summary = local.manifest.description ?? ""
        repositoryURL = ""
    }

    private func loadRemoteURL(for requestedID: String) async {
        guard let local = installed.first(where: { $0.id == requestedID }) else { return }
        let directory = local.directory
        let resolved = await Task.detached {
            guard let remote = ExtensionSharingService.remoteURL(directory: directory) else { return "" }
            if remote.hasPrefix("git@github.com:") || remote.hasPrefix("ssh://git@github.com/"),
               let publicURL = ExtensionSharingService.webURL(for: remote) {
                return publicURL.absoluteString
            }
            return remote
        }.value
        guard !Task.isCancelled, selectedLocalID == requestedID else { return }
        repositoryURL = resolved
    }

    private func save() {
        guard let version = manifest.version else { return }
        saving = true
        message = nil
        let parsedTags = tags.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty }
        let draft = MarketplaceExtensionDraft(
            repositoryURL: repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines),
            name: manifest.name,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            category: category.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            tags: Array(Set(parsedTags)).sorted(), version: version, manifest: manifest)
        Task {
            do { try await onSave(draft); dismiss() }
            catch { message = error.localizedDescription; saving = false }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
