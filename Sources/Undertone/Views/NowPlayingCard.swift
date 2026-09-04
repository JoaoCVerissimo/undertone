import AppKit
import SwiftUI
import UndertoneCore

struct NowPlayingCard: View {
    @Environment(PlayerEngine.self) private var engine

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: engine.track?.artworkURL, isResolving: engine.isResolving)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                if engine.isResolving {
                    Text(engine.resolvingTitle ?? "Resolving…")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Fetching audio…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Cancel") { engine.cancelResolving() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                } else if let track = engine.track {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    if let channel = track.channel {
                        Text(channel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if let queue = engine.queue {
                    Text("\(queue.position) / \(queue.count)\(queue.title.map { " · \($0)" } ?? "")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Loads artwork through the shared cache; shows a placeholder while resolving.
struct ArtworkView: View {
    let url: URL?
    let isResolving: Bool
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.08))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: isResolving ? "waveform.badge.magnifyingglass" : "music.note")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            image = url.flatMap { ArtworkLoader.shared.cached($0) }
            guard let url else { return }
            let loaded = await ArtworkLoader.shared.image(for: url)
            if !Task.isCancelled { image = loaded }
        }
    }
}
