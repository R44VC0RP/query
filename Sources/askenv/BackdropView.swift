import AppKit
import MetalKit

/// Compiled at runtime so the package needs no Metal resource bundle.
private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 size;        // drawable, pixels
    float2 cardCenter;  // pixels, origin top-left
    float2 cardHalf;    // pixels
    float radius;       // pixels
    float scale;        // pixels per point
    float time;
    float dim;
    float aura;
    float burst;
};

struct VOut { float4 pos [[position]]; };

vertex VOut backdrop_vertex(uint vid [[vertex_id]]) {
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
    for (int i = 0; i < 5; i++) {
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

fragment float4 backdrop_fragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 p = in.pos.xy;
    float2 pt = p / u.scale;
    float t = u.time;

    // Distance from the card's edge, in points.
    float d = max(sdRoundRect(p - u.cardCenter, u.cardHalf, u.radius), 0.0) / u.scale;

    // Slow smoke: domain-warped noise drifting upward.
    float2 q = pt / 110.0;
    float2 warp = float2(fbm(q + float2(0.0, t * 0.04)), fbm(q + float2(5.2, -t * 0.03)));
    float n = fbm(q * 1.3 + warp * 1.6 + float2(t * 0.015, -t * 0.03));

    float spread = 80.0 * (0.8 + 0.4 * n) * (1.0 + u.burst * 0.5);
    float light = exp(-d / spread) * (0.55 + 0.45 * n);
    float core = exp(-d / 10.0) * 0.35;  // tight light hugging the edge
    float la = clamp((light * 0.42 + core) * u.aura * (1.0 + u.burst * 0.6), 0.0, 0.85);

    float3 deep = float3(0.16, 0.18, 0.62);
    float3 violet = float3(0.47, 0.30, 0.92);
    float3 rose = float3(0.90, 0.52, 0.78);
    float3 color = mix(deep, violet, smoothstep(0.35, 0.7, n));
    color = mix(color, rose, 0.18 * smoothstep(0.62, 0.85, n));

    // Dim the screen, heavier toward the edges.
    float2 uv = p / u.size - 0.5;
    float vignette = smoothstep(0.15, 0.85, length(uv * float2(1.0, 1.15)));
    float dimA = u.dim * (0.16 + 0.26 * vignette);

    float a = dimA * (1.0 - la) + la;
    float3 rgb = color * la;
    // Dither against banding in the soft gradients.
    float grain = (hash(p + fract(t) * 91.0) - 0.5) / 255.0;
    return float4(max(rgb + grain, 0.0), a);
}
"""

private struct Uniforms {
    var size: SIMD2<Float>
    var cardCenter: SIMD2<Float>
    var cardHalf: SIMD2<Float>
    var radius: Float
    var scale: Float
    var time: Float
    var dim: Float
    var aura: Float
    var burst: Float
}

/// Full-screen, click-through layer that dims the screen and lets a slow,
/// smoky light spill out from behind the card.
final class BackdropView: MTKView, MTKViewDelegate {
    /// The card's frame in screen coordinates, read every frame so the light
    /// follows the card when it is dragged.
    var cardFrame: () -> NSRect = { .zero }
    var cardRadius: CGFloat = 22
    var screenFrame: NSRect = .zero

    var targetDim: Float = 0
    var targetAura: Float = 0

    private var dim: Float = 0
    private var aura: Float = 0
    private var burst: Float = 0
    private var pipeline: MTLRenderPipelineState!
    private var queue: MTLCommandQueue!
    private let start = CACurrentMediaTime()
    private var lastFrame = CACurrentMediaTime()

    init?(screenFrame: NSRect) {
        self.screenFrame = screenFrame
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        super.init(frame: NSRect(origin: .zero, size: screenFrame.size), device: device)
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "backdrop_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "backdrop_fragment")
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            FileHandle.standardError.write(Data("askenv: backdrop shader failed: \(error)\n".utf8))
            return nil
        }
        queue = device.makeCommandQueue()
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        layer?.isOpaque = false
        // Everything here is soft, so render at one pixel per point.
        autoResizeDrawable = false
        drawableSize = screenFrame.size
        preferredFramesPerSecond = 60
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        drawableSize = newSize
    }

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
        dim += (targetDim - dim) * (1 - exp(-dt * 4))
        aura += (targetAura - aura) * (1 - exp(-dt * 2.5))
        burst *= exp(-dt * 2)

        let scale = Float(drawableSize.width / max(bounds.width, 1))
        let card = cardFrame()
        let center = SIMD2<Float>(
            Float(card.midX - screenFrame.minX) * scale,
            Float(screenFrame.maxY - card.midY) * scale
        )
        var uniforms = Uniforms(
            size: SIMD2(Float(drawableSize.width), Float(drawableSize.height)),
            cardCenter: center,
            cardHalf: SIMD2(Float(card.width / 2), Float(card.height / 2)) * scale,
            radius: Float(cardRadius) * scale,
            scale: scale,
            time: Float(now - start),
            dim: dim,
            aura: aura,
            burst: burst
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
