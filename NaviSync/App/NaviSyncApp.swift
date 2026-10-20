import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct NaviSyncApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandMenu("Playback") {
                Button(model.player.isPlaying ? "Pause" : "Play") { model.player.togglePlayPause() }
                    .keyboardShortcut("p", modifiers: .command)
                Button("Next Song") { model.player.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Previous Song") { model.player.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
            }
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 460, height: 420)
        }
        #endif
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.config == nil {
                LoginView()
            } else {
                #if os(iOS)
                PhoneMainView()
                #else
                MacMainView()
                #endif
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.scenePhaseChanged(phase)
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.scenePhaseChanged(.active)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.scenePhaseChanged(.background)
        }
        #endif
    }
}
