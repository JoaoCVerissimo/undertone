import AppKit
import SwiftUI
import UndertoneCore

/// Shown until yt-dlp is found and current enough.
struct ToolStatusBanner: View {
    @Environment(YTDLPService.self) private var service

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if showsCommand {
                    HStack(spacing: 6) {
                        Text(service.installCommand)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(service.installCommand, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Copy command")
                        Spacer()
                        Button("Recheck") { Task { await service.refresh(rereadLoginPath: true) } }
                            .controlSize(.mini)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private var symbol: String {
        switch service.status {
        case .checking: return "hourglass"
        case .ready: return "checkmark.circle"
        case .outdated: return "arrow.up.circle.fill"
        case .missing, .broken: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch service.status {
        case .checking, .ready: return .secondary
        case .outdated: return .yellow
        case .missing, .broken: return .orange
        }
    }

    private var title: String {
        switch service.status {
        case .checking: return "Checking yt-dlp…"
        case .ready(let v): return "yt-dlp \(v) ready"
        case .outdated(let v): return "yt-dlp \(v) is older than YouTube likes"
        case .missing: return "yt-dlp isn't installed"
        case .broken(let message): return "yt-dlp isn't working: \(message)"
        }
    }

    private var hint: String? {
        switch service.status {
        case .outdated: return "Playback may fail until it is updated (needs ≥ \(YTDLPVersion.minimumRecommended))."
        case .missing: return "Undertone uses yt-dlp to find the audio stream. Install it with Homebrew, then Recheck."
        case .broken: return "Check the path in Settings, or reinstall with Homebrew."
        default: return nil
        }
    }

    private var showsCommand: Bool {
        switch service.status {
        case .outdated, .missing, .broken: return true
        default: return false
        }
    }
}
