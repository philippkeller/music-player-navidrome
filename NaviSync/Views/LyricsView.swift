import SwiftUI

/// Spotify-style lyrics that follow playback. Tapping a line means "this is being sung now" and fixes
/// the timing of that song; long-press a line to jump there or undo the fix.
struct LyricsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        let songId = player.currentSong?.id
        let lines = songId.flatMap { model.lyrics.lines(for: $0) }
        Group {
            if let lines, !lines.isEmpty {
                let store = model.lyrics
                LyricsList(
                    lines: lines,
                    current: LyricsStore.currentIndex(in: lines, at: player.currentTime),
                    syncHere: { index in if let songId { store.sync(songId: songId, lineIndex: index, to: player.currentTime) } },
                    jump: { player.seek(to: $0) },
                    canReset: { index in songId.map { store.hasTimingFix(songId: $0, lineIndex: index) } ?? false },
                    reset: { index in if let songId { store.resetTiming(songId: songId, lineIndex: index) } }
                )
            } else if lines == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("No lyrics for this song")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: songId) {
            if let songId { await model.lyrics.load(songId: songId) }
        }
    }
}

private struct LyricsList: View {
    let lines: [LyricLine]
    let current: Int?
    let syncHere: (Int) -> Void
    let jump: (Double) -> Void
    let canReset: (Int) -> Bool
    let reset: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Button {
                            if line.isHeader { jump(line.start) } else { syncHere(index) }
                        } label: {
                            row(line, isCurrent: index == current)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Play from Here", systemImage: "play") { jump(line.start) }
                            if !line.isHeader && canReset(index) {
                                Button("Reset Timing", systemImage: "arrow.uturn.backward") { reset(index) }
                            }
                        }
                        .id(index)
                    }
                }
                .padding(.vertical, 160)
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
            .onAppear { scroll(proxy, animated: false) }
            .onChange(of: current) { _, _ in scroll(proxy, animated: true) }
        }
    }

    @ViewBuilder
    private func row(_ line: LyricLine, isCurrent: Bool) -> some View {
        Group {
            if line.isHeader {
                Text(line.headerTitle)
                    .font(.subheadline.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .padding(.top, 24)
            } else {
                Text(line.text.isEmpty ? "\u{266A}" : line.text)
                    .font(.title2.bold())
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .scaleEffect(isCurrent ? 1 : 0.97, anchor: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.25), value: isCurrent)
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let current else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(current, anchor: UnitPoint(x: 0.5, y: 0.4)) }
        } else {
            proxy.scrollTo(current, anchor: UnitPoint(x: 0.5, y: 0.4))
        }
    }
}
