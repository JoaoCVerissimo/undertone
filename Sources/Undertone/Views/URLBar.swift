import AppKit
import SwiftUI
import UndertoneCore

struct URLBar: View {
    @Environment(PlayerEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @Environment(YTDLPService.self) private var service
    @Environment(PanelState.self) private var state
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 6) {
            Image(systemName: "link")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            TextField("Paste a YouTube link", text: $state.urlText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit(submit)
            if !state.urlText.isEmpty {
                Button {
                    state.urlText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
            RecentLinksMenu()
            Button(action: submit) {
                Text(state.urlText.isEmpty ? "Paste & Play" : "Play")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 2)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!service.status.isUsable)
            .help(state.urlText.isEmpty ? "Play the link on the clipboard" : "Play this link")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: state.showCount, initial: true) { _, _ in
            if engine.track == nil && !engine.isResolving { focused = true }
        }
    }

    private func submit() {
        var text = state.urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            state.urlText = text
        }
        guard !text.isEmpty else { return }
        engine.open(text)
        focused = false
    }
}

struct RecentLinksMenu: View {
    @Environment(PlayerEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @Environment(PanelState.self) private var state

    var body: some View {
        Menu {
            if settings.recent.items.isEmpty {
                Text("No recent links")
            }
            ForEach(settings.recent.items) { item in
                Button {
                    state.urlText = item.url.absoluteString
                    engine.open(item.url.absoluteString)
                } label: {
                    Text(item.title)
                }
            }
            if !settings.recent.items.isEmpty {
                Divider()
                Button("Clear Recent") { settings.recent.clear() }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Recent links")
    }
}
