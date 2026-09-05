import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI
import UndertoneCore

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerEngine.self) private var engine
    @Environment(YTDLPService.self) private var service
    @Environment(PanelState.self) private var state
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginRequiresApproval = LaunchAtLogin.status == .requiresApproval
    @State private var loginError: String?

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                IconButton(symbol: "chevron.left", help: "Back") { state.showSettings(false) }
                Text("Settings")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                IconButton(symbol: "power", help: "Quit Undertone") { NSApp.terminate(nil) }
            }

            section("Appearance") {
                swatches
                HStack {
                    Text("Custom").font(.caption).frame(width: 60, alignment: .leading)
                    HueSlider(hex: $settings.tintHex)
                }
                HStack {
                    Text("Intensity").font(.caption).frame(width: 60, alignment: .leading)
                    Slider(value: $settings.tintOpacity, in: 0.15...0.85).controlSize(.small)
                        .disabled(settings.tintHex == nil)
                }
                HStack {
                    Text("Glass").font(.caption).frame(width: 60, alignment: .leading)
                    Picker("Glass", selection: $settings.glassStyle) {
                        ForEach(GlassStyleChoice.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                    Picker("Backdrop", selection: $settings.backdrop) {
                        ForEach(BackdropChoice.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().controlSize(.small).frame(width: 110)
                }
            }

            section("Shortcuts") {
                shortcutRow("Play / Pause", .togglePlayPause)
                shortcutRow("Cycle speed", .cycleSpeed)
                shortcutRow("Open panel", .togglePanel)
                shortcutRow("Next track", .nextTrack)
                shortcutRow("Previous track", .previousTrack)
                Text("Media keys and the Now Playing widget work without any setup.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            section("General") {
                Toggle("Show track title in the menu bar", isOn: $settings.showTitleInMenuBar)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!LaunchAtLogin.isAvailable)
                    .onChange(of: launchAtLogin) { _, enabled in
                        guard enabled != LaunchAtLogin.isEnabled else { return }
                        do {
                            try LaunchAtLogin.set(enabled)
                            loginError = nil
                            loginRequiresApproval = LaunchAtLogin.status == .requiresApproval
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
                if !LaunchAtLogin.isAvailable {
                    Text("Run the built app (make install) to enable this.").font(.caption2).foregroundStyle(.tertiary)
                } else if !LaunchAtLogin.isInApplications {
                    Text("Tip: install to /Applications first so the login item survives rebuilds.").font(.caption2).foregroundStyle(.tertiary)
                }
                if loginRequiresApproval {
                    Button("Approve in System Settings…") { LaunchAtLogin.openSystemSettings() }.controlSize(.mini)
                }
                if let loginError {
                    Text(loginError).font(.caption2).foregroundStyle(.red)
                }
            }

            section("yt-dlp") {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: toolSymbol).foregroundStyle(toolColor).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(toolTitle).font(.caption).fixedSize(horizontal: false, vertical: true)
                        if let path = service.executable?.path {
                            Text(path).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                        Text(service.jsRuntime.map { "deno: \($0.path)" } ?? "deno not found (YouTube needs it: brew install deno)")
                            .font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                HStack {
                    Button("Recheck") { service.recheck() }
                    Button("Choose…") { choosePath() }
                    if settings.ytdlpPathOverride != nil {
                        Button("Use default") { service.setOverride(nil) }
                    }
                    Spacer()
                    Text(service.installCommand).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .controlSize(.mini)
            }

            HStack {
                Text("Undertone \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button(role: .destructive) { NSApp.terminate(nil) } label: {
                    Label("Quit Undertone", systemImage: "power")
                }
                .controlSize(.small)
            }
        }
        .padding(16)
        .onChange(of: state.showCount) { _, _ in
            launchAtLogin = LaunchAtLogin.isEnabled
            loginRequiresApproval = LaunchAtLogin.status == .requiresApproval
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .kerning(0.5)
            content()
        }
    }

    private func shortcutRow(_ label: String, _ name: KeyboardShortcuts.Name) -> some View {
        HStack {
            Text(label).font(.caption)
            Spacer()
            KeyboardShortcuts.Recorder(for: name)
                .controlSize(.small)
        }
    }

    private var swatches: some View {
        HStack(spacing: 8) {
            ForEach(TintPreset.all) { preset in
                Button {
                    settings.tintHex = preset.hex
                } label: {
                    ZStack {
                        Circle()
                            .fill(preset.hex.flatMap(Color.init(hex:)) ?? Color.clear)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                        if preset.hex == nil {
                            Image(systemName: "slash.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        if settings.tintHex == preset.hex {
                            Circle().strokeBorder(Color.primary, lineWidth: 2).padding(-3)
                        }
                    }
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(preset.name)
            }
        }
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Choose the yt-dlp executable"
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        NSApp.activate()
        state.hide()
        panel.begin { response in
            if response == .OK, let url = panel.url {
                service.setOverride(url.path)
            }
        }
    }

    private var toolSymbol: String {
        switch service.status {
        case .ready: return "checkmark.circle.fill"
        case .checking: return "hourglass"
        case .outdated: return "arrow.up.circle.fill"
        case .missing, .broken: return "exclamationmark.triangle.fill"
        }
    }

    private var toolColor: Color {
        switch service.status {
        case .ready: return .green
        case .checking: return .secondary
        case .outdated: return .yellow
        case .missing, .broken: return .orange
        }
    }

    private var toolTitle: String {
        switch service.status {
        case .checking: return "Checking…"
        case .ready(let v): return "yt-dlp \(v)"
        case .outdated(let v): return "yt-dlp \(v) — update recommended (≥ \(YTDLPVersion.minimumRecommended))"
        case .missing: return "Not found. Install with Homebrew."
        case .broken(let m): return "Not working: \(m)"
        }
    }
}

/// A hue slider that writes a saturated color back as hex.
struct HueSlider: View {
    @Binding var hex: String?
    @State private var hue: Double = 0.6

    var body: some View {
        Slider(value: $hue, in: 0...1) { editing in
            if !editing { commit() }
        }
        .controlSize(.small)
        .onChange(of: hue) { _, _ in commit() }
        .onAppear { syncFromHex() }
        .onChange(of: hex) { _, _ in syncFromHex() }
        .background(
            LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 0.1).map { Color(hue: $0, saturation: 0.75, brightness: 0.95) },
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 4)
                .clipShape(Capsule())
                .opacity(0.9)
        )
    }

    private func commit() {
        let color = NSColor(hue: hue, saturation: 0.72, brightness: 0.92, alpha: 1)
        let newHex = color.hexString
        if newHex != hex { hex = newHex }
    }

    private func syncFromHex() {
        guard let hex, let color = NSColor(hex: hex)?.usingColorSpace(.deviceRGB) else { return }
        let value = Double(color.hueComponent)
        if abs(value - hue) > 0.01 { hue = value }
    }
}
