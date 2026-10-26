import AppKit
import SwiftUI

/// A panel that takes keyboard focus without activating askenv, so the
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

let request = parseArguments(Array(CommandLine.arguments.dropFirst()))

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let mouse = NSEvent.mouseLocation
let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!

// Screen edges: a click-through window that glows inward from the edges.
let edgeWindow = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
edgeWindow.isOpaque = false
edgeWindow.backgroundColor = .clear
edgeWindow.hasShadow = false
edgeWindow.ignoresMouseEvents = true
edgeWindow.level = .statusBar
edgeWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
edgeWindow.isReleasedWhenClosed = false
let edgeGlow = GlowView(style: .edge, glowWidth: 48)
if let edgeGlow {
    edgeGlow.preferredFramesPerSecond = 60
    edgeWindow.contentView = edgeGlow
}

// The card: glass, the form, and a glowing ring drawn over its edge.
let cardRadius: CGFloat = 22
let margin: CGFloat = 90

let model = PromptModel(request: request)
let hosting = NSHostingView(rootView: PromptView(model: model))
hosting.sizingOptions = [.intrinsicContentSize]
let cardSize = hosting.fittingSize
let panelSize = NSSize(width: cardSize.width + margin * 2, height: cardSize.height + margin * 2)
let cardFrame = NSRect(x: margin, y: margin, width: cardSize.width, height: cardSize.height)

let panel = PromptPanel(
    contentRect: NSRect(origin: .zero, size: panelSize),
    styleMask: [.borderless, .nonactivatingPanel],
    backing: .buffered,
    defer: false
)
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = false
panel.appearance = NSAppearance(named: .darkAqua)
panel.isMovableByWindowBackground = true
panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
panel.hidesOnDeactivate = false
panel.isReleasedWhenClosed = false

let root = NSView(frame: NSRect(origin: .zero, size: panelSize))
let glass = NSVisualEffectView(frame: cardFrame)
glass.material = .hudWindow
glass.blendingMode = .behindWindow
glass.state = .active
glass.maskImage = roundedMask(radius: cardRadius)
root.addSubview(glass)

let tint = NSView(frame: cardFrame)
tint.wantsLayer = true
tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
tint.layer?.cornerRadius = cardRadius
tint.layer?.cornerCurve = .continuous
root.addSubview(tint)

hosting.frame = cardFrame
root.addSubview(hosting)

let ringGlow = GlowView(style: .ring(inset: margin, cornerRadius: cardRadius), glowWidth: 26)
if let ringGlow {
    ringGlow.frame = root.bounds
    root.addSubview(ringGlow)
}
panel.contentView = root

let visible = screen.visibleFrame
panel.setFrameOrigin(NSPoint(
    x: visible.midX - panelSize.width / 2,
    y: visible.maxY - visible.height * 0.18 - panelSize.height + margin
))

// Typing makes the light swell a little.
model.onType = {
    ringGlow?.kick(0.18)
    edgeGlow?.kick(0.08)
}

func dismiss(after delay: TimeInterval, then action: @escaping () -> Never) {
    ringGlow?.targetIntensity = 0
    edgeGlow?.targetIntensity = 0
    fade(panel, to: 0, duration: delay)
    fade(edgeWindow, to: 0, duration: delay)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        panel.orderOut(nil)
        edgeWindow.orderOut(nil)
        action()
    }
}

model.onFinish = { values in
    guard let values else {
        dismiss(after: 0.18) {
            FileHandle.standardError.write(Data("askenv: cancelled\n".utf8))
            exit(1)
        }
        return
    }
    ringGlow?.kick(1.2)
    edgeGlow?.kick(0.8)
    dismiss(after: 0.35) { deliver(values, for: request) }
}
panel.onCancel = { model.cancel() }

if let timeout = request.timeout {
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
        dismiss(after: 0.2) {
            FileHandle.standardError.write(Data("askenv: timed out after \(Int(timeout))s\n".utf8))
            exit(124)
        }
    }
}

// Entrance: the edges light up, then the card arrives in a swell of light.
edgeWindow.alphaValue = 0
panel.alphaValue = 0
edgeWindow.orderFrontRegardless()
panel.makeKeyAndOrderFront(nil)
edgeGlow?.targetIntensity = 1
edgeGlow?.kick(1.0)
fade(edgeWindow, to: 1, duration: 0.4)
DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
    ringGlow?.targetIntensity = 1
    ringGlow?.kick(1.2)
    fade(panel, to: 1, duration: 0.3)
    model.shown = true
}

app.run()
