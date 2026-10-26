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

let model = PromptModel(request: request)
let hosting = NSHostingView(rootView: PromptView(model: model, cornerRadius: cardRadius))
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
panel.isMovableByWindowBackground = true
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

// Behind the card: the screen dims and light spills out from under the glass.
let backdropWindow = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
backdropWindow.isOpaque = false
backdropWindow.backgroundColor = .clear
backdropWindow.hasShadow = false
backdropWindow.ignoresMouseEvents = true
backdropWindow.level = .statusBar
backdropWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
backdropWindow.isReleasedWhenClosed = false
let backdrop = BackdropView(screenFrame: screen.frame)
if let backdrop {
    backdrop.cardRadius = cardRadius
    backdrop.cardFrame = { panel.frame }
    backdropWindow.contentView = backdrop
}

// Typing stirs the light a little.
model.onType = { backdrop?.kick(0.05) }

func dismiss(submitted: Bool, then action: @escaping () -> Never) {
    let duration = submitted ? 0.4 : 0.22
    backdrop?.targetAura = 0
    backdrop?.targetDim = 0
    if submitted {
        backdrop?.kick(0.5)
        haptic()
    }
    let origin = panel.frame.origin
    glide(panel, to: NSPoint(x: origin.x, y: origin.y - (submitted ? 8 : 4)), alpha: 0, duration: duration)
    fade(backdropWindow, to: 0, duration: duration + 0.15)
    DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.15) {
        panel.orderOut(nil)
        backdropWindow.orderOut(nil)
        action()
    }
}

model.onFinish = { values in
    guard let values else {
        dismiss(submitted: false) {
            FileHandle.standardError.write(Data("askenv: cancelled\n".utf8))
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
            FileHandle.standardError.write(Data("askenv: timed out after \(Int(timeout))s\n".utf8))
            exit(124)
        }
    }
}

// Entrance: the screen dims and the light gathers, then the card rises into it.
backdropWindow.alphaValue = 1
panel.alphaValue = 0
panel.setFrameOrigin(NSPoint(x: restingOrigin.x, y: restingOrigin.y - 14))
backdropWindow.orderFrontRegardless()
panel.makeKeyAndOrderFront(nil)
backdrop?.targetDim = 1
backdrop?.targetAura = 1
DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
    glide(panel, to: restingOrigin, alpha: 1, duration: 0.55)
    model.shown = true
    haptic()
}

app.run()
