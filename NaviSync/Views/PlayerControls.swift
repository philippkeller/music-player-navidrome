import SwiftUI

struct PlaybackControls: View {
    var iconSize: CGFloat = 28
    var spacing: CGFloat = 44

    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        HStack(spacing: spacing) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: iconSize))
            }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: iconSize * 1.4))
                    .frame(width: iconSize * 1.8)
            }
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: iconSize))
            }
            .disabled(!player.hasNext)
        }
        .buttonStyle(.plain)
        .disabled(player.currentSong == nil)
    }
}

/// Seek slider; holds its own value while dragging so the playhead doesn't fight the user.
struct ProgressSlider: View {
    var compact = false

    @Environment(AppModel.self) private var model
    @State private var scrubValue: Double?

    var body: some View {
        let player = model.player
        let total = max(player.duration, 1)
        let value = scrubValue ?? min(player.currentTime, total)
        let slider = Slider(
            value: Binding(get: { value }, set: { scrubValue = $0 }),
            in: 0...total,
            onEditingChanged: { editing in
                if !editing, let target = scrubValue {
                    player.seek(to: target)
                    scrubValue = nil
                }
            }
        )
        .disabled(player.currentSong == nil)

        if compact {
            HStack(spacing: 8) {
                Text(formatTime(value)).frame(width: 44, alignment: .trailing)
                slider.controlSize(.small)
                Text(formatTime(player.duration)).frame(width: 44, alignment: .leading)
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 4) {
                slider
                HStack {
                    Text(formatTime(value))
                    Spacer()
                    Text("-" + formatTime(max(0, player.duration - value)))
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct QueueList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        ScrollViewReader { proxy in
            List {
                ForEach(Array(player.queue.enumerated()), id: \.offset) { index, song in
                    Button {
                        player.jump(to: index)
                    } label: {
                        HStack(spacing: 10) {
                            CoverArtView(coverArtId: song.coverArt, cornerRadius: 4)
                                .frame(width: 36, height: 36)
                            SongRow(song: song, showArtist: true)
                        }
                        .opacity(index < (player.currentIndex ?? 0) ? 0.5 : 1)
                    }
                    .buttonStyle(.plain)
                    .id(index)
                }
                .onDelete { player.removeFromQueue(at: $0) }
            }
            .listStyle(.plain)
            .onAppear {
                if let index = player.currentIndex { proxy.scrollTo(index, anchor: .top) }
            }
        }
    }
}

/// "Continue from Mac" banner offered when another device saved a newer queue.
struct HandoffBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let handoff = model.sync.pendingHandoff {
            HStack(spacing: 12) {
                Image(systemName: Self.icon(for: handoff.deviceName))
                    .font(.title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Continue from \(handoff.deviceName)")
                        .font(.subheadline.bold())
                    Text("\(handoff.song.title) · \(handoff.song.artist ?? "") · \(formatTime(handoff.position))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button("Resume") { model.sync.acceptHandoff() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button {
                    model.sync.dismissHandoff()
                } label: {
                    Image(systemName: "xmark").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            .padding(.horizontal, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    static func icon(for device: String) -> String {
        if device.contains("Mac") { return "laptopcomputer" }
        if device.contains("iPad") { return "ipad" }
        if device.contains("iPhone") { return "iphone" }
        return "hifispeaker"
    }
}
