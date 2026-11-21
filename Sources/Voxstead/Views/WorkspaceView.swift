import SwiftUI

struct WorkspaceView: View {
    @Bindable var store: WorkspaceStore
    @State private var showFolderEditor = false
    @State private var editingFolder: SessionFolder?
    @State private var folderName = ""
    @State private var showingImport = false
    @State private var pendingDelete: VoiceSession?
    @State private var pendingRename: VoiceSession?
    @State private var newTitle = ""
    @State private var practice = PracticeMeetingState()
    @State private var libraryDraft = LibraryAssistantDraft()
    @State private var showCompletedActions = false
    @Environment(\.openWindow) private var openWindow

    private var navigationSelection: Binding<WorkspaceDestination?> {
        Binding(get: { store.destination }, set: { if let destination = $0 { store.destination = destination } })
    }

    private var canStart: Bool { store.captureID == nil && !store.importingAudio && !store.isQuitting }
    private var hasLibraryFilters: Bool { !store.search.isEmpty || store.folderFilter != nil || store.sessionFilter != nil }

    var body: some View {
        NavigationSplitView {
            List(selection: navigationSelection) {
                Section("Workspace") {
                    Label("Home", systemImage: "house").tag(WorkspaceDestination.home)
                    Label("Practice meeting", systemImage: "play.rectangle").tag(WorkspaceDestination.practice)
                    Label("Ask your meetings", systemImage: "bubble.left.and.bubble.right").tag(WorkspaceDestination.libraryAssistant)
                    Label("Action items", systemImage: "checklist").tag(WorkspaceDestination.actionItems)
                    Label("Coach", systemImage: "person.crop.circle.badge.checkmark").tag(WorkspaceDestination.coach)
                }
                Section("Library") {
                    HStack {
                        Picker("Folder", selection: $store.folderFilter) {
                            Text("All folders").tag(nil as UUID?)
                            ForEach(store.document.folders ?? []) { folder in
                                Text(folder.name).tag(Optional(folder.id))
                            }
                        }
                        .labelsHidden()
                        Menu {
                            Button("New folder…") { editFolder(nil) }
                            if let folder = store.document.folders?.first(where: { $0.id == store.folderFilter }) {
                                Button("Rename folder…") { editFolder(folder) }
                                Button("Remove folder, keep sessions") { store.removeFolder(folder.id) }
                            }
                        } label: { Image(systemName: "folder.badge.plus") }
                        .accessibilityLabel("Manage folders")
                        .fixedSize()
                    }
                    Picker("Show sessions", selection: $store.sessionFilter) {
                        Text("All sessions").tag(nil as SessionKind?)
                        ForEach(SessionKind.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }.labelsHidden()
                    if store.visibleSessions.isEmpty {
                        Text(hasLibraryFilters ? "No matching sessions." : "Your sessions will appear here.")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                        if hasLibraryFilters {
                            Button("Clear filters") { store.search = ""; store.sessionFilter = nil; store.folderFilter = nil }
                        }
                    }
                    ForEach(store.visibleSessions) { session in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title).lineLimit(1)
                                Text(session.created.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        } icon: {
                            Image(systemName: store.captureID == session.id ? "record.circle" : session.kind.icon)
                                .foregroundStyle(store.captureID == session.id ? Color.red : Color.accentColor)
                        }
                        .help(session.title)
                        .tag(WorkspaceDestination.session(session.id))
                        .contextMenu { sessionActions(session) }
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) { sidebarFooter }
            .searchable(text: $store.search, placement: .sidebar, prompt: "Search sessions")
            .navigationSplitViewColumnWidth(min: 215, ideal: 242, max: 320)
        } detail: {
            detail
            .safeAreaInset(edge: .top, spacing: 0) {
                if let status = store.captureStatus {
                    recordingStrip(status, systemImage: "record.circle.fill", color: .red, action: store.stopCapture)
                } else if store.importingAudio {
                    recordingStrip("Transcribing audio on this Mac…", systemImage: "waveform", color: .accentColor,
                                   action: store.cancelAudioImport)
                }
            }
            .toolbar { workspaceToolbar }
        }
        .navigationSplitViewStyle(.balanced)
        .disabled(store.libraryRecoveryNeeded)
        .overlay(alignment: .bottom) {
            if let notice = store.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .allowsHitTesting(false)
            }
        }
        .task { store.presentFirstUseGuide() }
        .sheet(isPresented: $store.showGuide, onDismiss: store.performGuideAction) { FirstUseGuide(store: store) }
        .sheet(isPresented: $store.showConnections) { ConnectionsView(store: store) }
        .sheet(isPresented: $store.showMeetingSetup, onDismiss: store.clearMeetingSetupPreparation) {
            MeetingSetupView(store: store, phoneCall: store.isPhoneCallSetup)
        }
        .alert(editingFolder == nil ? "New folder" : "Rename folder", isPresented: $showFolderEditor) {
            TextField("Folder name", text: $folderName)
            Button("Save") { store.saveFolder(editingFolder?.id, name: folderName) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingImport) { ImportTextView(store: store) }
        .sheet(item: Binding(get: { store.approvalInLivePanel ? nil : store.approval }, set: { if $0 == nil { store.resolveApproval(false) } })) {
            ApprovalView(approval: $0, decide: store.resolveApproval)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if store.libraryRecoveryNeeded {
                HStack {
                    Label(store.error ?? "Library unavailable. Restore a backup to continue.",
                          systemImage: "externaldrive.badge.exclamationmark")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Show in Finder") { store.revealLibrary() }
                    Button("Restore Backup…") { store.chooseLibraryBackup() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(12).background(.bar)
            } else if store.hasUnsavedChanges {
                HStack {
                    Label("Library changes are still in memory.", systemImage: "externaldrive.badge.exclamationmark")
                    Spacer()
                    Button("Back Up…") { store.backUpLibrary() }
                    Button("Retry Save") { store.retryLibrarySave() }
                }
                .padding(12).background(.bar)
            } else if let error = store.error {
                RecoveryBanner(message: error, dismiss: { store.error = nil }, settings: { store.openSettings() })
            }
        }
        .alert("Rename session", isPresented: Binding(get: { pendingRename != nil }, set: { if !$0 { pendingRename = nil } })) {
            TextField("Name", text: $newTitle)
            Button("Save") {
                if let session = pendingRename { store.rename(session.id, title: newTitle) }
                pendingRename = nil
            }
            Button("Cancel", role: .cancel) { pendingRename = nil }
        }
        .alert("Delete this session?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let session = pendingDelete { store.delete(session.id) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This deletes the transcript, saved answers, and any answers in Ask your meetings that used \(pendingDelete?.title ?? "this session").")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch store.destination {
        case .home:
            WorkspaceHomeView(store: store, canStart: canStart, importText: { showingImport = true })
        case .practice:
            PracticeMeetingView(state: $practice, canStart: canStart, start: { store.showMeetingSetup = true })
                .navigationTitle("Practice meeting")
        case .libraryAssistant:
            LibraryAssistantView(store: store, draft: $libraryDraft)
                .navigationTitle("Ask your meetings")
        case .actionItems:
            GlobalActionItemsView(store: store, includeCompleted: $showCompletedActions)
                .navigationTitle("Action items")
        case .coach:
            CoachView(store: store).navigationTitle("Coach")
        case .session(let id):
            if let session = store.document.sessions.first(where: { $0.id == id }) {
                SessionView(store: store, session: session).id(id)
            } else {
                ContentUnavailableView("Session unavailable", systemImage: "doc.text.magnifyingglass")
            }
        }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Button { store.openGuide() } label: {
                Label("Getting started", systemImage: "questionmark.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(store.captureID != nil || store.importingAudio || store.runningID != nil)
            .padding(.horizontal, 14)
            Button { store.openSettings() } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { store.navigate(.backward) } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!store.canNavigate(.backward))
                .help("Back (⌘[)")
            Button { store.navigate(.forward) } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(!store.canNavigate(.forward))
                .help("Forward (⌘])")
        }
        ToolbarItem(placement: .primaryAction) {
            if store.activeMeeting != nil {
                Button { openWindow(id: "live-meeting") } label: {
                    Label("Show live meeting", systemImage: "video")
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { store.startCapture(.dictation) } label: { Label("Dictate", systemImage: "mic") }
                    .disabled(store.captureID != nil || store.importingAudio)
                Button { store.showMeetingSetup = true } label: { Label("Start meeting", systemImage: "person.2") }
                    .disabled(store.captureID != nil || store.importingAudio)
                Button { store.importAudio() } label: { Label("Transcribe audio file…", systemImage: "waveform.badge.plus") }
                    .disabled(store.captureID != nil || store.importingAudio)
                Button { showingImport = true } label: { Label("Add transcript…", systemImage: "doc.badge.plus") }
            } label: { Label("New session", systemImage: "plus") }
            .help("Start a dictation, meeting, or transcript import")
        }
        ToolbarItem(placement: .secondaryAction) {
            if let session = store.document.sessions.first(where: { $0.id == store.selected }) {
                Menu { sessionActions(session) } label: { Label("Session", systemImage: "ellipsis.circle") }
            }
        }
    }

    private func editFolder(_ folder: SessionFolder?) {
        editingFolder = folder
        folderName = folder?.name ?? ""
        showFolderEditor = true
    }

    @ViewBuilder
    private func sessionActions(_ session: VoiceSession) -> some View {
        Button { store.copyText(session.transcript) } label: { Label("Copy transcript", systemImage: "document.on.document") }
            .disabled(session.transcript.isEmpty)
        Button { store.export(session) } label: { Label("Export Markdown…", systemImage: "square.and.arrow.up") }
            .disabled(session.transcript.isEmpty)
        Button {
            pendingRename = session
            newTitle = session.title
        } label: { Label("Rename…", systemImage: "pencil") }
        if let folders = store.document.folders, !folders.isEmpty {
            Menu("Move to folder") {
                Button("No folder") { store.updateSession(session.id) { $0.folderID = nil } }
                ForEach(folders) { folder in
                    Button(folder.name) { store.updateSession(session.id) { $0.folderID = folder.id } }
                }
            }
        }
        Divider()
        Button(role: .destructive) { pendingDelete = session } label: { Label("Delete…", systemImage: "trash") }
            .disabled(session.id == store.captureID)
    }

    private func recordingStrip(_ status: String, systemImage: String, color: Color, action: @escaping () -> Void) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage).foregroundStyle(color)
            Text(status).font(.callout.weight(.medium))
            Spacer()
            Button("Stop", action: action)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 23)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct ImportTextView: View {
    let store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var kind: SessionKind = .meeting
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a transcript to your library").font(.title2.weight(.semibold))
            TextField("Title", text: $title)
            Picker("Type", selection: $kind) {
                ForEach(SessionKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Text("Text or transcript").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 175)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary))
                .accessibilityLabel("Text or transcript")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    store.addTranscript(title: title, text: text, kind: kind)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}

struct ApprovalView: View {
    let approval: ToolApproval
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Allow tool call", systemImage: "hammer")
                .font(.title2.weight(.semibold))
            Text("\(approval.server) / \(approval.tool)").font(.headline)
            Text("The server receives these arguments. The result goes to \(approval.provider).")
                .foregroundStyle(.secondary)
            ScrollView {
                Text(approval.arguments)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 210)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
            HStack {
                Spacer()
                Button("Decline") { decide(false) }.keyboardShortcut(.cancelAction)
                Button("Run tool") { decide(true) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 520)
        .interactiveDismissDisabled()
    }
}

struct RecoveryBanner: View {
    let message: String
    let dismiss: () -> Void
    let settings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).accessibilityHidden(true)
            ScrollView {
                Text(message).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 90)
            Button("Settings", action: settings)
            Button(action: dismiss) { Image(systemName: "xmark") }.accessibilityLabel("Dismiss error")
        }
        .padding(14).background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}
