import QtQuick
import Montage

Item {
    id: root
    readonly property var trackNames: [qsTr("Text"), qsTr("Effects"), qsTr("Overlay"), qsTr("Main track"), qsTr("Filters"), qsTr("Audio")]

    Rectangle {
        id: toolbar
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: 34; color: "#1c1d22"
        Row {
            anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
            spacing: 18
            Repeater {
                model: [qsTr("Split"), qsTr("Delete"), qsTr("Freeze"), qsTr("Reverse"), qsTr("Magnet"), qsTr("Snapping")]
                Text { text: modelData; color: "#c8c8c8"; font.pixelSize: 12 }
            }
        }
        Text {
            anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
            color: "#00c1cd"; font.pixelSize: 12
            text: qsTr("%n clip(s)", "", canvas.clipCount) + " · " + qsTr("Zoom: %1 px/s").arg(Math.round(canvas.pxPerSecond))
        }
    }

    Column {
        id: headers
        anchors { left: parent.left; top: toolbar.bottom; bottom: parent.bottom; topMargin: 24 }
        width: 110
        Repeater {
            model: root.trackNames
            Rectangle {
                width: headers.width; height: (headers.height) / root.trackNames.length
                color: index === 3 ? "#2a2c33" : "#202127"
                border.color: "#15161a"
                Text { anchors.centerIn: parent; text: modelData; color: "#d0d0d0"; font.pixelSize: 12 }
            }
        }
    }

    TimelineCanvas {
        id: canvas
        objectName: "timeline"
        anchors { left: headers.right; right: parent.right; top: toolbar.bottom; bottom: parent.bottom }
        clip: true
        trackCount: 6
        clipCount: 500
        pxPerSecond: 20
        playhead: 30

        // programmatic scroll + zoom animation (bench P4), started from C++
        ParallelAnimation {
            id: benchAnim
            objectName: "benchAnim"
            NumberAnimation { target: canvas; property: "scrollX"; from: 0; to: 9000; duration: 5000; easing.type: Easing.InOutSine }
            SequentialAnimation {
                NumberAnimation { target: canvas; property: "pxPerSecond"; from: 20; to: 140; duration: 2500; easing.type: Easing.InOutQuad }
                NumberAnimation { target: canvas; property: "pxPerSecond"; from: 140; to: 30; duration: 2500; easing.type: Easing.InOutQuad }
            }
            NumberAnimation { target: canvas; property: "playhead"; from: 30; to: 200; duration: 5000 }
        }
        WheelHandler {
            onWheel: (ev) => {
                if (ev.modifiers & Qt.ControlModifier) canvas.pxPerSecond = Math.max(2, Math.min(800, canvas.pxPerSecond * (ev.angleDelta.y > 0 ? 1.1 : 0.9)))
                else canvas.scrollX = Math.max(0, canvas.scrollX - ev.angleDelta.x - ev.angleDelta.y)
            }
        }
    }
}
