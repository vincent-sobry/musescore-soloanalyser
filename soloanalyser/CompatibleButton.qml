import QtQuick 2.9
import QtQuick.Controls 2.2

/**********************
/* 1.1: colours of MuseScore's theme when available (MuseScore 4), of the system otherwise (text and background)
/**********************************************/

Button {
    id: control
    readonly property bool themed: (typeof ui !== "undefined") && !!ui && !!ui.theme
    contentItem: Text {
        text: control.text
        font: control.font
        opacity: enabled ? 1.0 : 0.6
        color: control.themed ? ui.theme.fontPrimaryColor : sysActivePalette.buttonText
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }

    background: Rectangle {
        implicitWidth: 100
        implicitHeight: 32
        radius: 3
        color: control.themed ? ui.theme.buttonColor : sysActivePalette.button
        opacity: !control.themed ? (control.down ? 0.7 : 1.0)
            : control.down ? ui.theme.buttonOpacityHit : control.hovered ? ui.theme.buttonOpacityHover : ui.theme.buttonOpacityNormal
        border.width: control.visualFocus ? 2 : 0
        border.color: control.themed ? ui.theme.focusColor : sysActivePalette.highlight
    }

    
    SystemPalette {
        id: sysActivePalette;
        colorGroup: SystemPalette.Active
    }

}
