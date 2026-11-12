/// The renderer's Metal source, compiled at runtime by
/// `VideoEnhancementPipeline.make(device:)`.
///
/// Source rather than a `.metal` file in the target: SwiftPM's Metal
/// processing differs between toolchains and a host's archive step, and a
/// string compiles the same everywhere Metal exists. It is compiled once per
/// process (`VideoEnhancementPipeline.shared`), off the main actor.
///
/// Three fragment stages, all addressed in render-target pixels — nothing is
/// interpolated and nothing is filtered by a sampler, so each pass reads
/// exactly the texels it names:
///
/// 1. `enhancement_lanczos_horizontal`: the source's clean aperture →
///    output width × source height.
/// 2. `enhancement_lanczos_vertical`: → output width × output height.
/// 3. `enhancement_sharpen`: contrast-adaptive sharpening, at output size.
///
/// Both Lanczos passes clamp their result towards the two nearest source
/// samples (`antiRinging`): Lanczos' negative lobes ring on hard edges —
/// subtitles burned into the picture, letterbox edges, credits — and the
/// sharpening pass would only make the ringing louder.
enum VideoEnhancementShaders {
    static let vertexFunction = "enhancement_vertex"
    static let horizontalFunction = "enhancement_lanczos_horizontal"
    static let verticalFunction = "enhancement_lanczos_vertical"
    static let sharpenFunction = "enhancement_sharpen"

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct EnhancementVertex {
        float4 position [[position]];
    };

    // One triangle over the whole viewport.
    vertex EnhancementVertex enhancement_vertex(uint vid [[vertex_id]]) {
        float2 corner = float2(float((vid << 1) & 2), float(vid & 2));
        EnhancementVertex out;
        out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
        return out;
    }

    // Must match `VideoEnhancementPipeline.ScaleUniforms` byte for byte.
    struct ScaleUniforms {
        int2 sourceOrigin;   // first texel of the region read
        int2 sourceSize;     // texels in that region
        float2 targetOrigin; // render-target pixel where this pass's picture starts
        float2 targetSize;   // pixels in this pass's picture
        float antiRinging;   // 0 = plain Lanczos, 1 = fully clamped
        uint phases;         // entries in the weight table
    };

    // Must match `VideoEnhancementPipeline.SharpenUniforms`.
    struct SharpenUniforms {
        float2 targetOrigin;
        int2 size;
        float strength;
    };

    static inline float4 enhancement_fetch(texture2d<float, access::read> source,
                                           constant ScaleUniforms &u, int2 p) {
        int2 c = clamp(p, int2(0), u.sourceSize - int2(1));
        return source.read(uint2(u.sourceOrigin + c));
    }

    // One axis of the separable filter. `horizontal` picks the axis that is
    // resampled; the other is read one-to-one.
    static inline float4 enhancement_resample(texture2d<float, access::read> source,
                                              constant ScaleUniforms &u,
                                              constant float4 *weights,
                                              float2 pixel, bool horizontal) {
        float2 local = pixel - u.targetOrigin;
        float along = horizontal ? local.x : local.y;
        float targetLength = horizontal ? u.targetSize.x : u.targetSize.y;
        float sourceLength = float(horizontal ? u.sourceSize.x : u.sourceSize.y);
        // Pixel centres onto pixel centres.
        float position = along * sourceLength / targetLength - 0.5;
        float base = floor(position);
        float phase = position - base;
        uint index = min(uint(phase * float(u.phases - 1) + 0.5), u.phases - 1);
        float4 w = weights[index];
        int b = int(base);
        int across = int(floor(horizontal ? local.y : local.x));
        int2 step = horizontal ? int2(1, 0) : int2(0, 1);
        int2 origin = horizontal ? int2(b, across) : int2(across, b);
        float4 s0 = enhancement_fetch(source, u, origin - step);
        float4 s1 = enhancement_fetch(source, u, origin);
        float4 s2 = enhancement_fetch(source, u, origin + step);
        float4 s3 = enhancement_fetch(source, u, origin + step * 2);
        float4 result = s0 * w.x + s1 * w.y + s2 * w.z + s3 * w.w;
        float4 low = min(s1, s2);
        float4 high = max(s1, s2);
        return mix(result, clamp(result, low, high), float4(u.antiRinging));
    }

    fragment float4 enhancement_lanczos_horizontal(EnhancementVertex in [[stage_in]],
                                                   texture2d<float, access::read> source [[texture(0)]],
                                                   constant float4 *weights [[buffer(0)]],
                                                   constant ScaleUniforms &u [[buffer(1)]]) {
        return enhancement_resample(source, u, weights, in.position.xy, true);
    }

    fragment float4 enhancement_lanczos_vertical(EnhancementVertex in [[stage_in]],
                                                 texture2d<float, access::read> source [[texture(0)]],
                                                 constant float4 *weights [[buffer(0)]],
                                                 constant ScaleUniforms &u [[buffer(1)]]) {
        float4 value = enhancement_resample(source, u, weights, in.position.xy, false);
        return float4(value.rgb, 1.0);
    }

    // Contrast-adaptive sharpening on a five-sample cross.
    //
    // The boost follows the neighbourhood's luma contrast: none on flat
    // areas (grain and compression noise are all a flat area has to
    // sharpen), most on soft texture, and less again on edges that are
    // already hard, which is where halos start. The result is held inside
    // the neighbourhood's own range per channel, so it steepens a transition
    // without ever overshooting it.
    fragment float4 enhancement_sharpen(EnhancementVertex in [[stage_in]],
                                        texture2d<float, access::read> source [[texture(0)]],
                                        constant SharpenUniforms &u [[buffer(0)]]) {
        int2 p = int2(floor(in.position.xy - u.targetOrigin));
        int2 last = u.size - int2(1);
        float3 c = source.read(uint2(clamp(p, int2(0), last))).rgb;
        float3 n = source.read(uint2(clamp(p + int2(0, -1), int2(0), last))).rgb;
        float3 s = source.read(uint2(clamp(p + int2(0, 1), int2(0), last))).rgb;
        float3 e = source.read(uint2(clamp(p + int2(1, 0), int2(0), last))).rgb;
        float3 w = source.read(uint2(clamp(p + int2(-1, 0), int2(0), last))).rgb;

        const float3 luma = float3(0.2126, 0.7152, 0.0722);
        float lc = dot(c, luma);
        float ln = dot(n, luma);
        float ls = dot(s, luma);
        float le = dot(e, luma);
        float lw = dot(w, luma);
        float lowLuma = min(lc, min(min(ln, ls), min(le, lw)));
        float highLuma = max(lc, max(max(ln, ls), max(le, lw)));
        float contrast = highLuma - lowLuma;

        float gain = u.strength
            * smoothstep(0.012, 0.05, contrast)
            * (1.0 - smoothstep(0.3, 0.7, contrast));

        float3 blur = (n + s + e + w) * 0.25;
        float3 sharpened = c + (c - blur) * (gain * 2.0);
        float3 low = min(c, min(min(n, s), min(e, w)));
        float3 high = max(c, max(max(n, s), max(e, w)));
        return float4(saturate(clamp(sharpened, low, high)), 1.0);
    }
    """
}
