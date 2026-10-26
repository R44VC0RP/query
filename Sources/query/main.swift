import AppKit
import SwiftUI

/// A panel that takes keyboard focus without activating query, so the
/// app the person was using stays frontmost, like Spotlight.
final class PromptPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    // There is no menu bar to route edit shortcuts, so handle them here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let key = event.charactersIgnoringModifiers {
            let action: Selector? = switch key {
            case "v": #selector(NSText.paste(_:))
            case "c": #selector(NSText.copy(_:))
            case "x": #selector(NSText.cut(_:))
            case "a": #selector(NSText.selectAll(_:))
            case "z": Selector(("undo:"))
            default: nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
            if key == "w" || key == "q" { onCancel?(); return true }
        }
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z",
           NSApp.sendAction(Selector(("redo:")), to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// query is never the active app, so the first click must count.
final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

func roundedMask(radius: CGFloat) -> NSImage {
    let side = radius * 2 + 1
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
}

func fade(_ window: NSWindow, to alpha: CGFloat, duration: TimeInterval) {
    NSAnimationContext.runAnimationGroup { context in
        context.duration = duration
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        window.animator().alphaValue = alpha
    }
}

/// Moves and fades a window together, with a curve that settles gently.
func glide(_ window: NSWindow, to origin: NSPoint, alpha: CGFloat, duration: TimeInterval) {
    NSAnimationContext.runAnimationGroup { context in
        context.duration = duration
        context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        window.animator().setFrameOrigin(origin)
        window.animator().alphaValue = alpha
    }
}

func haptic() {
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
}

let request = parseArguments(Array(CommandLine.arguments.dropFirst()))

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let mouse = NSEvent.mouseLocation
let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!

// The card: glass, a dark tint, and the form.
let cardRadius: CGFloat = 22

accent = request.palette.accentColor
let model = PromptModel(request: request)
let hosting = DraggableHostingView(rootView: PromptView(model: model, cornerRadius: cardRadius))
hosting.sizingOptions = [.intrinsicContentSize]
let cardSize = hosting.fittingSize
let cardBounds = NSRect(origin: .zero, size: cardSize)

let panel = PromptPanel(
    contentRect: cardBounds,
    styleMask: [.borderless, .nonactivatingPanel],
    backing: .buffered,
    defer: false
)
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = true
panel.appearance = NSAppearance(named: .darkAqua)
panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
panel.hidesOnDeactivate = false
panel.isReleasedWhenClosed = false

let root = NSView(frame: cardBounds)
let glass = NSVisualEffectView(frame: cardBounds)
glass.material = .hudWindow
glass.blendingMode = .behindWindow
glass.state = .active
glass.maskImage = roundedMask(radius: cardRadius)
root.addSubview(glass)

let tint = NSView(frame: cardBounds)
tint.wantsLayer = true
tint.layer?.backgroundColor = NSColor(red: 0.03, green: 0.03, blue: 0.06, alpha: 0.62).cgColor
tint.layer?.cornerRadius = cardRadius
tint.layer?.cornerCurve = .continuous
root.addSubview(tint)

hosting.frame = cardBounds
root.addSubview(hosting)
panel.contentView = root

let visible = screen.visibleFrame
let restingOrigin = NSPoint(
    x: visible.midX - cardSize.width / 2,
    y: visible.maxY - visible.height * 0.24 - cardSize.height
)

// The screen dims, heavier toward its edges. Static, so it costs nothing per frame.
let dimWindow = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
dimWindow.isOpaque = false
dimWindow.backgroundColor = .clear
dimWindow.hasShadow = false
dimWindow.ignoresMouseEvents = true
dimWindow.level = .statusBar
dimWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
dimWindow.isReleasedWhenClosed = false
let dimView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
dimView.wantsLayer = true
let vignette = CAGradientLayer()
vignette.type = .radial
vignette.colors = [
    NSColor.black.withAlphaComponent(0.16).cgColor,
    NSColor.black.withAlphaComponent(0.2).cgColor,
    NSColor.black.withAlphaComponent(0.42).cgColor,
]
vignette.locations = [0, 0.35, 1]
vignette.startPoint = CGPoint(x: 0.5, y: 0.5)
vignette.endPoint = CGPoint(x: 1.1, y: 1.1)
vignette.frame = dimView.bounds
dimView.layer?.addSublayer(vignette)
dimWindow.contentView = dimView

// Light spills out from under the glass. A child window of the card, so the
// window server moves both together when the card is dragged.
let auraMargin: CGFloat = 200
let auraSize = NSSize(width: cardSize.width + auraMargin * 2, height: cardSize.height + auraMargin * 2)
let auraWindow = NSWindow(contentRect: NSRect(origin: .zero, size: auraSize), styleMask: .borderless, backing: .buffered, defer: false)
auraWindow.isOpaque = false
auraWindow.backgroundColor = .clear
auraWindow.hasShadow = false
auraWindow.ignoresMouseEvents = true
auraWindow.level = panel.level
auraWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
auraWindow.isReleasedWhenClosed = false
let backdrop = AuraView(size: auraSize, cardSize: cardSize, cardRadius: cardRadius, palette: request.palette)
if let backdrop { auraWindow.contentView = backdrop }

func placeAura() {
    let card = panel.frame
    auraWindow.setFrameOrigin(NSPoint(x: card.minX - auraMargin, y: card.minY - auraMargin))
}

// Typing stirs the light a little.
model.onType = { backdrop?.kick(0.05) }

func dismiss(submitted: Bool, then action: @escaping () -> Never) {
    let duration = submitted ? 0.4 : 0.22
    backdrop?.targetAura = 0
    if submitted {
        backdrop?.kick(0.5)
        haptic()
    }
    let origin = panel.frame.origin
    glide(panel, to: NSPoint(x: origin.x, y: origin.y - (submitted ? 8 : 4)), alpha: 0, duration: duration)
    fade(dimWindow, to: 0, duration: duration + 0.15)
    DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.15) {
        panel.orderOut(nil)
        dimWindow.orderOut(nil)
        action()
    }
}

model.onFinish = { values in
    guard let values else {
        dismiss(submitted: false) {
            FileHandle.standardError.write(Data("query: cancelled\n".utf8))
            exit(1)
        }
        return
    }
    dismiss(submitted: true) { deliver(values, for: request) }
}
panel.onCancel = { model.cancel() }

// Escape cancels even when a text field holds the keyboard.
NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
    guard event.keyCode == 53 else { return event }
    model.cancel()
    return nil
}

if let timeout = request.timeout {
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
        dismiss(submitted: false) {
            FileHandle.standardError.write(Data("query: timed out after \(Int(timeout))s\n".utf8))
            exit(124)
        }
    }
}

// Entrance: the screen dims and the light gathers, then the card rises into it.
dimWindow.alphaValue = 0
panel.alphaValue = 0
panel.setFrameOrigin(NSPoint(x: restingOrigin.x, y: restingOrigin.y - 14))
dimWindow.orderFrontRegardless()
panel.makeKeyAndOrderFront(nil)
placeAura()
panel.addChildWindow(auraWindow, ordered: .below)
fade(dimWindow, to: 1, duration: 0.5)
backdrop?.targetAura = 1
DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
    glide(panel, to: restingOrigin, alpha: 1, duration: 0.55)
    model.shown = true
    haptic()
}

app.run()
