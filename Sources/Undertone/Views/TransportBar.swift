import SwiftUI
import UndertoneCore

struct TransportBar: View {
    @Environment(PlayerEngine.self) private var engine

    var body: some View {
        HStack(spacing: 22) {
            if engine.queue != nil {
                TransportButton(symbol: "backward.end.fill", size: 15, help: "Previous") { engine.previous() }
                    .disabled(engine.queue?.hasPrevious != true && engine.currentTime < 3)
            }
            TransportButton(symbol: "gobackward.15", size: 19, help: "Back 15 seconds") { engine.skip(by: -15) }
            Button {
                engine.togglePlayPause()
            } label: {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(.tint))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(engine.isPlaying ? "Pause" : "Play")
            TransportButton(symbol: "goforward.15", size: 19, help: "Forward 15 seconds") { engine.skip(by: 15) }
            if engine.queue != nil {
                TransportButton(symbol: "forward.end.fill", size: 15, help: "Next") { engine.next() }
                    .disabled(engine.queue?.hasNext != true)
            }
        }
        .frame(maxWidth: .infinity)
        .disabled(engine.track == nil)
    }
}

struct TransportButton: View {
    let symbol: String
    let size: CGFloat
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .help(help)
    }
}

struct SpeedPicker: View {
    @Environment(PlayerEngine.self) private var engine

    var body: some View {
        Picker("Speed", selection: Binding(get: { engine.speed }, set: { engine.setSpeed($0) })) {
            ForEach(PlaybackSpeed.allCases) { speed in
                Text(speed.label).tag(speed)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 150)
    }
}

/// Repeat · speed · volume, on one row under the transport.
struct SecondaryControls: View {
    var body: some View {
        HStack(spacing: 8) {
            RepeatButton()
            Spacer(minLength: 2)
            SpeedPicker()
            Spacer(minLength: 2)
            VolumeControl()
        }
    }
}

struct RepeatButton: View {
    @Environment(PlayerEngine.self) private var engine

    var body: some View {
        Button {
            engine.cycleRepeatMode()
        } label: {
            Image(systemName: engine.repeatMode.symbolName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 22)
                .background(engine.repeatMode.isOn ? Color.primary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(engine.repeatMode.isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .help(engine.repeatMode.label)
    }
}

struct VolumeControl: View {
    @Environment(PlayerEngine.self) private var engine

    var body: some View {
        HStack(spacing: 4) {
            Button {
                engine.toggleMute()
            } label: {
                Image(systemName: engine.volumeSymbol)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(engine.isMuted ? "Unmute" : "Mute")
            Slider(value: Binding(get: { Double(engine.effectiveVolume) }, set: { engine.setVolume(Float($0)) }), in: 0...1)
                .controlSize(.mini)
                .frame(width: 70)
                .help("Volume (or scroll over the menu bar icon)")
        }
    }
}
