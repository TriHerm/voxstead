import AppKit
import SwiftUI

@main
struct VoxsteadApp: App {
    @NSApplicationDelegateAdaptor(VoxsteadDelegate.self) private var delegate
    private var store: WorkspaceStore { delegate.store }

    var body: some Scene {
        Window("Voxstead", id: "workspace") {
            WorkspaceView(store: store)
                .frame(minWidth: 800, minHeight: 560)
                .task { store.installHotkey() }
        }
        .defaultSize(width: 1040, height: 690)
        .defaultLaunchBehavior(.presented)
        .commands {
            MeetingCommands(store: store)
            CommandGroup(after: .saveItem) {
                Button("Back Up Library…") { store.backUpLibrary() }
                Button("Restore Library Backup…") { store.chooseLibraryBackup() }
                    .disabled(!store.canRestoreLibrary)
            }
            CommandGroup(replacing: .newItem) {
                Button("New dictation") { store.startCapture(.dictation) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(store.showGuide || store.captureID != nil || store.importingAudio)
                Button("New meeting") { store.showMeetingSetup = true }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(store.showGuide || store.captureID != nil || store.importingAudio)
                Divider()
                Button("Transcribe audio file…") { store.importAudio() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(store.showGuide || store.captureID != nil || store.importingAudio)
            }
            CommandGroup(replacing: .help) {
                Button("Voxstead getting started") { store.openGuide() }
                    .disabled(store.captureID != nil || store.importingAudio || store.runningID != nil)
                Button("Practice a meeting") { store.destination = .practice }
            }
            CommandGroup(after: .sidebar) {
                Button("Go Back") { store.navigate(.backward) }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!store.canNavigate(.backward))
                Button("Go Forward") { store.navigate(.forward) }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!store.canNavigate(.forward))
                Divider()
                Button("Go to Home") { store.destination = .home }
                    .keyboardShortcut("1", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { store.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }

        Window("Live meeting", id: "live-meeting") {
            LiveMeetingView(store: store)
        }
        .defaultSize(width: 480, height: 515)
        .defaultLaunchBehavior(.suppressed)
        .windowLevel(store.meetingPanelPinned ? .floating : .normal)

        MenuBarExtra {
            WorkspaceMenu(store: store)
        } label: {
            Label("Voxstead", systemImage: store.captureID == nil ? "waveform" : "record.circle")
        }
    }
}

private struct MeetingCommands: Commands {
    let store: WorkspaceStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Meeting") {
            Button("Show live panel") { openWindow(id: "live-meeting") }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(store.activeMeeting == nil)
        }
    }
}

@MainActor
final class VoxsteadDelegate: NSObject, NSApplicationDelegate {
    let store = WorkspaceStore()
    private var awaitingTermination = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if awaitingTermination { return .terminateLater }
        guard store.captureID != nil || store.hasUnsavedChanges || store.meetingAudioCheck.isRunning else { return .terminateNow }
        awaitingTermination = true
        Task {
            let saved = await store.finishBeforeQuit()
            awaitingTermination = false
            sender.reply(toApplicationShouldTerminate: saved)
            if !saved { sender.activate() }
        }
        return .terminateLater
    }
}

private struct WorkspaceMenu: View {
    let store: WorkspaceStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Voxstead") { openWorkspace() }
        Divider()
        if let status = store.captureStatus {
            Text(status)
            if store.activeMeeting != nil {
                Button("Show live meeting") { openWindow(id: "live-meeting") }
            }
            Button("Stop") { store.stopCapture() }
        } else if store.importingAudio {
            Text("Transcribing audio…")
            Button("Stop") { store.cancelAudioImport() }
        } else {
            Button("Dictate") {
                openWorkspace()
                store.startCapture(.dictation)
            }
            Button("Start meeting") {
                openWorkspace()
                store.showMeetingSetup = true
            }
            Button("Start phone call") {
                openWorkspace()
                store.openPhoneCallSetup()
            }
            Text(store.hotkeyError ?? "Hold ⌃⌥D to dictate")
        }
        Divider()
        Button("Settings…") {
            openWorkspace()
            store.openSettings()
        }
        Button("Quit Voxstead") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func openWorkspace() {
        openWindow(id: "workspace")
        NSApp.activate()
    }
}
