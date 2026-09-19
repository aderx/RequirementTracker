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
                    .fill(DesignColor.surface.opacity(tintOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(DesignColor.textPrimary.opacity(strokeOpacity * 0.25), lineWidth: 0.6)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 10, y: 3)
    }
}

struct GlassDivider: View {
    var body: some View {
        Rectangle()
            .fill(DesignColor.border)
            .frame(height: 0.5)
    }
}

// 文本视图必须跟随实际视口宽度；SwiftUI 首次创建时视口尚未完成布局。
final class TextEditorScrollView: NSScrollView {
    private var lastViewportSize = NSSize.zero

    override func layout() {
        super.layout()
        guard let editor = documentView as? NSTextView,
              contentSize.width > 0, contentSize.height > 0,
              contentSize != lastViewportSize else { return }
        lastViewportSize = contentSize
        editor.minSize = NSSize(width: 0, height: contentSize.height)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.setFrameSize(NSSize(width: contentSize.width, height: max(editor.frame.height, contentSize.height)))
        editor.textContainer?.containerSize = NSSize(
            width: max(1, contentSize.width - editor.textContainerInset.width * 2),
            height: .greatestFiniteMagnitude
        )
        editor.sizeToFit()
    }
}
