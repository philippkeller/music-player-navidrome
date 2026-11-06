import SwiftUI

struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue = false

    var body: some View {
        let player = model.player
        VStack(spacing: 24) {
            #if os(macOS)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            #endif

            if showQueue {
                QueueList()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Spacer(minLength: 0)
                CoverArtView(coverArtId: player.currentSong?.coverArt, cornerRadius: 14)
                    .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: 520)
                Spacer(minLength: 0)
            }

            VStack(spacing: 4) {
                Text(player.currentSong?.title ?? "Not Playing")
                    .font(.title3.bold())
                    .lineLimit(1)
                Text([player.currentSong?.artist, player.currentSong?.album].compactMap { $0 }.joined(separator: " — "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            ProgressSlider()

            PlaybackControls()

            OutputNameLabel()

            HStack {
                SyncStatusLabel()
                Spacer()
                SonosButton()
                OutputPickerButton()
                Button {
                    withAnimation { showQueue.toggle() }
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.title3)
                        .padding(8)
                        .background(showQueue ? Color.accentColor.opacity(0.2) : Color.clear, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        .frame(minWidth: 440, minHeight: 640)
        #endif
    }
}

/// Small "Synced 10:42" indicator. Click to refresh library, artwork and playback sync.
struct SyncStatusLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sync = model.sync
        Button {
            Task { await model.refreshAll() }
        } label: {
            if model.isRefreshing {
                Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
            } else if sync.lastError != nil {
                Label("Offline", systemImage: "icloud.slash")
            } else if let saved = sync.lastSaved {
                Label("Synced \(saved.formatted(date: .omitted, time: .shortened))", systemImage: "arrow.triangle.2.circlepath")
            } else {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
        .disabled(model.isRefreshing)
        .help(sync.lastError ?? "Click to refresh new albums and artwork from your Navidrome server")
    }
}
