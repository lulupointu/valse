import QtQuick
import QtQuick.Window
import Montage

Window {
    id: win
    required property string mode
    width: 1280
    height: mode === "timeline" ? 520 : 780
    visible: true
    color: "#141518"
    title: mode === "timeline" ? qsTr("Montage — Timeline") : qsTr("Montage — Player")

    Loader {
        anchors.fill: parent
        sourceComponent: win.mode === "timeline" ? timelinePage : playerPage
    }

    Component {
        id: playerPage
        Item {
            Rectangle {
                id: bar
                anchors { left: parent.left; right: parent.right; top: parent.top }
                height: 36
                color: "#1c1d22"
                Text {
                    anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                    color: "#e6e6e6"; font.pixelSize: 13
                    text: qsTr("Player")
                }
                Text {
                    anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                    color: "#00c1cd"; font.pixelSize: 12
                    //: %n = number of video layers in the preview composition
                    text: qsTr("%n layer(s) · 1080p preview", "", 4)
                }
            }
            PreviewItem {
                objectName: "preview"
                anchors { top: bar.bottom; horizontalCenter: parent.horizontalCenter; topMargin: 8 }
                width: Math.min(parent.width - 16, (parent.height - bar.height - 16) * 16 / 9)
                height: width * 9 / 16
                fixedColorBufferWidth: 1920
                fixedColorBufferHeight: 1080
            }
        }
    }

    Component {
        id: timelinePage
        TimelineView {}
    }
}
