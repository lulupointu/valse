import Foundation
import ValseCore

/// Adjust ▸ Basic ▸ ☐ Auto adjust (CL-007): a correction computed once from the frame under the playhead
/// (histogram statistics: median exposure, percentile contrast stretch around the corrected median, grey-world white
/// balance as linear gains (`temperature` = log2 red/blue trade, `tint` = log2 green), saturation and
/// highlight/shadow recovery), stored in the instance's params and mixed by Strength. No ML needed; the AI team can
/// replace the analysis through `AutoAdjustAnalyzer.provider` (engine).
public enum AutoColor {
    public static let descriptor = EffectDescriptor(
        id: "valse.adjust.auto", category: .adjustment, nameKey: "adjust.auto", groupKey: "adjust.group.auto",
        params: [
            .scalar("strength", "fx.param.strength", 0, 1, 1, display: 100),
            .scalar("exposure", "adjust.exposure", -2, 2, 0, display: 50),
            .scalar("contrast", "adjust.contrast", -1, 1, 0, display: 50),
            .scalar("temperature", "adjust.temperature", -1, 1, 0, display: 50),
            .scalar("tint", "adjust.tint", -1, 1, 0, display: 50),
            .scalar("saturation", "adjust.saturation", -1, 1, 0, display: 50),
            .scalar("highlights", "adjust.highlights", -1, 1, 0, display: 50),
            .scalar("shadows", "adjust.shadows", -1, 1, 0, display: 50),
            .scalar("pivot", "adjust.contrast", 0, 1, 0.5, display: 100),
        ],
        symbol: "wand.and.stars",
        shader: """
        float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
            float4 c = src.sample(s, uv);
            float3 lin = fx_to_linear(saturate(c.rgb)) * exp2(p[1]);
            // white balance as linear gains: temperature trades red against blue, tint scales green (log2 units)
            float3 g = float3(exp2(p[3]), exp2(-p[4]), exp2(-p[3]));
            g /= dot(g, float3(0.2126, 0.7152, 0.0722));
            float3 o = fx_to_display(lin * g);
            o = (o - p[8]) * (1.0 + p[2]) + p[8];
            float l = fx_luma(saturate(o));
            o += p[6] * 0.22 * smoothstep(0.45, 1.0, l) + p[7] * 0.22 * (1.0 - smoothstep(0.0, 0.55, l));
            o = mix(float3(fx_luma(o)), o, 1.0 + p[5]);
            return float4(mix(c.rgb, saturate(o), saturate(p[0])), c.a);
        }
        """)

    /// Frame statistics → correction params (keys of `descriptor`, strength excluded).
    /// `rgba` is 8-bit RGBA (display-encoded), any size; it is subsampled to ≤ 64k pixels.
    public static func analyze(rgba: [UInt8], width: Int, height: Int) -> [String: Double] {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return [:] }
        let step = max(1, Int((Double(width * height) / 65_536).squareRoot()))
        var hist = [Int](repeating: 0, count: 256)
        var sum = SIMD3<Double>(0, 0, 0), chromaSum = 0.0, n = 0.0
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let i = (y * width + x) * 4
                let r = Double(rgba[i]) / 255, g = Double(rgba[i + 1]) / 255, b = Double(rgba[i + 2]) / 255
                let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                hist[min(255, Int(l * 255 + 0.5))] += 1
                sum += SIMD3(pow(r, 2.4), pow(g, 2.4), pow(b, 2.4))
                chromaSum += max(r, g, b) - min(r, g, b)
                n += 1
            }
        }
        guard n > 0 else { return [:] }
        func percentile(_ q: Double) -> Double {
            let target = q * n
            var acc = 0.0
            for (k, c) in hist.enumerated() { acc += Double(c); if acc >= target { return Double(k) / 255 } }
            return 1
        }
        let p1 = percentile(0.01), p50 = percentile(0.5), p99 = percentile(0.99)
        let mean = sum / n
        var out: [String: Double] = [:]
        // exposure: bring the median toward mid grey (display 0.46), at most ±1.2 stops
        let medLin = pow(max(p50, 0.02), 2.4), target = pow(0.46, 2.4)
        let ev = min(max(log2(target / medLin) * 0.85, -2), 2)
        out["exposure"] = ev
        out["pivot"] = min(max(pow(medLin * pow(2, ev), 1 / 2.4), 0.15), 0.85)
        // contrast: stretch the 1–99 % range toward 0.92
        let range = max(p99 - p1, 0.05)
        out["contrast"] = min(max(0.92 / range - 1, -0.25), 0.4)
        // grey-world white balance (linear means), 75 % of the way, as log2 gains
        if mean.x > 1e-5, mean.y > 1e-5, mean.z > 1e-5 {
            out["temperature"] = min(max(0.5 * log2(mean.z / mean.x) * 0.75, -1), 1)
            out["tint"] = min(max(log2(mean.y / (mean.x * mean.z).squareRoot()) * 0.75, -1), 1)
        }
        // saturation: lift dull frames, calm over-saturated ones
        let chroma = chromaSum / n
        out["saturation"] = chroma < 0.12 ? 0.18 : (chroma > 0.4 ? -0.12 : 0.06)
        // recover clipped highlights / crushed shadows
        out["highlights"] = p99 > 0.97 ? -0.35 : 0
        out["shadows"] = p1 < 0.03 && p50 < 0.4 ? 0.3 : 0
        return out
    }
}
