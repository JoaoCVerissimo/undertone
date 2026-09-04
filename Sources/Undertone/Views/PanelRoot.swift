import SwiftUI
import UndertoneCore

/// The SwiftUI content of the panel. Transparent: the AppKit glass view behind it provides the surface.
struct PanelRoot: View {
    let engine: PlayerEngine
    let settings: AppSettings
    let service: YTDLPService
    let state: PanelState

    var body: some View {
        Group {
            if state.showingSettings {
                SettingsView()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                MainView()
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(width: PanelController.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(blurTint)
        .clipShape(.rect(cornerRadius: PanelController.cornerRadius))
        .tint(tint)
        .environment(engine)
        .environment(settings)
        .environment(service)
        .environment(state)
        .animation(.snappy(duration: 0.25), value: state.showingSettings)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            state.controller?.contentSizeChanged(size)
        }
    }

    private var tint: Color? {
        settings.tintHex.flatMap(Color.init(hex:))
    }

    /// The blur fallback has no tintColor of its own, so the tint is painted here instead.
    @ViewBuilder private var blurTint: some View {
        if settings.backdrop == .blur, let tint {
            tint.opacity(settings.tintOpacity * 0.35)
        }
    }
}
