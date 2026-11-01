import QtQuick 2.9
import QtQuick.Controls 2.2

/**
 * 1.0: initial
 * 1.1: tweak colours in dark mode
 * 1.2: colours of MuseScore's theme when available (MuseScore 4), of the system otherwise
 */
RadioButton {
    id: control
    readonly property bool themed: (typeof ui !== "undefined") && !!ui && !!ui.theme
    
    width: 200
    
    indicator: Rectangle {
        implicitWidth: 20
        implicitHeight: 20
        x: control.leftPadding
        y: parent.height / 2 - height / 2
        radius: 13
        color: control.themed ? ui.theme.textFieldColor : sysActivePalette.base
        border.color: control.themed ? ui.theme.strokeColor : (control.down ? "#555555" : "#929292")

        Rectangle {
            width: 10
            height: 10
            x: 5
            y: 5
            radius: 7
            color: control.themed ? ui.theme.fontPrimaryColor : (control.down ? "#555555" : "black")
            visible: control.checked
        }
    }

   contentItem: Text {
        text: control.text
        font: control.font
        opacity: enabled ? 1.0 : 0.3
        color: control.themed ? ui.theme.fontPrimaryColor : sysActivePalette.text
        verticalAlignment: Text.AlignVCenter
        leftPadding: control.indicator.width + control.spacing
    }

    SystemPalette {
        id: sysActivePalette;
        colorGroup: SystemPalette.Active
    }
}