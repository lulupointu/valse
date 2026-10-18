#pragma once
// GPU-drawn, virtualized timeline canvas (Qt Quick scene graph, no QML item per clip).
// Only clips intersecting the viewport produce geometry: one batched vertex-colored node for all
// clip bodies, one textured node for all filmstrip thumbnails (single atlas texture -> 1 draw call),
// and pooled QSGTextNodes for labels.
#include <QQuickItem>
#include <QtQml/qqmlregistration.h>
#include <QColor>
#include <QTextLayout>
#include <vector>
#include <memory>

class QSGTexture;

class TimelineCanvas : public QQuickItem {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(double pxPerSecond READ pxPerSecond WRITE setPxPerSecond NOTIFY viewChanged)
    Q_PROPERTY(double scrollX READ scrollX WRITE setScrollX NOTIFY viewChanged)
    Q_PROPERTY(int clipCount READ clipCount WRITE setClipCount NOTIFY modelChanged)
    Q_PROPERTY(int trackCount READ trackCount WRITE setTrackCount NOTIFY modelChanged)
    Q_PROPERTY(double contentSeconds READ contentSeconds NOTIFY modelChanged)
    Q_PROPERTY(double playhead READ playhead WRITE setPlayhead NOTIFY viewChanged)
    Q_PROPERTY(int visibleClips READ visibleClips NOTIFY statsChanged)
public:
    explicit TimelineCanvas(QQuickItem *parent = nullptr);
    ~TimelineCanvas() override;

    double pxPerSecond() const { return m_pps; }
    void setPxPerSecond(double v) { if (v != m_pps) { m_pps = v; update(); emit viewChanged(); } }
    double scrollX() const { return m_scroll; }
    void setScrollX(double v) { if (v != m_scroll) { m_scroll = v; update(); emit viewChanged(); } }
    double playhead() const { return m_playhead; }
    void setPlayhead(double v) { if (v != m_playhead) { m_playhead = v; update(); emit viewChanged(); } }
    int clipCount() const { return int(m_clips.size()); }
    void setClipCount(int n);
    int trackCount() const { return m_tracks; }
    void setTrackCount(int n) { m_tracks = n; setClipCount(clipCount()); }
    double contentSeconds() const { return m_contentSeconds; }
    int visibleClips() const { return m_visible; }

    // average CPU time spent in updatePaintNode (ms), for diagnostics
    static double s_paintMsSum; static long s_paintCount;

signals:
    void viewChanged();
    void modelChanged();
    void statsChanged();

protected:
    QSGNode *updatePaintNode(QSGNode *old, UpdatePaintNodeData *) override;

private:
    struct Clip { int track; double start, dur; QColor color; QString label; std::unique_ptr<QTextLayout> layout; double labelW = 0; };
    std::vector<Clip> m_clips;
    std::vector<std::vector<int>> m_byTrack; // clip indices sorted by start, per track
    int m_tracks = 6;
    double m_pps = 40, m_scroll = 0, m_playhead = 0, m_contentSeconds = 0;
    int m_visible = 0;
};
