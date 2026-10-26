import AppKit
import MetalKit

/// Compiled at runtime so the package needs no Metal resource bundle.
private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 size;      // drawable, pixels
    float2 halfSize;  // glowing rounded rect, pixels
    float radius;
    float time;
    float intensity;
    float burst;
    float width;
    float inner;      // 1: glow inward from the edge (screen), 0: outward (card)
    float scale;
    float pad;
};

struct VOut { float4 pos [[position]]; };

vertex VOut glow_vertex(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    VOut o;
    o.pos = float4(p[vid], 0, 1);
    return o;
}

constant float3 kColors[6] = {
    float3(0.55, 0.62, 1.00),
    float3(0.74, 0.51, 0.95),
    float3(0.96, 0.73, 0.92),
    float3(1.00, 0.40, 0.47),
    float3(1.00, 0.73, 0.44),
    float3(0.78, 0.53, 1.00),
};

float3 palette(float t) {
    t = fract(t) * 6.0;
    int i = int(t);
    float f = smoothstep(0.0, 1.0, fract(t));
    return mix(kColors[i % 6], kColors[(i + 1) % 6], f);
}

float sdRoundRect(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

fragment float4 glow_fragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 p = in.pos.xy - u.size * 0.5;
    float d = sdRoundRect(p, u.halfSize, u.radius);
    float tau = 6.2831853;
    float ang = atan2(p.y, p.x) / tau;
    float t = u.time;

    // Bands of light that drift along the perimeter.
    float flow = 0.5 + 0.5 * sin(ang * tau * 2.0 + t * 1.7) * sin(ang * tau * 3.0 - t * 1.1);
    float3 color = palette(ang + t * 0.07 + 0.08 * sin(t * 0.6 + ang * tau * 2.0));
    float breathe = 0.86 + 0.14 * sin(t * 1.9);

    float outside = u.inner > 0.5 ? -d : d;
    float w = u.width * (0.6 + 0.6 * flow) * (1.0 + u.burst * 0.9);
    float halo = outside > 0.0 ? exp(-outside / w) : 0.0;
    float rim = exp(-abs(d) / (1.1 * u.scale));
    float innerLight = outside < 0.0 ? exp(outside / (6.0 * u.scale)) * 0.25 : 0.0;

    float a = halo * (0.45 + 0.55 * flow) * breathe + rim * 0.85 + innerLight;
    a *= u.intensity * (1.0 + u.burst * 0.8);
    a = clamp(a, 0.0, 1.0);
    float3 c = mix(color, float3(1.0), clamp(rim * 0.4 + u.burst * 0.2, 0.0, 1.0));
    return float4(c * a, a);
}
"""

private struct Uniforms {
    var size: SIMD2<Float>
    var halfSize: SIMD2<Float>
    var radius: Float
    var time: Float
    var intensity: Float
    var burst: Float
    var width: Float
    var inner: Float
    var scale: Float
    var pad: Float = 0
}

/// An animated glow along a rounded rectangle: around the card, or inward
/// from the screen's edges.
final class GlowView: MTKView, MTKViewDelegate {
    enum Style {
        /// Glow outward from a rounded rect inset from the view's bounds.
        case ring(inset: CGFloat, cornerRadius: CGFloat)
        /// Glow inward from the view's edges.
        case edge
    }

    let style: Style
    let glowWidth: CGFloat
    /// The level the glow eases toward.
    var targetIntensity: Float = 0

    private var intensity: Float = 0
    private var burst: Float = 0
    private var pipeline: MTLRenderPipelineState!
    private var queue: MTLCommandQueue!
    private let start = CACurrentMediaTime()
    private var lastFrame = CACurrentMediaTime()

    init?(style: Style, glowWidth: CGFloat) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.style = style
        self.glowWidth = glowWidth
        super.init(frame: .zero, device: device)

        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "glow_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "glow_fragment")
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            FileHandle.standardError.write(Data("askenv: glow shader failed: \(error)\n".utf8))
            return nil
        }
        queue = device.makeCommandQueue()
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        layer?.isOpaque = false
        preferredFramesPerSecond = 120
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A brief swell, added on top of the current level.
    func kick(_ amount: Float) {
        burst = min(burst + amount, 1.4)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastFrame, 0.1))
        lastFrame = now
        intensity += (targetIntensity - intensity) * (1 - exp(-dt * 5))
        burst *= exp(-dt * 2.4)

        let scale = Float(window?.backingScaleFactor ?? 2)
        let size = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
        var halfSize = size / 2
        var radius: Float = 0
        var inner: Float = 1
        if case let .ring(inset, cornerRadius) = style {
            halfSize -= Float(inset) * scale
            radius = Float(cornerRadius) * scale
            inner = 0
        }
        var uniforms = Uniforms(
            size: size,
            halfSize: halfSize,
            radius: radius,
            time: Float(now - start),
            intensity: intensity,
            burst: burst,
            width: Float(glowWidth) * scale,
            inner: inner,
            scale: scale
        )

        guard let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}
