import AppKit
import SwiftUI

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .menu
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
    }
}

struct TransparentWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureWindow(from: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        configureWindow(from: view)
    }

    private func configureWindow(from view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else {
                return
            }

            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
        }
    }
}

struct GlassPanelBackground: View {
    var cornerRadius: CGFloat = 10
    var tintOpacity: Double = 0.16
    var strokeOpacity: Double = 0.45

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(tintOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(strokeOpacity), lineWidth: 0.6)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 10, y: 3)
    }
}

struct GlassDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.34))
            .frame(height: 0.7)
            .overlay(Rectangle().fill(Color.black.opacity(0.05)).offset(y: 0.5))
    }
}
