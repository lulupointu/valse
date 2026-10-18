// Word error rate after light normalization (case, punctuation, apostrophes, digits kept as-is).
export function normalize(s: string) {
  return s.toLowerCase().replace(/[’']/g, ' ').replace(/[^\p{L}\p{N}\s-]/gu, ' ').replace(/-/g, ' ').split(/\s+/).filter(Boolean);
}
export function wer(ref: string, hyp: string) {
  const r = normalize(ref), h = normalize(hyp);
  const d = Array.from({ length: r.length + 1 }, (_, i) => { const row = new Array(h.length + 1).fill(0); row[0] = i; return row; });
  for (let j = 0; j <= h.length; j++) d[0][j] = j;
  for (let i = 1; i <= r.length; i++) for (let j = 1; j <= h.length; j++)
    d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (r[i - 1] === h[j - 1] ? 0 : 1));
  return d[r.length][h.length] / Math.max(1, r.length);
}
