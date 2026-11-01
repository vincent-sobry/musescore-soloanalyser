import QtQuick 2.9
import QtQuick.Controls 2.2

/**
 * 1.0: GroupBox with the colours of MuseScore's theme when available (MuseScore 4), of the system otherwise
 */
GroupBox {
    id: control
    readonly property bool themed: (typeof ui !== "undefined") && !!ui && !!ui.theme

    label: Text {
        x: control.leftPadding
        width: control.availableWidth
        text: control.title
        font: control.font
        color: control.themed ? ui.theme.fontPrimaryColor : sysActivePalette.windowText
        elide: Text.ElideRight
    }

    background: Rectangle {
        y: control.topPadding - control.bottomPadding
        width: parent.width
        height: parent.height - control.topPadding + control.bottomPadding
        color: "transparent"
        radius: 3
        border.color: control.themed ? ui.theme.strokeColor : sysActivePalette.mid
    }

    SystemPalette {
        id: sysActivePalette;
        colorGroup: SystemPalette.Active
    }
}
