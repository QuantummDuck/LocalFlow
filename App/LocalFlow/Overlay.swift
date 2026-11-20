import AppKit
import SwiftUI

/// The Flow Bar: a small bubble at the bottom of the screen. Hover shows a hint and click starts hands-free;
/// it shows live mic bars while listening, Stop/Cancel buttons in hands-free, dots while working, and short notices.
@MainActor final class FlowBar {
    enum State: Equatable { case idle, recording, handsFree, command, processing, transforming }

    @Observable final class Model {
        var state = State.idle
        var hover = false
        var notice: String?
        var levels = [CGFloat](repeating: 0, count: 16)
    }

    let model = Model()
    var onClick: () -> Void = {}       // idle click → hands-free, or stop hands-free
    var onCancel: () -> Void = {}
    private let panel: NSPanel
    private var hoverTimer: Timer?
    private var noticeWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 60, height: 24),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = ClickThroughHost(rootView: BarView(model: model, click: { [weak self] in self?.onClick() },
                                                      cancel: { [weak self] in self?.onCancel() }))
        host.sizingOptions = []
        panel.contentView = host
        // hover polling: tracking areas don't fire reliably in a non-activating panel
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHover() }
        }
    }

    var size: CGSize {
        if let n = model.notice { return CGSize(width: min(420, CGFloat(n.count) * 7.2 + 56), height: 34) }
        switch model.state {
        case .idle: return model.hover ? CGSize(width: 250, height: 34) : CGSize(width: 64, height: 22)
        case .recording, .command: return CGSize(width: 136, height: 34)
        case .handsFree: return CGSize(width: 196, height: 34)
        case .processing, .transforming: return CGSize(width: 84, height: 34)
        }
    }

    func show(_ s: State) {
        model.state = s
        if s != .processing && s != .transforming && s != .idle { model.levels = model.levels.map { _ in 0 } }
        layout()
    }

    func idle() { show(.idle) }

    func notice(_ text: String, seconds: Double = 2.6) {
        model.notice = text
        layout()
        noticeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.model.notice = nil; self?.layout() }
        noticeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    func push(level: Float) {
        let v = CGFloat(min(1, sqrt(Double(level)) * 4))  // perceptual-ish scaling
        model.levels.removeFirst()
        model.levels.append(v)
    }

    func layout() {
        let visible = model.state != .idle || model.notice != nil || Settings.shared.p.flowBar
        guard visible else { panel.orderOut(nil); return }
        let screen = (model.state == .idle && model.notice == nil ? nil : NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) })
            ?? panel.screen ?? NSScreen.main
        guard let f = screen?.visibleFrame else { return }
        let s = size
        panel.setFrame(NSRect(x: (f.midX - s.width / 2).rounded(), y: f.minY + 14, width: s.width, height: s.height), display: true)
        panel.ignoresMouseEvents = !(model.state == .idle || model.state == .handsFree)
        panel.orderFrontRegardless()
    }

    private func checkHover() {
        guard panel.isVisible, model.state == .idle, model.notice == nil else { if model.hover { model.hover = false }; return }
        let inside = panel.frame.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation)
        if inside != model.hover { withAnimation(.snappy(duration: 0.18)) { model.hover = inside }; layout() }
    }
}

/// Clicks land on the first click even though the panel never becomes key.
private final class ClickThroughHost<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct BarView: View {
    let model: FlowBar.Model
    let click: () -> Void
    let cancel: () -> Void
    @State private var phase = false

    var body: some View {
        ZStack {
            Capsule().fill(.black.opacity(model.state == .idle && !model.hover && model.notice == nil ? 0.55 : 0.86))
            Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1)
            content.padding(.horizontal, 12)
        }
        .padding(model.state == .idle && !model.hover && model.notice == nil ? 6 : 0)
        .animation(.snappy(duration: 0.2), value: model.state)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder var content: some View {
        if let n = model.notice {
            Text(n).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1)
        } else {
            switch model.state {
            case .idle:
                if model.hover {
                    Button(action: click) {
                        HStack(spacing: 6) {
                            Image(systemName: "waveform").font(.system(size: 11, weight: .bold))
                            Text("Click or hold fn to start dictating").font(.system(size: 12, weight: .medium))
                        }.foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                } else {
                    Color.clear.contentShape(Rectangle()).onTapGesture(perform: click)
                }
            case .recording: bars
            case .command:
                HStack(spacing: 6) { Image(systemName: "sparkles").font(.system(size: 11, weight: .bold)).foregroundStyle(.purple); bars }
            case .handsFree:
                HStack(spacing: 8) {
                    Button(action: cancel) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                        .frame(width: 22, height: 22).background(Circle().fill(.white.opacity(0.14))) }.buttonStyle(.plain)
                    bars
                    Button(action: click) { RoundedRectangle(cornerRadius: 2.5).fill(.red).frame(width: 9, height: 9)
                        .frame(width: 22, height: 22).background(Circle().fill(.white.opacity(0.14))) }.buttonStyle(.plain)
                }
            case .processing, .transforming:
                HStack(spacing: 5) {
                    if model.state == .transforming { Image(systemName: "sparkles").font(.system(size: 10, weight: .bold)).foregroundStyle(.purple) }
                    ForEach(0..<3, id: \.self) { i in
                        Circle().fill(.white.opacity(0.9)).frame(width: 5, height: 5)
                            .scaleEffect(phase ? 1 : 0.45)
                            .animation(.easeInOut(duration: 0.45).repeatForever().delay(Double(i) * 0.15), value: phase)
                    }
                }
                .onAppear { phase = true }
                .onDisappear { phase = false }
            }
        }
    }

    var bars: some View {
        HStack(spacing: 2.5) {
            ForEach(model.levels.indices, id: \.self) { i in
                Capsule().fill(.white.opacity(0.92)).frame(width: 3, height: 3 + model.levels[i] * 18)
            }
        }
        .animation(.linear(duration: 0.06), value: model.levels)
    }
}
