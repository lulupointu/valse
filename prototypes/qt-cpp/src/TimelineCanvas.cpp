#include "TimelineCanvas.h"
#include "Metrics.h"
#include <QSGGeometryNode>
#include <QSGVertexColorMaterial>
#include <QSGOpaqueTextureMaterial>
#include <QSGTextNode>
#include <QQuickWindow>
#include <QPainter>
#include <QRandomGenerator>
#include <QFont>
#include <unordered_map>
#include <algorithm>
#include <cmath>

double TimelineCanvas::s_paintMsSum = 0;
long TimelineCanvas::s_paintCount = 0;

namespace {
constexpr double kRulerH = 24;
constexpr int kAtlasCols = 4, kAtlasRows = 2, kThumbW = 160, kThumbH = 90;

// Scene graph state, owned by the root node (lives on the render thread).
struct RootNode : QSGNode {
    QSGGeometryNode *body = nullptr, *thumbs = nullptr, *overlay = nullptr;
    QSGNode *labels = nullptr;
    QSGTexture *atlas = nullptr;
    std::unordered_map<int, QSGTextNode *> textByClip;
    std::vector<QSGTextNode *> freeText;
    ~RootNode() override { delete atlas; }
};

QSGGeometryNode *makeColorNode()
{
    auto *n = new QSGGeometryNode;
    auto *g = new QSGGeometry(QSGGeometry::defaultAttributes_ColoredPoint2D(), 0);
    g->setDrawingMode(QSGGeometry::DrawTriangles);
    n->setGeometry(g); n->setFlag(QSGNode::OwnsGeometry);
    n->setMaterial(new QSGVertexColorMaterial); n->setFlag(QSGNode::OwnsMaterial);
    return n;
}

struct ColorSink {
    std::vector<QSGGeometry::ColoredPoint2D> v;
    void rect(float x, float y, float w, float h, QColor c)
    {
        const uchar r = uchar(c.red()), g = uchar(c.green()), b = uchar(c.blue()), a = uchar(c.alpha());
        auto P = [&](float px, float py) { QSGGeometry::ColoredPoint2D p; p.set(px, py, r, g, b, a); v.push_back(p); };
        P(x, y); P(x + w, y); P(x, y + h); P(x + w, y); P(x + w, y + h); P(x, y + h);
    }
    void flush(QSGGeometryNode *n)
    {
        QSGGeometry *g = n->geometry();
        g->allocate(int(v.size()));
        if (!v.empty()) std::memcpy(g->vertexDataAsColoredPoint2D(), v.data(), v.size() * sizeof(v[0]));
        n->markDirty(QSGNode::DirtyGeometry);
        v.clear();
    }
};

QImage makeAtlas()
{
    QImage img(kAtlasCols * kThumbW, kAtlasRows * kThumbH, QImage::Format_RGBA8888_Premultiplied);
    QPainter p(&img);
    for (int i = 0; i < kAtlasCols * kAtlasRows; ++i) {
        QRect r((i % kAtlasCols) * kThumbW, (i / kAtlasCols) * kThumbH, kThumbW, kThumbH);
        QLinearGradient grad(r.topLeft(), r.bottomRight());
        grad.setColorAt(0, QColor::fromHsv((i * 45) % 360, 120, 200));
        grad.setColorAt(1, QColor::fromHsv((i * 45 + 60) % 360, 160, 90));
        p.fillRect(r, grad);
        p.setPen(QColor(255, 255, 255, 90));
        p.drawEllipse(r.center(), 18 + i * 2, 14 + i);
        p.fillRect(r.adjusted(0, 0, -kThumbW + 2, 0), QColor(0, 0, 0, 120)); // frame separator
    }
    return img;
}
}

TimelineCanvas::TimelineCanvas(QQuickItem *parent) : QQuickItem(parent)
{
    setFlag(ItemHasContents, true);
    setClipCount(500);
}

TimelineCanvas::~TimelineCanvas() = default;

void TimelineCanvas::setClipCount(int n)
{
    m_clips.clear();
    m_byTrack.assign(m_tracks, {});
    QRandomGenerator rng(42);
    std::vector<double> cursor(m_tracks, 0.0);
    static const QColor trackColors[] = {
        QColor(0xE0, 0x8A, 0x2E), QColor(0x8E, 0x5C, 0xD9), QColor(0x2E, 0x9C, 0xB0),
        QColor(0x33, 0x6E, 0xC9), QColor(0x2F, 0x8F, 0x83), QColor(0x3E, 0xA0, 0x5A)};
    QFont font; font.setPixelSize(11);
    m_contentSeconds = 0;
    for (int i = 0; i < n; ++i) {
        const int t = i % m_tracks;
        Clip c;
        c.track = t;
        c.start = cursor[t] + (rng.bounded(100) < 30 ? rng.bounded(1.0) : 0.0);
        c.dur = 1.5 + rng.bounded(7.0);
        cursor[t] = c.start + c.dur;
        c.color = trackColors[t].lighter(90 + rng.bounded(30));
        c.label = QStringLiteral("Clip %1").arg(i + 1);
        c.layout = std::make_unique<QTextLayout>(c.label, font);
        c.layout->beginLayout();
        QTextLine line = c.layout->createLine();
        line.setLineWidth(1000);
        c.layout->endLayout();
        c.labelW = line.naturalTextWidth();
        m_contentSeconds = std::max(m_contentSeconds, cursor[t]);
        m_byTrack[t].push_back(int(m_clips.size()));
        m_clips.push_back(std::move(c));
    }
    update();
    emit modelChanged();
}

QSGNode *TimelineCanvas::updatePaintNode(QSGNode *old, UpdatePaintNodeData *)
{
    const double t0 = metrics::nowMs();
    auto *root = static_cast<RootNode *>(old);
    if (!root) {
        root = new RootNode;
        root->body = makeColorNode();
        root->thumbs = new QSGGeometryNode;
        auto *g = new QSGGeometry(QSGGeometry::defaultAttributes_TexturedPoint2D(), 0);
        g->setDrawingMode(QSGGeometry::DrawTriangles);
        root->thumbs->setGeometry(g); root->thumbs->setFlag(QSGNode::OwnsGeometry);
        root->atlas = window()->createTextureFromImage(makeAtlas());
        root->atlas->setFiltering(QSGTexture::Linear);
        auto *mat = new QSGOpaqueTextureMaterial; mat->setTexture(root->atlas);
        root->thumbs->setMaterial(mat); root->thumbs->setFlag(QSGNode::OwnsMaterial);
        root->labels = new QSGNode;
        root->overlay = makeColorNode();
        root->appendChildNode(root->body);
        root->appendChildNode(root->thumbs);
        root->appendChildNode(root->labels);
        root->appendChildNode(root->overlay);
    }

    const float W = float(width()), H = float(height());
    const double trackH = (H - kRulerH) / m_tracks;
    const double tStart = m_scroll / m_pps, tEnd = (m_scroll + W) / m_pps;
    ColorSink body, overlay;
    std::vector<QSGGeometry::TexturedPoint2D> tv;

    // lanes + ruler
    body.rect(0, 0, W, float(kRulerH), QColor(0x1E, 0x1F, 0x24));
    for (int t = 0; t < m_tracks; ++t)
        body.rect(0, float(kRulerH + t * trackH), W, float(trackH - 1), t % 2 ? QColor(0x23, 0x24, 0x2A) : QColor(0x26, 0x27, 0x2E));
    double step = 1;
    for (double s : {0.5, 1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0, 120.0}) { step = s; if (s * m_pps >= 70) break; }
    for (double s = std::floor(tStart / step) * step; s <= tEnd; s += step) {
        float x = float(s * m_pps - m_scroll);
        body.rect(x, 12, 1, float(kRulerH - 12), QColor(0x80, 0x84, 0x90));
        for (int k = 1; k < 5; ++k) body.rect(float(x + k * step * m_pps / 5), 18, 1, 6, QColor(0x50, 0x54, 0x60));
    }

    // visible clips only (per-track binary search on sorted, non-overlapping clips)
    std::unordered_map<int, QSGTextNode *> nextText;
    int visible = 0;
    const float atlasW = kAtlasCols * kThumbW, atlasH = kAtlasRows * kThumbH;
    for (int t = 0; t < m_tracks; ++t) {
        const auto &ids = m_byTrack[t];
        auto it = std::lower_bound(ids.begin(), ids.end(), tStart, [&](int id, double v) {
            return m_clips[id].start + m_clips[id].dur < v;
        });
        const float y = float(kRulerH + t * trackH + 2), h = float(trackH - 5);
        for (; it != ids.end(); ++it) {
            const Clip &c = m_clips[*it];
            if (c.start > tEnd) break;
            ++visible;
            const float x = float(c.start * m_pps - m_scroll), w = float(c.dur * m_pps);
            body.rect(x, y, std::max(1.f, w - 1), h, c.color);
            // filmstrip placeholder tiles (only those inside the viewport)
            const float ty = y + 16, th = h - 18;
            if (th > 8 && w > 6) {
                const float tw = th * 16.f / 9.f;
                const float visL = std::max(x, 0.f), visR = std::min(x + w - 2, W);
                int k0 = int(std::max(0.f, std::floor((visL - x) / tw)));
                for (int k = k0;; ++k) {
                    float tx = x + 1 + k * tw;
                    if (tx >= visR) break;
                    float tw2 = std::min(tw, x + w - 2 - tx);
                    if (tw2 <= 0) break;
                    int fi = (*it + k) % (kAtlasCols * kAtlasRows);
                    float u0 = (fi % kAtlasCols) * kThumbW / atlasW, v0 = (fi / kAtlasCols) * kThumbH / atlasH;
                    float u1 = u0 + (kThumbW / atlasW) * (tw2 / tw), v1 = v0 + kThumbH / atlasH;
                    auto P = [&](float px, float py, float u, float v) { QSGGeometry::TexturedPoint2D p; p.set(px, py, u, v); tv.push_back(p); };
                    P(tx, ty, u0, v0); P(tx + tw2, ty, u1, v0); P(tx, ty + th, u0, v1);
                    P(tx + tw2, ty, u1, v0); P(tx + tw2, ty + th, u1, v1); P(tx, ty + th, u0, v1);
                }
            }
            // label (only if it fits)
            if (w > c.labelW + 10) {
                QSGTextNode *tn = nullptr;
                auto found = root->textByClip.find(*it);
                if (found != root->textByClip.end()) { tn = found->second; root->textByClip.erase(found); }
                else {
                    if (!root->freeText.empty()) { tn = root->freeText.back(); root->freeText.pop_back(); }
                    else { tn = window()->createTextNode(); root->labels->appendChildNode(tn); }
                    tn->clear();
                    tn->setColor(Qt::white);
                    tn->addTextLayout(QPointF(0, 0), c.layout.get());
                }
                QMatrix4x4 m; m.translate(std::max(x, 0.f) + 5, y + 1);
                tn->setMatrix(m);
                nextText[*it] = tn;
            }
        }
    }
    for (auto &[id, tn] : root->textByClip) { tn->clear(); root->freeText.push_back(tn); }
    root->textByClip = std::move(nextText);

    // playhead
    const float px = float(m_playhead * m_pps - m_scroll);
    overlay.rect(px - 0.5f, 0, 1.5f, H, QColor(0xFF, 0xFF, 0xFF));
    overlay.rect(px - 5, 0, 10, 10, QColor(0x00, 0xC1, 0xCD));

    body.flush(root->body);
    overlay.flush(root->overlay);
    QSGGeometry *g = root->thumbs->geometry();
    g->allocate(int(tv.size()));
    if (!tv.empty()) std::memcpy(g->vertexDataAsTexturedPoint2D(), tv.data(), tv.size() * sizeof(tv[0]));
    root->thumbs->markDirty(QSGNode::DirtyGeometry);

    if (visible != m_visible) { m_visible = visible; QMetaObject::invokeMethod(this, "statsChanged", Qt::QueuedConnection); }
    s_paintMsSum += metrics::nowMs() - t0; s_paintCount++;
    return root;
}
