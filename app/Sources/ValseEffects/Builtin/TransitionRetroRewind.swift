/// TR-RETRO-REWIND: CapCut's "Retro Rewind" (2 s overlap transition), rebuilt from its effect package and matched
/// frame by frame against CapCut's own export (1080p30, see the branch report for the error table).
///
/// CapCut's graph, on the authored 2 s timeline `T`:
/// 1. each clip goes through Tone (mix towards luma601 × 0.494 grey) and a mirrored horizontal pan whose position
///    keyframes are *hold* keys (step function on the 30 fps grid; the layer shows 0.75 current + 0.25 previous key);
///    A is shown for frames 0…29, B from frame 30 (mid-pan, at a mirrored position).
/// 2. a horizontal gaussian blur adjustment layer (CapCut's tap count / sigma / dropped out-of-frame taps).
/// 3. an overlay video (normal blend, colour treated as premultiplied, opacity ramps in/out over 4 frames), one frame
///    late: a white ◀◀ with a soft drop shadow that rises in, "rewinds" (the left then the right triangle slide left
///    and spring back) and drops out; a halftone dot screen whose phase jumps every frame; a drifting vertical
///    scratch line; film dust. We cannot ship that video: everything is procedural here, driven by per-frame tables
///    measured from it (icon offsets, dot phases, scratch line) plus hashed dust with the same size/density statistics.
extension BuiltinTransitions {
    /// Program-scope MSL for `retroRewind`. Overlay lengths are in pixels of CapCut's 512-px-high overlay video.
    static let retroRewindLib = retroLib(forward: false)
    /// TR-RETRO-FF: the same pipeline mirrored (▶▶, pan and scratch line running the other way).
    static let retroFastForwardLib = retroLib(forward: true)

    static func retroLib(forward: Bool) -> String { """
    \(retroRewindTables)
    constant float RR_FLIP = \(forward ? "-1.0" : "1.0");
    constant float RR_P = 11.2;                // halftone lattice pitch (16:9 video px)
    // halftone dot alpha by distance from its centre, 0.125 + 0.25 i video px (measured)
    constant float RR_DOT[14] = {0.201, 0.202, 0.205, 0.204, 0.197, 0.182, 0.151, 0.113, 0.076, 0.044, 0.018, 0.005, 0.002, 0.0};
    // CapCut's grey carries a faint warm cast (+1 V, +0.15 Y in 8-bit Rec.709 at full tone)
    constant float3 RR_TINT = float3(0.007715, -0.001405, 0.000685);

    inline float rr_glmod(float x, float y) { return x - y * floor(x / y); }
    inline float rr_mirror(float u) { return abs(rr_glmod(u - 1.0, 2.0) - 1.0); }

    /// CSS-style cubic-bezier(x1, y1, x2, y2) easing of x ∈ [0,1] (bisection on the curve parameter).
    inline float rr_bezier(float x, float x1, float y1, float x2, float y2) {
        x = saturate(x);
        float lo = 0.0, hi = 1.0, u = x;
        for (int i = 0; i < 20; i++) {
            u = 0.5 * (lo + hi);
            float m = 1.0 - u;
            float bx = 3.0 * m * m * u * x1 + 3.0 * m * u * u * x2 + u * u * u;
            if (bx < x) lo = u; else hi = u;
        }
        float m = 1.0 - u;
        return 3.0 * m * m * u * y1 + 3.0 * m * u * u * y2 + u * u * u;
    }
    inline float rr_tone(float T) {
        if (T < 0.333333) return rr_bezier(T / 0.333333, 0.73, 0.0, 0.27, 1.0);
        if (T < 1.6) return 1.0;
        if (T < 1.933333) return 1.0 - rr_bezier((T - 1.6) / 0.333333, 0.73, 0.0, 0.27, 1.0);
        return 0.0;
    }
    inline float rr_blurIntensity(float T) {
        if (T >= 0.533333 && T < 0.966667) return 20.0 * rr_bezier((T - 0.533333) / 0.433334, 0.33333333, 0.0, 0.0, 0.999999923);
        if (T >= 0.966667 && T < 1.466667) return 20.0 * (1.0 - rr_bezier((T - 0.966667) / 0.5, 1.0, 1.19e-7, 0.66666667, 1.0));
        return 0.0;
    }
    /// CapCut's directional-blur tap count for an intensity (getSampleNum, quality 0.5).
    inline float rr_samples(float I) {
        float n = I <= 10.0 ? 0.8 * I : (I <= 50.0 ? (0.7 * I + 2.0) * 0.78 : (0.5 * I + 10.0) * 0.66);
        return n < 2.0 ? floor(n + 0.5) : n;
    }
    inline float rr_opacity(float T) {
        if (T < 0.133333) return max(T, 0.0) / 0.133333;
        if (T < 1.833333) return 1.0;
        if (T < 1.966667) return 1.0 - (T - 1.833333) / 0.133334;
        return 0.0;
    }
    inline float3 rr_tap(texture2d<float> from, texture2d<float> to, sampler s, bool useB, float x, float y, float pan) {
        float2 q = float2(rr_mirror(x - pan), y);
        return (useB ? to.sample(s, q) : from.sample(s, q)).rgb;
    }

    /// The blur runs on a downscaled copy (80 % / 70 % of the canvas, bilinear): one tap = bilinear over that grid.
    /// (Horizontal only: the blur is horizontal and the vertical resampling costs more than it is worth.)
    inline float3 rr_tapD(texture2d<float> from, texture2d<float> to, sampler s, bool useB, float x, float y, float pan, float2 dsz) {
        float g = x * dsz.x - 0.5;
        float i0 = floor(g), f = g - i0;
        float lo = clamp((i0 + 0.5) / dsz.x, 0.5 / dsz.x, 1.0 - 0.5 / dsz.x), hi = clamp((i0 + 1.5) / dsz.x, 0.5 / dsz.x, 1.0 - 0.5 / dsz.x);
        return mix(rr_tap(from, to, s, useB, lo, y, pan), rr_tap(from, to, s, useB, hi, y, pan), f);
    }

    /// Signed distance to triangle p0 p1 p2 (negative inside).
    inline float rr_sdTri(float2 p, float2 p0, float2 p1, float2 p2) {
        float2 e0 = p1 - p0, e1 = p2 - p1, e2 = p0 - p2;
        float2 v0 = p - p0, v1 = p - p1, v2 = p - p2;
        float2 a = v0 - e0 * saturate(dot(v0, e0) / dot(e0, e0));
        float2 b = v1 - e1 * saturate(dot(v1, e1) / dot(e1, e1));
        float2 c = v2 - e2 * saturate(dot(v2, e2) / dot(e2, e2));
        float sg = sign(e0.x * e2.y - e0.y * e2.x);
        float2 d = min(min(float2(dot(a, a), sg * (v0.x * e0.y - v0.y * e0.x)),
                           float2(dot(b, b), sg * (v1.x * e1.y - v1.y * e1.x))),
                       float2(dot(c, c), sg * (v2.x * e2.y - v2.y * e2.x)));
        return -sqrt(d.x) * sign(d.y);
    }
    /// ◀◀: union of two rounded triangles (centre-relative 16:9 video px), left one at offset ol, right one at or.
    inline float rr_sdIcon(float2 p, float2 ol, float2 orr) {
        float2 a = p - ol, b = p - orr;
        float l = rr_sdTri(a, float2(-113.71, 0.0), float2(3.33, -91.8), float2(3.33, 91.8));
        float r = rr_sdTri(b, float2(-2.80, 0.0), float2(114.29, -91.8), float2(114.29, 91.8));
        return min(l, r) - 14.5;
    }
    /// Same silhouette in a per-axis scaled space (q, offsets and vertices divided by sg), corner radius r there.
    inline float rr_sdIconScaled(float2 q, float2 ol, float2 orr, float2 sg, float r) {
        float2 a = q - ol / sg, b = q - orr / sg;
        float l = rr_sdTri(a, float2(-113.71, 0.0) / sg, float2(3.33, -91.8) / sg, float2(3.33, 91.8) / sg);
        float rr = rr_sdTri(b, float2(-2.80, 0.0) / sg, float2(114.29, -91.8) / sg, float2(114.29, 91.8) / sg);
        return min(l, rr) - r;
    }
    inline float rr_erfc01(float z) {        // 0.5 * erfc(z), tanh approximation
        z = clamp(z, -4.0, 4.0);             // (fast-math tanh overflows to NaN for large arguments)
        return 0.5 * (1.0 - tanh(z * (1.128379 + 0.10294 * z * z)));
    }
    inline float2 rr_iconOffset(int j, bool right) {
        j = clamp(j, 0, 59);
        return right ? float2(RR_IXR[j], RR_IYR[j]) : float2(RR_IXL[j], RR_IYL[j]);
    }

    /// Film dust of overlay frame j at q (512-high video px, scaled to 16:9 density); returns coverage (white).
    inline float rr_dust(float2 q, int j, float2 ext) {
        float jf = float(j);
        float a = 0.0;
        // specks: at most one per 16 px cell
        float2 cell = floor(q / 16.0);
        float h = fx_hash(cell + float2(jf * 13.17, jf * 7.31));
        if (h < 0.062) {
            float2 c = (cell + 0.2 + 0.6 * float2(fx_hash(cell + h * 3.7), fx_hash(cell - h * 5.3))) * 16.0;
            float rad = 0.55 + 1.1 * pow(fract(h * 91.7), 2.0);
            float br = 0.55 + 0.45 * fract(h * 53.1);
            a = br * saturate((rad + 0.75 - length(q - c)) / 1.5);
        }
        // fibres: 16 short curls + 7 long hairs
        for (int i = 0; i < 23; i++) {
            float2 seed = float2(jf * 1.913 + 0.37, float(i) * 7.77 + 1.3);
            bool longOne = i >= 16;
            float2 c = float2(fx_hash(seed + 1.1), fx_hash(seed + 2.3)) * ext;
            float hl = fx_hash(seed + 4.9);
            float len = longOne ? 8.0 + 80.0 * pow(hl, 2.5) : 2.5 + 4.5 * hl;
            float2 d = q - c;
            if (abs(d.x) > len + 12.0 || abs(d.y) > len + 12.0) continue;
            float2 l = tr_rot(d, -fx_hash(seed + 3.7) * 6.2832);
            if (abs(l.x) > len) continue;
            float k = longOne ? (2.5 + 4.0 * fx_hash(seed + 6.1)) / len : (1.5 + 2.0 * fx_hash(seed + 6.1)) / len;
            float amp = longOne ? len * (0.08 + 0.12 * fx_hash(seed + 5.3)) : len * (0.15 + 0.25 * fx_hash(seed + 5.3));
            float ph = l.x * k + fx_hash(seed + 7.7) * 6.2832;
            float dist = abs(l.y - amp * sin(ph)) / sqrt(1.0 + pow(amp * k * cos(ph), 2.0));
            float w = longOne ? 0.55 + 0.35 * fx_hash(seed + 8.3) : 0.7 + 0.5 * fx_hash(seed + 8.3);
            float br = 0.5 + 0.45 * fx_hash(seed + 9.1);
            float fade = 1.0 - smoothstep(0.75 * len, len, abs(l.x));
            a = max(a, br * saturate((w + 0.75 - dist) / 1.5) * fade);
        }
        return a;
    }

    /// Per-frame overlay state (which video, icon offsets and motion-blur vectors).
    struct RRFrame {
        int j; int ns;
        float vw, sci, kd, icx, flip;   // flip = -1: fast-forward (overlay mirrored left-right)
        float2 ol, orr, vl, vr;
    };
    inline float rr_dotProfile(float r) {
        float x = clamp((r - 0.125) / 0.25, 0.0, 12.999);
        int i = int(x);
        return mix(RR_DOT[i], RR_DOT[i + 1], x - float(i));
    }
    /// One texel of the overlay's fine pattern (halftone dots + scratch line) at video position o (texel centre):
    /// (alpha, premultiplied white).
    inline float2 rr_overlayTexel(float2 o, thread const RRFrame& F) {
        int j = F.j;
        if (F.flip < 0.0) o.x = F.vw - 1.0 - o.x;
        // halftone dots (alpha only, black)
        float P = RR_P * F.kd;
        float u = (o.x + o.y) / P + RR_DP1[j], v = (o.x - o.y) / P + RR_DP2[j];
        float du = u - round(u), dv = v - round(v);
        float rd = P * length(float2(du + dv, du - dv)) * 0.5;
        float ad = rr_dotProfile(rd / F.kd);
        // scratch line drifting left
        float lx = F.vw * 0.5 + (RR_VLX[j] - 455.0) * F.kd, lxa = F.vw * 0.5 + (RR_VLXA[j] - 455.0) * F.kd;
        float cl = RR_VLC[j] * saturate(1.0 - abs(o.x - lx)), al = RR_VLA[j] * saturate(1.0 - abs(o.x - lxa));
        return float2(1.0 - (1.0 - ad) * (1.0 - saturate(al)), saturate(cl));
    }
    /// ◀◀ coverage and drop shadow at video position o, motion-blurred over half a frame: (coverage, shadow alpha).
    inline float2 rr_icon(float2 o, thread const RRFrame& F) {
        float2 p = (o - float2(F.icx, 256.0)) / F.sci;
        p.x *= F.flip;   // ▶▶: the same ◀◀ animation seen in a mirror
        // bounding box of both triangles + shadow over the shutter
        float2 lo = min(F.ol - abs(F.vl) * 0.5, F.orr - abs(F.vr) * 0.5) - float2(170.0, 135.0);
        float2 hi = max(F.ol + abs(F.vl) * 0.5, F.orr + abs(F.vr) * 0.5) + float2(190.0, 175.0);
        if (any(p < lo) || any(p > hi)) return float2(0.0);
        float cov = 0.0, sh = 0.0;
        float2 sg = RR_SHADOW_SIGMA.xy;
        for (int k = 0; k < F.ns; k++) {
            float sk = F.ns == 1 ? 0.0 : (float(k) + 0.5) / float(F.ns) - 0.5;
            float2 a = F.ol + sk * F.vl, b = F.orr + sk * F.vr;
            // edge width 1.65 px = the video's 1.5 px anti-aliasing after the bilinear upscale
            cov += saturate(0.5 - rr_sdIcon(p, a, b) / 1.65);
            // drop shadow: anisotropic gaussian of a shrunk silhouette (erfc of the scaled-space distance)
            float sd = rr_sdIconScaled((p - RR_SHADOW.xy) / sg, a, b, sg, RR_SHADOW_SIGMA.z);
            sh += min(RR_SHADOW.z * rr_erfc01(sd * 0.707107), 1.0);
        }
        return float2(cov / float(F.ns) * 0.9953, sh / float(F.ns));
    }

    /// Overlay (alpha, premultiplied white) at canvas uv for overlay frame position jt (continuous frame index):
    /// four texels of the 512-px-high video, bilinearly upscaled like CapCut's texture sampling.
    inline float2 rr_overlay(float2 uv, float2 size, float jt, float flip) {
        float ra = size.x / size.y;
        float d16 = abs(ra - 1.777778), d11 = abs(ra - 1.0), d916 = abs(ra - 0.5625);
        RRFrame F;
        F.flip = flip;
        // CapCut picks the overlay video whose aspect is nearest: 910×512 (16:9), 512×512, 288×512 (9:16)
        // (icon centre x and scale measured in each video)
        F.vw = 910.0; F.sci = 1.0; F.kd = 1.0; F.icx = 455.0;
        if (d11 < d16 && d11 <= d916) { F.vw = 512.0; F.sci = 0.8995; F.icx = 243.25; }
        else if (d916 < d16 && d916 < d11) { F.vw = 288.0; F.sci = 0.5343; F.kd = 0.5625; F.icx = 136.85; }
        float va = F.vw / 512.0;
        float2 t = uv;   // Fill crop
        if (va > ra) t.x = (uv.x - 0.5) * (ra / va) + 0.5; else t.y = (uv.y - 0.5) * (va / ra) + 0.5;
        float2 o = float2(t.x * F.vw - 0.5, t.y * 512.0);   // (measured: the video sits half a texel left)
        int j = clamp(int(floor(jt + 1e-3)), 0, 59);
        float fj = clamp(jt - float(j), 0.0, 1.0);
        F.j = j;
        F.ol = mix(rr_iconOffset(j, false), rr_iconOffset(j + 1, false), fj);
        F.orr = mix(rr_iconOffset(j, true), rr_iconOffset(j + 1, true), fj);
        F.vl = 0.5 * (rr_iconOffset(j + 1, false) - rr_iconOffset(j - 1, false)) * RR_SHUTTER;
        F.vr = 0.5 * (rr_iconOffset(j + 1, true) - rr_iconOffset(j - 1, true)) * RR_SHUTTER;
        F.ns = clamp(int(ceil(max(length(F.vl), length(F.vr)) / 2.5)), 1, 12);
        // fine pattern: four texels, bilinear like CapCut's upscale of the 512-px video
        float2 g = o - 0.5;
        float2 i0 = floor(g), f = g - i0;
        float2 c00 = rr_overlayTexel(i0 + 0.5, F), c10 = rr_overlayTexel(i0 + float2(1.5, 0.5), F);
        float2 c01 = rr_overlayTexel(i0 + float2(0.5, 1.5), F), c11 = rr_overlayTexel(i0 + 1.5, F);
        float2 fine = mix(mix(c00, c10, f.x), mix(c01, c11, f.x), f.y);
        float2 ic = rr_icon(o, F);
        float ai = ic.x + ic.y * (1.0 - ic.x);
        // dust: evaluated once (its edges are as soft as the upscale), white
        float dd = rr_dust(o / F.kd, j, float2(F.vw, 512.0) / F.kd);
        float A = 1.0 - (1.0 - fine.x) * (1.0 - ai) * (1.0 - dd);
        float C = 1.0 - (1.0 - fine.y) * (1.0 - ic.x) * (1.0 - dd);
        return float2(A, min(C, A));
    }
    """ }
}
