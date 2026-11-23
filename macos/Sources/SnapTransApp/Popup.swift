import AppKit
import SwiftUI

/// State of the result card.
@MainActor
final class PopupModel: ObservableObject {
    @Published var status = ""
    @Published var warning: String?
    @Published var translation = ""
    @Published var source = ""
    @Published var message = ""          // error / stage text when there is no translation
    @Published var busy = false
    @Published var showingSource = false
    @Published var copied = false
    @Published var dark = true

    var body: String { showingSource ? source : (translation.isEmpty ? message : translation) }
    var canToggle: Bool { !source.isEmpty && !translation.isEmpty }
    var canCopy: Bool { !(showingSource ? source : (translation.isEmpty ? source : translation)).isEmpty }
}

/// Palette shared with the Windows card: dark navy (#273242) with light text, or a light variant in the light theme.
struct PopupPalette {
    let dark: Bool
    var background: Color { dark ? Color(red: 39 / 255, green: 50 / 255, blue: 66 / 255) : Color(red: 248 / 255, green: 250 / 255, blue: 253 / 255) }
    var title: Color { dark ? Color(red: 190 / 255, green: 201 / 255, blue: 217 / 255) : Color(red: 52 / 255, green: 66 / 255, blue: 86 / 255) }
    var status: Color { dark ? Color(red: 140 / 255, green: 154 / 255, blue: 175 / 255) : Color(red: 104 / 255, green: 116 / 255, blue: 134 / 255) }
    var body: Color { dark ? .white : Color(red: 26 / 255, green: 30 / 255, blue: 36 / 255) }
    var edge: Color { dark ? Color(red: 58 / 255, green: 72 / 255, blue: 92 / 255) : Color(red: 214 / 255, green: 221 / 255, blue: 230 / 255) }
    var hover: Color { dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06) }
}

struct PopupIconButton: View {
    let symbol: String
    let help: String
    let enabled: Bool
    let palette: PopupPalette
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.title.opacity(enabled ? 1 : 0.35))
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering && enabled ? palette.hover : .clear))
        .onHover { hovering = $0 }
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct PopupView: View {
    @ObservedObject var model: PopupModel
    let onCopy: () -> Void
    let onToggle: () -> Void
    let onClose: () -> Void

    var body: some View {
        let p = PopupPalette(dark: model.dark)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(Loc.t(model.showingSource ? "Popup_TitleSource" : "Popup_Title"))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(p.title).lineLimit(1)
                HStack(spacing: 6) {
                    Text(model.status).font(.system(size: 12)).foregroundStyle(p.status).lineLimit(1).truncationMode(.tail)
                        .accessibilityIdentifier("PopupStatus")
                    if let w = model.warning {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12))
                            .foregroundStyle(Color(red: 1, green: 0.784, blue: 0.341)).help(w).accessibilityLabel(w)
                    }
                }.padding(.leading, 10).padding(.trailing, 8)
                Spacer(minLength: 0)
                // Fixed "switch" glyph; the header says what is shown, the tooltip says where the button goes.
                PopupIconButton(symbol: "arrow.left.arrow.right", help: Loc.t(model.showingSource ? "Popup_ShowTranslation" : "Popup_ShowSource"),
                                enabled: model.canToggle, palette: p, action: onToggle)
                PopupIconButton(symbol: model.copied ? "checkmark" : "doc.on.doc", help: Loc.t(model.copied ? "Popup_Copied" : "Popup_Copy"),
                                enabled: model.canCopy, palette: p, action: onCopy)
                PopupIconButton(symbol: "xmark", help: Loc.t("Popup_Close"), enabled: true, palette: p, action: onClose)
            }
            .padding(.leading, 20).padding(.trailing, 8).padding(.top, 10).padding(.bottom, 2)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    if model.busy { ProgressView().progressViewStyle(.linear).tint(Color(red: 0.30, green: 0.76, blue: 1.0)).padding(.top, 6) }
                    if !model.body.isEmpty {
                        Text(model.body)
                            .font(.system(size: PopupController.bodyFontSize))
                            .lineSpacing(PopupController.bodyLineSpacing)
                            .foregroundStyle(p.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("PopupBodyText")
                    }
                }
                .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 16)
            }
            .scrollIndicators(.automatic)
        }
        .background(p.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(p.edge, lineWidth: 1))
    }
}

/// The result card: a non-activating NSPanel (never takes focus from the app being read), always on top, moved by
/// dragging its background, closed with × or Esc.
@MainActor
final class PopupController {
    static let bodyFontSize: CGFloat = 16
    static let bodyLineSpacing: CGFloat = 5
    final class Panel: NSPanel {
        var onEscape: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { onEscape?() }
    }

    let model = PopupModel()
    private var panel: Panel?
    private var anchor: CGRect = .zero    // CG global
    private var copyReset: DispatchWorkItem?
    var isVisible: Bool { panel?.isVisible == true }
    var window: NSWindow? { panel }

    private func ensurePanel() -> Panel {
        if let panel { return panel }
        let p = Panel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 160), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.title = "MyPLaMo SnapTrans"
        p.onEscape = { [weak self] in self?.hide() }
        let view = PopupView(model: model, onCopy: { [weak self] in self?.copy() }, onToggle: { [weak self] in self?.toggle() }, onClose: { [weak self] in self?.hide() })
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        p.contentView = host
        panel = p
        return p
    }

    func applyTheme(dark: Bool) { model.dark = dark; panel?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua) }

    /// Shows the card next to a CG-global selection rectangle.
    func show(at selection: CGRect, stage: String) {
        anchor = selection
        model.translation = ""; model.source = ""; model.message = ""; model.warning = nil
        model.showingSource = false; model.busy = true; model.status = stage; model.copied = false
        let p = ensurePanel()
        fit(reposition: true)
        p.orderFrontRegardless()
    }

    func setStage(_ s: String) { model.status = s }

    func setResult(translation: String, source: String, status: String, warning: String?) {
        model.translation = translation; model.source = source; model.status = status; model.warning = warning
        model.busy = false; model.showingSource = false; model.message = ""
        fit(reposition: false)
    }

    func setError(_ message: String, source: String) {
        model.translation = ""; model.source = source; model.message = message; model.status = ""
        model.busy = false; model.showingSource = false
        fit(reposition: false)
    }

    func hide() { panel?.orderOut(nil) }

    func copy() {
        let text = model.showingSource ? model.source : (model.translation.isEmpty ? model.source : model.translation)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.copied = true
        copyReset?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.model.copied = false }
        copyReset = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    func toggle() {
        guard model.canToggle else { return }
        model.showingSource.toggle()
        fit(reposition: false)
    }

    /// Sizes the card for its content: width follows the selection (380–720 pt), height the text (≤ 70 % of the
    /// screen). A new card goes below the selection (above it when there is no room), always on that screen.
    private func fit(reposition: Bool) {
        guard let p = panel else { return }
        let screen = reposition ? (Geometry.screen(forCG: anchor) ?? NSScreen.main!) : (p.screen ?? NSScreen.main!)
        let work = screen.visibleFrame
        let width = reposition ? min(max(anchor.width, 380), max(380, min(720, work.width - 16))) : p.frame.width
        let textWidth = width - 40
        let font = NSFont.systemFont(ofSize: Self.bodyFontSize)
        let para = NSMutableParagraphStyle(); para.lineSpacing = Self.bodyLineSpacing
        let body = model.body
        let textHeight = body.isEmpty ? 0 : ceil(NSAttributedString(string: body, attributes: [.font: font, .paragraphStyle: para])
            .boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        let header: CGFloat = 40
        let busy: CGFloat = model.busy ? 18 : 0
        let height = min(max(header + 4 + busy + textHeight + 20, 96), work.height * 0.7)
        var frame = p.frame
        frame.size = NSSize(width: width, height: height)
        if reposition {
            let a = Geometry.appKit(fromCG: anchor)
            let gap: CGFloat = 10
            frame.origin.x = a.minX
            frame.origin.y = a.minY - gap - height                         // below the selection
            if frame.minY < work.minY { frame.origin.y = a.maxY + gap }    // above it
            if frame.maxY > work.maxY { frame.origin.y = max(work.minY, work.maxY - height) }
        } else {
            frame.origin.y = p.frame.maxY - height                         // keep the top edge, grow downwards
            if frame.minY < work.minY { frame.origin.y = work.minY }
        }
        frame.origin.x = min(max(frame.minX, work.minX), max(work.minX, work.maxX - width))
        p.setFrame(frame, display: true)
    }
}
