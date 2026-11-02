import QtQuick 2.9
import QtQuick.Controls 2.2

/**
 * 1.0: Only setting the right color in the darkmode
 * 1.1: colours of MuseScore's theme when available (MuseScore 4), of the system otherwise
 */
Label {
    id: control
    readonly property bool themed: (typeof ui !== "undefined") && !!ui && !!ui.theme
    color: control.themed ? ui.theme.fontPrimaryColor : sysActivePalette.text

    SystemPalette {
        id: sysActivePalette;
        colorGroup: SystemPalette.Active
    }

}
