#pragma once
#include <QQuickRhiItem>
#include <QtQml/qqmlregistration.h>
#include <atomic>
#include "Compositor.h"

class Engine;

struct PreviewStats {
    std::atomic<int64_t> presented{0};      // distinct composition frames rendered while playing
    std::atomic<int64_t> dropped{0};        // frame indices that were never shown on time
    std::atomic<int64_t> lastIdx{-1};
    std::atomic<uint64_t> renderedGen{0};   // seek generation of the last rendered composition
    std::atomic<bool> renderedAny{false};
    std::atomic<double> renderMsSum{0};
    std::atomic<int64_t> renderCount{0};
    void resetPlayback() { presented = 0; dropped = 0; lastIdx = -1; renderMsSum = 0; renderCount = 0; }
};

class PreviewItem : public QQuickRhiItem {
    Q_OBJECT
    QML_ELEMENT
public:
    explicit PreviewItem(QQuickItem *parent = nullptr);
    static Engine *s_engine;           // set before QML is loaded
    static PreviewStats s_stats;
protected:
    QQuickRhiItemRenderer *createRenderer() override;
};
