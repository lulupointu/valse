"""Generates Valse's bundled Lottie stickers (Bodymovin JSON, 512x512, 30 fps). Re-run to regenerate."""
import json, math, os, sys

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)

def static(v): return {"a": 0, "k": v}
def anim(keys, ease=(0.42, 0, 0.58, 1)):
    """keys: [(frame, value)] -> animated property with bezier ease between keys."""
    ks = []
    for i, (t, v) in enumerate(keys):
        k = {"t": t, "s": v if isinstance(v, list) else [v]}
        if i < len(keys) - 1:
            k["o"] = {"x": [ease[0]], "y": [ease[1]]}
            k["i"] = {"x": [ease[2]], "y": [ease[3]]}
        ks.append(k)
    return {"a": 1, "k": ks}

def tr(p=(0, 0), a=(0, 0), s=(100, 100), r=0, o=100):
    def wrap(x):
        return x if isinstance(x, dict) else static(list(x) if isinstance(x, (list, tuple)) else x)
    return {"ty": "tr", "p": wrap(p), "a": wrap(a), "s": wrap(s), "r": wrap(r), "o": wrap(o)}

def layer_ks(p=(256, 256), a=(0, 0), s=(100, 100), r=0, o=100):
    t = tr(p, a, s, r, o); t.pop("ty"); return t

def fill(c, o=100): return {"ty": "fl", "c": static(list(c) + [1]), "o": static(o), "r": 1}
def stroke(c, w, o=100, lc=2, lj=2): return {"ty": "st", "c": static(list(c) + [1]), "o": static(o), "w": static(w), "lc": lc, "lj": lj}
def ellipse(size, p=(0, 0)): return {"ty": "el", "p": static(list(p)), "s": static(list(size)) if not isinstance(size, dict) else size}
def rect(size, p=(0, 0), r=0): return {"ty": "rc", "p": static(list(p)), "s": static(list(size)), "r": static(r)}
def star(n, outer, inner, p=(0, 0), r=0, polygon=False):
    return {"ty": "sr", "sy": 2 if polygon else 1, "p": static(list(p)), "pt": static(n), "or": static(outer), "ir": static(inner),
            "r": static(r) if not isinstance(r, dict) else r, "os": static(0), "is": static(0)}
def path(v, i=None, o=None, closed=True):
    z = [[0, 0]] * len(v)
    return {"ty": "sh", "ks": static({"c": closed, "v": v, "i": i or z, "o": o or z})}
def group(items, t): return {"ty": "gr", "it": items + [t]}
def shape_layer(name, shapes, ks, ind=1, ip=0, op=60): return {"ddd": 0, "ind": ind, "ty": 4, "nm": name, "ks": ks, "shapes": shapes, "ip": ip, "op": op, "st": 0, "sr": 1}
def comp(name, layers, op=60): return {"v": "5.7.0", "nm": name, "fr": 30, "ip": 0, "op": op, "w": 512, "h": 512, "ddd": 0, "assets": [], "layers": layers}

def save(name, c):
    with open(os.path.join(OUT, f"lottie-{name}.json"), "w") as f: json.dump(c, f, separators=(",", ":"))

# 1. heartbeat — bezier heart, double beat
heart_v = [[0, 60], [-100, -20], [-50, -95], [0, -50], [50, -95], [100, -20]]
heart_i = [[40, -30], [-10, 45], [-40, 0], [-15, -25], [15, -25], [40, 0]]
heart_o = [[-40, -30], [-10, -45], [15, -25], [15, -25], [40, 0], [10, 45]]
# make tangents consistent: (in, out) per vertex
heart_i = [[45, -35], [0, 50], [-35, 0], [-10, -30], [-25, 0], [0, -50]]
heart_o = [[-45, -35], [0, -50], [25, 0], [10, -30], [35, 0], [0, 50]]
beat = anim([(0, [100, 100]), (8, [118, 118]), (16, [100, 100]), (24, [112, 112]), (32, [100, 100]), (60, [100, 100])])
save("heartbeat", comp("Heartbeat", [
    shape_layer("heart", [group([path(heart_v, heart_i, heart_o), fill((0.93, 0.18, 0.32))], tr(s=beat))], layer_ks(s=(170, 170))),
    shape_layer("glow", [group([ellipse((260, 260)), fill((1, 0.55, 0.65), o=35)],
                               tr(s=anim([(0, [70, 70]), (12, [125, 125]), (32, [70, 70])]), o=anim([(0, 0), (8, 60), (30, 0)])))],
                layer_ks(p=(256, 250)), ind=2),
]))

# 2. spinning star
save("spinStar", comp("Spin star", [
    shape_layer("star", [group([star(5, 190, 82), fill((1, 0.8, 0.12)), stroke((1, 0.55, 0.05), 10)],
                               tr(r=anim([(0, 0), (60, 360)], ease=(0, 0, 1, 1)),
                                  s=anim([(0, [100, 100]), (15, [110, 110]), (30, [100, 100]), (45, [110, 110]), (60, [100, 100])])))],
                layer_ks()),
]))

# 3. checkmark — circle pops, then the tick draws (trim path)
save("checkmark", comp("Check", [
    shape_layer("tick", [group([path([[-85, 0], [-25, 60], [95, -65]], closed=False), stroke((1, 1, 1), 34, lc=2, lj=2),
                                {"ty": "tm", "s": static(0), "e": anim([(10, 0), (28, 100)]), "o": static(0), "m": 1}], tr())],
                layer_ks(), ind=1),
    shape_layer("disc", [group([ellipse((380, 380)), fill((0.18, 0.75, 0.42))],
                               tr(s={"a": 1, "k": [{"t": 0, "s": [0, 0], "o": {"x": [0.17], "y": [0.89]}, "i": {"x": [0.32], "y": [1.27]}},
                                                   {"t": 12, "s": [100, 100]}]}))],
                layer_ks(), ind=2),
], op=60))

# 4. loading ring
save("loadingRing", comp("Loading", [
    shape_layer("ring", [group([ellipse((300, 300)), stroke((0.34, 0.75, 0.80), 30, lc=2),
                                {"ty": "tm", "s": anim([(0, 0), (20, 0), (45, 95)]), "e": anim([(0, 5), (30, 100), (45, 100)]),
                                 "o": static(0), "m": 1}],
                               tr(r=anim([(0, 0), (45, 360)], ease=(0, 0, 1, 1))))],
                layer_ks(), op=45),
    shape_layer("track", [group([ellipse((300, 300)), stroke((1, 1, 1), 30, o=18)], tr())], layer_ks(), ind=2, op=45),
], op=45))

# 5. bouncing ball with squash and shadow
save("bounceBall", comp("Bounce", [
    shape_layer("ball", [group([ellipse((150, 150)), fill((1, 0.48, 0.18))],
                               tr(p=anim([(0, [0, -150]), (15, [0, 100]), (30, [0, -150])], ease=(0.33, 0, 0.67, 1)),
                                  s=anim([(0, [100, 100]), (13, [100, 100]), (15, [125, 78]), (18, [96, 106]), (30, [100, 100])])))],
                layer_ks(p=(256, 230)), ind=1, op=30),
    shape_layer("shadow", [group([ellipse((170, 34)), fill((0, 0, 0), o=35)],
                                 tr(s=anim([(0, [55, 55]), (15, [100, 100]), (30, [55, 55])], ease=(0.33, 0, 0.67, 1))))],
                layer_ks(p=(256, 420)), ind=2, op=30),
], op=30))

# 6. confetti burst
colors = [(0.98, 0.36, 0.42), (1, 0.78, 0.25), (0.34, 0.75, 0.80), (0.45, 0.42, 0.95), (0.4, 0.85, 0.45)]
pieces = []
for k in range(14):
    ang = k / 14 * 2 * math.pi
    d = 170 + 40 * (k % 3)
    end = [round(math.cos(ang) * d, 1), round(math.sin(ang) * d, 1)]
    pieces.append(group([rect((26, 14), r=3), fill(colors[k % len(colors)])],
                        tr(p=anim([(0, [0, 0]), (30, end), (60, [end[0], end[1] + 60])], ease=(0.1, 0.8, 0.3, 1)),
                           r=anim([(0, 0), (60, 360 * (1 if k % 2 else -1))], ease=(0, 0, 1, 1)),
                           o=anim([(0, 100), (40, 100), (60, 0)]))))
save("confetti", comp("Confetti", [shape_layer("confetti", pieces, layer_ks())]))

# 7. nudging arrow
save("arrowNudge", comp("Arrow", [
    shape_layer("arrow", [group([path([[-120, -30], [20, -30], [20, -90], [130, 0], [20, 90], [20, 30], [-120, 30]]), fill((1, 1, 1)),
                                 stroke((0.13, 0.13, 0.13), 12, lj=1)],
                                tr(p=anim([(0, [-25, 0]), (15, [25, 0]), (30, [-25, 0])])))],
                layer_ks(), op=30),
], op=30))

# 8. sparkle with radial gradient
save("sparkle", comp("Sparkle", [
    shape_layer("sparkle", [group([star(4, 200, 46),
                                   {"ty": "gf", "t": 2, "s": static([0, 0]), "e": static([200, 0]), "o": static(100),
                                    "g": {"p": 2, "k": static([0, 1, 1, 0.85, 1, 0.98, 0.62, 0.15])}}],
                                  tr(s=anim([(0, [40, 40]), (15, [100, 100]), (30, [40, 40])]),
                                     r=anim([(0, 0), (30, 45)], ease=(0, 0, 1, 1))))],
                layer_ks(), op=30),
], op=30))
print("ok")
