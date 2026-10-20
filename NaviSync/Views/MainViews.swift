import SwiftUI

#if os(iOS)

/// iPhone / iPad: tab bar with a mini player above it, full player as a sheet.
struct PhoneMainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView {
            NavigationStack { ArtistsView() }
                .safeAreaInset(edge: .bottom) { PlayerInset() }
                .tabItem { Label("Library", systemImage: "music.note.list") }

            NavigationStack { DownloadsView() }
                .safeAreaInset(edge: .bottom) { PlayerInset() }
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }

            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .sheet(isPresented: $model.showNowPlaying) {
            NowPlayingView()
        }
    }
}

private struct PlayerInset: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 6) {
            HandoffBanner()
            MiniPlayerBar()
        }
        .padding(.bottom, 4)
        .animation(.default, value: model.sync.pendingHandoff?.id)
    }
}

private struct MiniPlayerBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        if let song = player.currentSong {
            HStack(spacing: 12) {
                CoverArtView(coverArtId: song.coverArt, cornerRadius: 4)
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(song.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 36, height: 36)
                }
                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                }
                .disabled(!player.hasNext)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    let fraction = player.duration > 0 ? min(player.currentTime / player.duration, 1) : 0
                    Rectangle()
                        .fill(.tint)
                        .frame(width: geo.size.width * fraction, height: 2)
                }
                .frame(height: 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .onTapGesture { model.showNowPlaying = true }
        }
    }
}

#else

/// Mac: sidebar + content, with a player bar along the bottom of the window.
struct MacMainView: View {
    enum SidebarItem: Hashable {
        case artists, downloads
    }

    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .artists

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            NavigationSplitView {
                List(selection: $selection) {
                    Section("Library") {
                        NavigationLink(value: SidebarItem.artists) {
                            Label("Artists", systemImage: "music.mic")
                        }
                        NavigationLink(value: SidebarItem.downloads) {
                            Label("Downloads", systemImage: "arrow.down.circle")
                        }
                    }
                }
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 280)
            } detail: {
                NavigationStack {
                    switch selection ?? .artists {
                    case .artists: ArtistsView()
                    case .downloads: DownloadsView()
                    }
                }
                .id(selection)
            }

            if model.sync.pendingHandoff != nil {
                HandoffBanner()
                    .padding(.vertical, 6)
            }

            Divider()
            MacPlayerBar()
        }
        .frame(minWidth: 760, minHeight: 480)
        .animation(.default, value: model.sync.pendingHandoff?.id)
        .sheet(isPresented: $model.showNowPlaying) {
            NowPlayingView()
        }
    }
}

private struct MacPlayerBar: View {
    @Environment(AppModel.self) private var model
    @State private var showQueue = false

    var body: some View {
        let player = model.player
        HStack(spacing: 20) {
            HStack(spacing: 10) {
                CoverArtView(coverArtId: player.currentSong?.coverArt, cornerRadius: 4)
                    .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.currentSong?.title ?? "Not Playing")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(player.currentSong?.artist ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 240, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if player.currentSong != nil { model.showNowPlaying = true } }

            VStack(spacing: 4) {
                PlaybackControls(iconSize: 15, spacing: 26)
                ProgressSlider(compact: true)
            }
            .frame(maxWidth: 520)

            HStack(spacing: 12) {
                SyncStatusLabel()
                Button { showQueue.toggle() } label: {
                    Image(systemName: "list.bullet")
                }
                .buttonStyle(.borderless)
                .help("Queue")
                .popover(isPresented: $showQueue, arrowEdge: .top) {
                    QueueList()
                        .frame(width: 360, height: 460)
                }
            }
            .frame(width: 240, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

#endif
