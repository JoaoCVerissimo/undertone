import SwiftUI
import UndertoneCore

struct Scrubber: View {
    @Environment(PlayerEngine.self) private var engine
    @State private var dragValue: Double?

    var body: some View {
        let duration = engine.duration ?? 0
        let shown = dragValue ?? min(engine.currentTime, max(duration, 0))
        VStack(spacing: 2) {
            Slider(
                value: Binding(get: { shown }, set: { dragValue = $0 }),
                in: 0...max(duration, 1),
                onEditingChanged: { editing in
                    if !editing, let value = dragValue {
                        engine.seek(to: value)
                        dragValue = nil
                    }
                }
            )
            .controlSize(.small)
            .disabled(duration <= 0 || engine.isResolving)
            HStack {
                Text(TimeFormat.clock(shown))
                Spacer()
                if engine.isBuffering && !engine.isResolving {
                    Text("Buffering…")
                }
                Spacer()
                Text(TimeFormat.remaining(shown, of: duration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}
