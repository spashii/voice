import AppKit
import SwiftUI

/// A small pill at the top of the screen while Voice listens or works. It never takes
/// focus, so the paste lands in the app that was in front.
@MainActor
final class Indicator {
    private let model: AppModel
    private var panel: NSPanel?
    /// Room for the pill at its largest, with the live text; the panel is clear around it.
    private static let size = NSSize(width: 440, height: 80)

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        // Clicks pass through to the app below, except on a notice with a button.
        if case .notice(_, .some) = model.phase {
            panel.ignoresMouseEvents = false
        } else {
            panel.ignoresMouseEvents = true
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.maxY - Self.size.height - 8))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: IndicatorView().environment(model))
        return panel
    }
}

struct IndicatorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            switch model.phase {
            case .recording(_, let began):
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        LevelBar(level: model.level)
                        Text(began, style: .timer).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if !model.liveText.isEmpty {
                        Text(Self.tail(model.liveText))
                            .lineLimit(2)
                            .truncationMode(.head)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 400, alignment: .leading)
                    }
                }
            case .transcribing:
                ProgressView().controlSize(.small)
                Text("Transcribing")
            case .cleaningUp:
                ProgressView().controlSize(.small)
                Text("Fixing")
            case .notice(let text, let action):
                Text(text).lineLimit(2).minimumScaleFactor(0.8)
                if let action {
                    Button("Allow…") { model.noticeAction(action) }
                        .controlSize(.small)
                }
            case .idle:
                EmptyView()
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minHeight: 32)
        // A capsule at one line's height, a rounded box once the text adds a second.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// About two lines of the running text, from a word boundary.
    static func tail(_ text: String) -> String {
        guard text.count > 130 else { return text }
        let end = text.suffix(130)
        return "…" + (end.firstIndex(of: " ").map { end[end.index(after: $0)...] } ?? end)
    }
}

private struct LevelBar: View {
    let level: Float

    var body: some View {
        Capsule().fill(.quaternary)
            .frame(width: 48, height: 4)
            .overlay(alignment: .leading) {
                Capsule().fill(.green).frame(width: 48 * CGFloat(level), height: 4)
            }
    }
}
