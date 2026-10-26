import AppKit
import MetalKit

/// Compiled at runtime so the package needs no Metal resource bundle.
private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 size;      // drawable, pixels
    float2 cardHalf;  // pixels; the card is centered
    float radius;     // pixels
    float scale;      // pixels per point
    float time;
    float aura;
    float burst;
    float pad0;
    float pad1;
    float pad2;
    float4 deep;
    float4 body;
    float4 highlight;
};

struct VOut { float4 pos [[position]]; };

vertex VOut aura_vertex(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    VOut o;
    o.pos = float4(p[vid], 0, 1);
    return o;
}

float hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

float noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + float2(1, 0)), u.x),
               mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), u.x), u.y);
}

float fbm(float2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 4; i++) {
        v += a * noise(p);
        p = p * 2.03 + float2(1.7, 9.2);
        a *= 0.5;
    }
    return v;
}

float sdRoundRect(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

fragment float4 aura_fragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 p = in.pos.xy;
    float2 pt = p / u.scale;
    float t = u.time;

    // Distance from the card's edge, in points.
    float d = max(sdRoundRect(p - u.size * 0.5, u.cardHalf, u.radius), 0.0) / u.scale;

    // Slow smoke: domain-warped noise drifting upward.
    float2 q = pt / 110.0;
    float2 warp = float2(fbm(q + float2(0.0, t * 0.04)), fbm(q + float2(5.2, -t * 0.03)));
    float n = fbm(q * 1.3 + warp * 1.6 + float2(t * 0.015, -t * 0.03));

    float spread = 80.0 * (0.8 + 0.4 * n) * (1.0 + u.burst * 0.5);
    float light = exp(-d / spread) * (0.55 + 0.45 * n);
    float core = exp(-d / 10.0) * 0.35;  // tight light hugging the edge

    // Fade out before the window's edges so they never show.
    float2 edge = min(p, u.size - p) / u.scale;
    float fade = smoothstep(0.0, 90.0, min(edge.x, edge.y));

    float la = clamp((light * 0.42 + core) * u.aura * (1.0 + u.burst * 0.6) * fade, 0.0, 0.85);

    float3 color = mix(u.deep.rgb, u.body.rgb, smoothstep(0.35, 0.7, n));
    color = mix(color, u.highlight.rgb, 0.18 * smoothstep(0.62, 0.85, n));

    // Dither against banding in the soft gradients.
    float grain = (hash(p + fract(t) * 91.0) - 0.5) / 255.0;
    return float4(max(color * la + grain * la, 0.0), la);
}
"""

private struct Uniforms {
    var size: SIMD2<Float>
    var cardHalf: SIMD2<Float>
    var radius: Float
    var scale: Float
    var time: Float
    var aura: Float
    var burst: Float
    var pad0: Float = 0
    var pad1: Float = 0
    var pad2: Float = 0
    var deep: SIMD4<Float>
    var body: SIMD4<Float>
    var highlight: SIMD4<Float>
}

/// Slow, smoky light that spills out from behind a card centered in the view.
/// It lives in a child window of the card, so it moves with the card exactly.
final class AuraView: MTKView, MTKViewDelegate {
    var targetAura: Float = 0

    private let cardSize: CGSize
    private let cardRadius: CGFloat
    private let palette: Palette
    private var aura: Float = 0
    private var burst: Float = 0
    private var pipeline: MTLRenderPipelineState!
    private var queue: MTLCommandQueue!
    private let start = CACurrentMediaTime()
    private var lastFrame = CACurrentMediaTime()

    init?(size: CGSize, cardSize: CGSize, cardRadius: CGFloat, palette: Palette) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.cardSize = cardSize
        self.cardRadius = cardRadius
        self.palette = palette
        super.init(frame: NSRect(origin: .zero, size: size), device: device)
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "aura_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "aura_fragment")
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            FileHandle.standardError.write(Data("askenv: aura shader failed: \(error)\n".utf8))
            return nil
        }
        queue = device.makeCommandQueue()
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        layer?.isOpaque = false
        preferredFramesPerSecond = 120
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A brief swell of light.
    func kick(_ amount: Float) {
        burst = min(burst + amount, 1.2)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastFrame, 0.1))
        lastFrame = now
        aura += (targetAura - aura) * (1 - exp(-dt * 2.5))
        burst *= exp(-dt * 2)

        let scale = Float(drawableSize.width / max(bounds.width, 1))
        var uniforms = Uniforms(
            size: SIMD2(Float(drawableSize.width), Float(drawableSize.height)),
            cardHalf: SIMD2(Float(cardSize.width / 2), Float(cardSize.height / 2)) * scale,
            radius: Float(cardRadius) * scale,
            scale: scale,
            time: Float(now - start),
            aura: aura,
            burst: burst,
            deep: SIMD4(palette.deep, 1),
            body: SIMD4(palette.body, 1),
            highlight: SIMD4(palette.highlight, 1)
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
