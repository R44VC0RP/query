import AppKit
import SwiftUI

enum Typeface {
    static func sans(_ size: CGFloat) -> Font { .custom("Helvetica Neue", size: size) }
    static func mono(_ size: CGFloat) -> Font { .custom("BerkeleyMonoVariable-Regular", size: size) }
}

/// The one accent, matching the light behind the card. Set from the palette at launch.
var accent = Color(red: 0.52, green: 0.50, blue: 1.0)

final class PromptModel: ObservableObject {
    let request: Request
    /// Who asks, why, and where the values go. Shown on hover only.
    let context: String

    @Published var values: [String: String] = [:]
    @Published var shown = false
    @Published var focusRequest: String?
    @Published var shakes: [String: Int] = [:]

    private var finished = false
    var onFinish: (([(String, String)]?) -> Void)?
    var onType: (() -> Void)?

    init(request: Request) {
        self.request = request
        let requester = requesterName()
        let directory = abbreviatedPath(FileManager.default.currentDirectoryPath)
        let destination = switch request.mode {
        case .run(let command): "Passed to \(command.map(displayWord).joined(separator: " ")) in \(directory)"
        case .write(let path): "Saved to \(path) in \(directory)"
        case .get: "Returned to \(requester) in \(directory)"
        }
        context = [requester, request.reason, destination].compactMap { $0 }.joined(separator: "\n")
    }

    var isComplete: Bool {
        request.keys.allSatisfy { !(values[$0.name] ?? "").isEmpty }
    }

    func submit() {
        if let empty = request.keys.first(where: { (values[$0.name] ?? "").isEmpty }) {
            shakes[empty.name, default: 0] += 1
            focusRequest = empty.name
            return
        }
        finish(request.keys.map { ($0.name, values[$0.name] ?? "") })
    }

    func cancel() { finish(nil) }

    private func finish(_ result: [(String, String)]?) {
        guard !finished else { return }
        finished = true
        onFinish?(result)
    }
}

struct PromptView: View {
    @ObservedObject var model: PromptModel
    let cornerRadius: CGFloat
    @FocusState private var focused: String?
    @State private var revealed: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Beacon()
                    .frame(width: 8, height: 8)
                Text("Your input is required")
                    .font(Typeface.sans(13.5).weight(.medium))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer(minLength: 8)
                Button(action: model.submit) {
                    Image(systemName: "return")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(.white.opacity(model.isComplete ? 0.16 : 0.06))
                        )
                        .foregroundStyle(.white.opacity(model.isComplete ? 0.95 : 0.35))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .animation(.easeOut(duration: 0.2), value: model.isComplete)
            }
            .help(model.context)
            .opacity(model.shown ? 1 : 0)
            .offset(y: model.shown ? 0 : 6)
            .animation(.spring(duration: 0.5, bounce: 0.2).delay(0.05), value: model.shown)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(model.request.keys.enumerated()), id: \.element.id) { index, key in
                    field(for: key)
                        .opacity(model.shown ? 1 : 0)
                        .offset(y: model.shown ? 0 : 10)
                        .animation(
                            .spring(duration: 0.55, bounce: 0.2).delay(0.12 + 0.06 * Double(index)),
                            value: model.shown
                        )
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 22)
        .background(WindowDragArea())
        .background(
            // Light falls from above: a faint lift at the top of the glass.
            LinearGradient(colors: [.white.opacity(0.045), .clear], startPoint: .top, endPoint: .center)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        )
        .overlay(
            // A lit top edge that fades down the sides.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.2), .white.opacity(0.06), .white.opacity(0.03)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .frame(width: 420)
        .onChange(of: model.shown) { _, shown in
            if shown { focused = model.request.keys.first?.name }
        }
        .onChange(of: model.focusRequest) { _, name in
            if let name { focused = name }
            model.focusRequest = nil
        }
        .onChange(of: model.values) { _, _ in model.onType?() }
    }

    private func field(for key: KeySpec) -> some View {
        let name = key.name
        let text = Binding(
            get: { model.values[name] ?? "" },
            set: { model.values[name] = $0 }
        )
        let isRevealed = revealed.contains(name)
        let isFocused = focused == name

        return VStack(alignment: .leading, spacing: 7) {
            Text(name)
                .font(Typeface.mono(11.5))
                .foregroundStyle(.white.opacity(isFocused ? 0.85 : 0.5))
                .help(key.hint ?? "")
                .animation(.easeOut(duration: 0.2), value: isFocused)

            HStack(spacing: 8) {
                Group {
                    if isRevealed {
                        TextField("", text: text)
                    } else {
                        SecureField("", text: text)
                    }
                }
                .textFieldStyle(.plain)
                .font(Typeface.mono(14))
                .foregroundStyle(.white)
                .tint(accent)
                .focused($focused, equals: name)
                .onSubmit { advance(from: name) }

                Button {
                    if isRevealed { revealed.remove(name) } else { revealed.insert(name) }
                    DispatchQueue.main.async { focused = name }
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.leading, 12)
            .padding(.trailing, 9)
            .frame(height: 38)
            .background(Well(active: isFocused))
            .contentShape(Rectangle())
            .onTapGesture { focused = name }
            .modifier(Shake(travel: CGFloat(model.shakes[name] ?? 0)))
            .animation(.easeOut(duration: 0.2), value: isFocused)
            .animation(.linear(duration: 0.4), value: model.shakes[name] ?? 0)
        }
    }

    /// Return moves to the next empty field, or submits once every field has a value.
    private func advance(from name: String) {
        if model.isComplete {
            model.submit()
            return
        }
        let keys = model.request.keys.map(\.name)
        let start = (keys.firstIndex(of: name) ?? 0) + 1
        let ordered = keys[start...] + keys[..<start]
        focused = ordered.first { (model.values[$0] ?? "").isEmpty }
    }
}

/// A field recessed into the glass: darker than the card, shaded at the top,
/// with a faint lower lip catching the light. Focus lights it from within.
private struct Well: View {
    let active: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        shape
            .fill(Color.black.opacity(active ? 0.42 : 0.32))
            .overlay(
                shape
                    .stroke(Color.black.opacity(0.55), lineWidth: 2)
                    .blur(radius: 1.5)
                    .offset(y: 1)
                    .clipShape(shape)
            )
            .overlay(
                shape.strokeBorder(
                    active
                        ? AnyShapeStyle(accent.opacity(0.55))
                        : AnyShapeStyle(LinearGradient(
                            colors: [.black.opacity(0.3), .white.opacity(0.07)],
                            startPoint: .top,
                            endPoint: .bottom
                        )),
                    lineWidth: 1
                )
            )
            .shadow(color: accent.opacity(active ? 0.28 : 0), radius: 10)
    }
}

/// Behind the content: a press anywhere that is not a field or button
/// drags the window.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

/// A small light that breathes while the prompt waits.
private struct Beacon: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breath = 0.5 + 0.5 * sin(t * 1.6)
            Circle()
                .fill(accent)
                .shadow(color: accent.opacity(0.5 + 0.4 * breath), radius: 3 + 4 * breath)
                .opacity(0.75 + 0.25 * breath)
        }
    }
}

private struct Shake: GeometryEffect {
    var travel: CGFloat
    var animatableData: CGFloat {
        get { travel }
        set { travel = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 6 * sin(travel * .pi * 4), y: 0))
    }
}
