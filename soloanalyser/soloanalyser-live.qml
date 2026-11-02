import QtQuick
import QtQuick.Controls
import MuseScore 3.0
import QtQuick.Layouts

import "notehelper.js" as NoteHelper
import "chordanalyser.js" as ChordHelper
import "liveanalyser.js" as Live
import "core.js" as Core

/**********************
/* Parking B - MuseScore - Solo Analyser plugin - Live panel - MuseScore 4.4+ version
/* Keeps a window open next to the score and shows, while composing, the role of the notes
/* of the current bar relative to the chord symbols, and writes the analyse in the score. Paused (⏸),
/* nothing is updated and the analyse stays in the score; it is removed when the window is closed.
/* All the options are the ones of "Interactive" (opened with the ⚙ button).
/* MuseScore 4 does not emit onScoreStateChanged to plugins, so the score is polled with a Timer.
/* MuseScore 4 cannot dock plugins in its side panels: only "dialog" windows are supported.
/* ChangeLog:
/*  - 1.0.0: Initial version
/*  - 1.1.0: Options taken from "Interactive"; analyse removed from the score when closing
/*  - 1.2.0: Choice of the parts to analyse; the bar shown as a table of beats, with the short part names,
/*           the selected note highlighted
/*  - 1.3.0: Follows MuseScore's light/dark theme
/*  - 1.3.0: One play/pause button instead of "Write in score" and "Pause"; MuseScore's icons
/**********************************************/

MuseScore {
    menuPath: "Plugins.Solo Analyser." + pluginName
    description: "Live panel showing the role of the notes of the current bar relative to the chord symbols."
    version: "1.3.0"

    readonly property var pluginName: qsTr("Live")

    title: "Solo Analyser Live"
    thumbnailName: "logoSoloAnalyserLive.png"
    categoryCode: "color-notes"

    pluginType: "dialog"
    width: 460
    height: 360

    id: mainWindow

    property int lastFocusTick: -1
    property var selectedNote: null
    property string lastKey: ""
    property string lastWriteKey: ""
    property bool cleanedUp: false
    property bool live: true // ▶: the panel and the score follow the edits; ⏸: both are frozen
    readonly property var categories: ["root", "bass", "chord", "altered", "scale", "outside"]
    // Parts of the score that can be analysed (no drums), and the keys of the ones the user unchecked.
    // The excluded parts are stored by name, so the choice is kept for the next scores with the same instruments.
    property var parts: []
    property var excludedParts: []

    // Only one Live panel at a time: two panels would both write in the score, and closing one would
    // clear what the other one keeps writing. The open panel stores a heartbeat in its settings
    // (shared by all plugin instances); a new panel finding a recent heartbeat of another one closes.
    readonly property string instanceId: Date.now() + "-" + Math.floor(Math.random() * 1000000)
    readonly property int heartbeatTimeout: 3000

    onRun: {
        var owner = liveSettings.value("owner", "");
        var beat = parseInt(liveSettings.value("heartbeat", 0), 10) || 0;
        if (owner !== "" && owner !== instanceId && (Date.now() - beat) < heartbeatTimeout) {
            cleanedUp = true; // never touch the score from this instance
            output.text = "<i>" + qsTr("Solo Analyser Live is already open.") + "</i>";
            closer.start();
            return;
        }
        heartbeat();
        heartbeatTimer.start();
        try {
            excludedParts = JSON.parse(liveSettings.value("excludedParts", "[]")) || [];
        } catch (err) {
            excludedParts = [];
        }
        refresh(true);
    }

    function heartbeat() {
        liveSettings.setValue("owner", instanceId);
        liveSettings.setValue("heartbeat", Date.now());
    }

    Timer {
        id: heartbeatTimer
        interval: 1000
        repeat: true
        onTriggered: heartbeat()
    }

    Timer {
        id: closer
        interval: 1500
        onTriggered: {
            if (mainWindow.Window.window) mainWindow.Window.window.close();
            else quit();
        }
    }

    // Options of "Interactive". They are read with value() at each refresh, and not as properties:
    // properties are only loaded when the plugin starts, and declaring them without a value
    // would store invalid values for "Interactive".
    Settings {
        id: settings
        category: "SoloAnalyser"
    }

    Settings {
        id: liveSettings
        category: "SoloAnalyserLive"
    }

    Timer {
        id: poller
        interval: 400
        repeat: true
        running: live && !cleanedUp
        onTriggered: refresh(false)
    }

    // Removing the analyse from the score when the window is closed
    Connections {
        target: mainWindow.Window.window
        ignoreUnknownSignals: true
        function onClosing(close) {
            cleanup();
        }
    }

    Component.onDestruction: cleanup()

    function cleanup() {
        if (cleanedUp) return;
        cleanedUp = true;
        heartbeatTimer.stop();
        if (liveSettings.value("owner", "") === instanceId) liveSettings.setValue("heartbeat", 0);
        try {
            clearScore();
        } catch (err) {
            console.log("Solo Analyser Live: " + err);
        }
    }

    // Only the analysed parts are cleared: the excluded ones may hold an analyse the user wants to keep
    function clearScore() {
        if (!curScore) return;
        Live.clearScore(categories.map(categoryColor), includedParts());
        lastWriteKey = "";
    }

    function includedParts() {
        return Live.getParts().filter(function (p) {
            return excludedParts.indexOf(p.key) < 0;
        }).map(function (p) {
            return p.key;
        });
    }

    function setPartIncluded(key, included) {
        var ex = excludedParts.filter(function (k) {
            return k !== key;
        });
        if (!included) ex.push(key);
        excludedParts = ex;
        liveSettings.setValue("excludedParts", JSON.stringify(ex));
        // Removing what was written in a part that is no longer analysed
        if (!included && curScore) {
            try {
                Live.clearScore(categories.map(categoryColor), [key]);
            } catch (err) {
                console.log("Solo Analyser Live: " + err);
            }
        }
        refresh(true);
    }

    function setting(key, def) {
        var v = settings.value(key, def);
        return (v === undefined || v === null || v === "") ? def : v;
    }

    function opt(key, def) {
        return Core.cbool(setting(key, def));
    }

    function options() {
        return {
            "wholeScore": false,
            "useAboveSymbols": opt("useAboveSymbols", Core.defUseAboveSymbols),
            "useBelowSymbols": opt("useBelowSymbols", Core.defUseBelowSymbols),
            "lookAhead": opt("lookAhead", Core.defLookAhead),
            "ignoreBrackettedChords": opt("ignoreBrackettedChords", Core.defIgnoreBrackettedChords),
            "excludedParts": excludedParts
        };
    }

    function modes() {
        var m = {
            "colorNotes": "" + setting("colorNotes", Core.defColorNotes),
            "nameNotes": "" + setting("nameNotes", Core.defNameNotes),
            "textType": "" + setting("textType", Core.defTextType)
        };
        if (m.colorNotes === "none" && m.nameNotes === "none") { // as core.js
            m.colorNotes = Core.defColorNotes;
            m.nameNotes = Core.defNameNotes;
        }
        return m;
    }

    function refresh(force) {
        if (cleanedUp) return;
        if (!curScore) {
            output.text = "<i>" + qsTr("No score open") + "</i>";
            lastKey = "";
            return;
        }
        try {
            var ps = Live.getParts().filter(function (p) {
                return !p.drum;
            });
            if (JSON.stringify(ps) !== JSON.stringify(parts)) parts = ps;

            var sel = Live.getSelection();
            if (sel.tick >= 0) {
                lastFocusTick = sel.tick; // keep the last position when the selection is cleared
                selectedNote = sel.note;
            }
            // The selected note is highlighted in the table, so selecting another note refreshes the panel
            var selKey = selectedNote ? lastFocusTick + "/" + selectedNote.track + ":" + selectedNote.pitch : "";

            var opts = options();
            var md = modes();
            // Changing an option in "Interactive" must refresh the panel and rewrite the score
            var settingsKey = JSON.stringify([opts, md, categories.map(categoryColor)]);

            var res = Live.analyse(lastFocusTick, opts);
            if (res === null) {
                output.text = "<i>" + qsTr("Empty score") + "</i>";
                lastKey = "";
                return;
            }
            // Only react to changes of notes, chord symbols, bar or options: the labels and colours written
            // by the plugin are not part of the keys, so undoing the plugin's write is not re-applied.
            if (force || res.key + settingsKey + selKey !== lastKey) {
                lastKey = res.key + settingsKey + selKey;
                output.text = render(res);
                legend.text = categories.map(function (c) {
                    return "<span style='color:" + categoryColor(c) + "'>■ " + c + "</span>";
                }).join(" ");
                status.text = qsTr("Updated") + " " + Qt.formatTime(new Date(), "hh:mm:ss");
            }
            if (live) {
                // The whole score is written, not just the displayed bar, so that moving the selection
                // does not create undo steps: only edits of notes, chord symbols or options change this key.
                opts.wholeScore = true;
                var all = Live.analyse(0, opts);
                if (all === null || (!force && all.key + settingsKey === lastWriteKey)) return;
                lastWriteKey = all.key + settingsKey;
                var n = Live.writeToScore(all, md, categoryColor);
                if (n > 0) status.text = qsTr("Updated") + " " + Qt.formatTime(new Date(), "hh:mm:ss") + " – " + n + " " + qsTr("note(s) updated in the score");
            }
        } catch (err) {
            // The score can be in an intermediate state while being edited: retry on the next tick
            // MuseScore 4 does not write plugin console output to its log file, so show it in the panel
            console.log("Solo Analyser Live: " + err);
            status.text = qsTr("Error") + ": " + err + (err.lineNumber ? " (line " + err.lineNumber + ")" : "");
            lastKey = "";
        }
    }

    function categoryColor(category) {
        switch (category) {
        case "root": return "" + setting("rootColor", Core.defRootColor);
        case "bass": return "" + setting("bassColor", Core.defBassColor);
        case "chord": return "" + setting("chordColor", Core.defChordColor);
        case "altered": return "" + setting("alteredColor", Core.defAlteredColor);
        case "scale": return "" + setting("scaleColor", Core.defScaleColor);
        case "outside": return "" + setting("errorColor", Core.defErrorColor);
        default: return "#777777";
        }
    }

    // Opens "Interactive", installed in the same folder as this plugin
    function openOptions() {
        var url = "" + Qt.resolvedUrl("soloanalyser-interactive44.qml");
        var m = url.match(/\/plugins\/(.+)$/i);
        var path = m ? decodeURIComponent(m[1]) : "soloanalyser/soloanalyser-interactive44.qml";
        cmd("action://extensions/v1/" + path + "?action=main");
    }

    function esc(s) {
        return ("" + s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }

    // The bar as a table: one column per beat, one row per part, the chord symbols on top.
    // The notes of a chord are stacked, top note first; the chords of a beat are side by side.
    // Thin lines between the parts, the bar number on the chords' line.
    function render(res) {
        var html = "";
        for (var b = 0; b < res.bars.length; b++) {
            var bar = res.bars[b];
            var label = (bar.number === "pickup") ? qsTr("Pickup") : qsTr("Bar") + " " + bar.number;
            // The first column is as wide as the longest part name or the bar number, the beats share the rest
            barMetrics.text = label;
            var nameWidth = barMetrics.advanceWidth + 8; // + cell padding
            bar.staves.forEach(function (st) {
                nameMetrics.text = st.name;
                nameWidth = Math.max(nameWidth, nameMetrics.advanceWidth + 8);
            });
            var namePct = Math.min(40, Math.ceil(100 * nameWidth / Math.max(1, output.width)));
            var w = Math.floor((100 - namePct) / bar.beats.length);
            html += "<table width='100%' border='0' cellspacing='0' cellpadding='3' style='border-collapse:collapse'>";
            html += "<tr><td width='" + namePct + "%'><span style='white-space:nowrap'>" + esc(label) + "</span></td>";
            bar.beats.forEach(function (bt) {
                html += "<td width='" + w + "%' align='center'>"
                    + (bt.chords.length > 0 ? "<b>" + bt.chords.map(esc).join(" ") + "</b>" : "&nbsp;") + "</td>";
            });
            html += "</tr>";
            if (bar.staves.length === 0) {
                html += "<tr><td></td><td colspan='" + bar.beats.length + "' style='color:" + mutedColor + "'><i>" + qsTr("no notes") + "</i></td></tr>";
            }
            bar.staves.forEach(function (st) {
                var cells = bar.beats.map(function () {
                    return [];
                });
                st.events.forEach(function (ev) {
                    var i = 0;
                    while (i + 1 < bar.beats.length && bar.beats[i + 1].tick <= ev.tick) i++;
                    cells[i].push(ev);
                });
                var line = " style='border-top:1px solid " + lineColor + "'";
                html += "<tr><td valign='top'" + line + "><span style='color:" + softColor + "; font-size:7pt; white-space:nowrap'>" + esc(st.name) + "</span></td>";
                cells.forEach(function (evs) {
                    html += "<td valign='top' align='center'" + line + ">";
                    if (evs.length > 0) {
                        html += "<table align='center' cellspacing='0' cellpadding='0'><tr>";
                        evs.forEach(function (ev, e) {
                            html += "<td valign='top' align='center' style='padding-left:" + (e > 0 ? 6 : 0) + "px'>" + renderNotes(ev.notes) + "</td>";
                        });
                        html += "</tr></table>";
                    }
                    html += "</td>";
                });
                html += "</tr>";
            });
            html += "</table>";
        }
        return html;
    }

    // Colours of MuseScore's light/dark theme. The table is rich text, so they are given as "#rrggbb" strings.
    readonly property color textColor: ui.theme.fontPrimaryColor
    readonly property color backgroundColor: ui.theme.backgroundPrimaryColor
    readonly property string softColor: mix(textColor, backgroundColor, 0.3)
    readonly property string mutedColor: mix(textColor, backgroundColor, 0.5)
    readonly property string lineColor: "" + ui.theme.strokeColor

    // a colour between a (t = 0) and b (t = 1)
    function mix(a, b, t) {
        return "" + Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1);
    }

    // A theme change renders the panel again (at the next poll)
    Connections {
        target: ui.theme
        function onThemeChanged() {
            lastKey = "";
        }
    }

    // The notes of a chord, top note first, one per line. The selected note is framed, in the text colour.
    // (A table: rich text has no borders around inline text.)
    function renderNotes(notes) {
        var html = "<table cellspacing='0' cellpadding='0'>";
        notes.slice().reverse().forEach(function (n) {
            var sel = selectedNote !== null && ((typeof n.note.is === "function") ? n.note.is(selectedNote) : n.note === selectedNote);
            html += "<tr><td align='center'>";
            html += sel ? "<table border='1' cellspacing='0' cellpadding='1' style='border-style:solid; border-color:" + textColor + "'><tr><td>"
                + renderNote(n, "" + textColor) + "</td></tr></table>" : renderNote(n, null);
            html += "</td></tr>";
        });
        return html + "</table>";
    }

    // The note name small and grey, then the degree large and coloured ("b" for flats: the ♭ sign is too wide in this font)
    // color: the colour of the name, instead of grey
    function renderNote(n, color) {
        var name = esc(n.name.replace(/♭/g, "b"));
        return n.degree
            ? "<span style='color:" + (color || mutedColor) + "; font-size:9pt'>" + name + "</span>&nbsp;<b style='color:" + categoryColor(n.category) + "'>" + esc(n.degree) + "</b>"
            : "<span style='color:" + (color || mutedColor) + "'>" + name + "</span>";
    }

    TextMetrics {
        id: nameMetrics
        font.pointSize: 7
    }

    TextMetrics {
        id: barMetrics
        font.pointSize: 10
    }

    component SmallCheck: SmallCheckBox {
        font.pointSize: 8
        padding: 0
        spacing: 3
        boxWidth: 14
    }

    // Codes of MuseScore's icon font (ui.theme.iconsFont), see MuseScore's iconcodes.h
    readonly property var icons: ({
        "play": String.fromCharCode(0xEF1D),
        "pause": String.fromCharCode(0xF3C9),
        "refresh": String.fromCharCode(0xF358),
        "settings": String.fromCharCode(0xEF55),
        "arrowDown": String.fromCharCode(0xEF12)
    })

    // A flat button with a text and/or an icon of MuseScore's icon font
    component ThemedToolButton: ToolButton {
        id: tb
        property string iconChar: ""
        font.pointSize: 8
        implicitHeight: 24
        hoverEnabled: true
        contentItem: Row {
            spacing: 4
            Text {
                visible: tb.text !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: tb.text
                font: tb.font
                color: textColor
            }
            Text {
                visible: tb.iconChar !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: tb.iconChar
                font: ui.theme.iconsFont
                color: textColor
            }
        }
        background: Rectangle {
            implicitWidth: 24
            implicitHeight: 24
            radius: 3
            color: ui.theme.buttonColor
            opacity: tb.down ? ui.theme.buttonOpacityHit : tb.hovered ? ui.theme.buttonOpacityHover : 0
        }
    }

    Rectangle {
        anchors.fill: parent
        color: backgroundColor

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 4
            spacing: 2

            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                ThemedToolButton {
                    id: btnParts
                    readonly property int nIncluded: parts.filter(function (p) {
                        return excludedParts.indexOf(p.key) < 0;
                    }).length
                    text: qsTr("Parts") + ((nIncluded < parts.length) ? " " + nIncluded + "/" + parts.length : "")
                    iconChar: icons.arrowDown
                    ToolTip.visible: hovered && !partsPopup.visible
                    ToolTip.text: qsTr("Choose the parts to analyse")
                    onClicked: partsPopup.visible ? partsPopup.close() : partsPopup.open()

                    Popup {
                        id: partsPopup
                        y: btnParts.height
                        x: 0
                        width: 200
                        height: Math.min(partsList.contentHeight + topPadding + bottomPadding, mainWindow.height - 30)
                        padding: 4
                        background: Rectangle {
                            color: ui.theme.popupBackgroundColor
                            border.color: ui.theme.strokeColor
                            radius: 3
                        }

                        ListView {
                            id: partsList
                            anchors.fill: parent
                            clip: true
                            model: parts
                            ScrollBar.vertical: ScrollBar {}
                            delegate: SmallCheck {
                                width: partsList.width
                                text: modelData.name
                                checked: excludedParts.indexOf(modelData.key) < 0
                                onToggled: setPartIncluded(modelData.key, checked)
                            }
                        }
                    }
                }
                Item { Layout.fillWidth: true }
                ThemedToolButton {
                    iconChar: live ? icons.pause : icons.play
                    ToolTip.visible: hovered
                    ToolTip.text: live
                        ? qsTr("Live: the notes are coloured and numbered in the score while you compose, as set in \"Interactive\". Each update is one undo step. Click to pause.")
                        : qsTr("Paused: nothing is updated, the colours and numbers stay in the score. Click to resume.")
                    onClicked: {
                        live = !live;
                        if (live) refresh(true);
                        else status.text = qsTr("Paused");
                    }
                }
                ThemedToolButton {
                    iconChar: icons.refresh
                    ToolTip.visible: hovered
                    ToolTip.text: qsTr("Refresh")
                    onClicked: refresh(true)
                }
                ThemedToolButton {
                    iconChar: icons.settings
                    ToolTip.visible: hovered
                    ToolTip.text: qsTr("Options: opens \"Interactive\"")
                    onClicked: openOptions()
                }
            }

            Flickable {
                id: flick
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentWidth: width
                contentHeight: output.paintedHeight
                ScrollBar.vertical: ScrollBar {
                    policy: (flick.contentHeight > flick.height) ? ScrollBar.AlwaysOn : ScrollBar.AsNeeded
                }

                Text {
                    id: output
                    width: flick.width - ((flick.contentHeight > flick.height) ? 10 : 0)
                    onWidthChanged: lastKey = "" // the parts column width depends on it: rendered again at the next poll
                    textFormat: Text.RichText
                    wrapMode: Text.WordWrap
                    color: textColor
                    font.pointSize: 10
                }
            }

            Text {
                id: legend
                horizontalAlignment: Text.AlignRight
                Layout.fillWidth: true
                textFormat: Text.RichText
                font.pointSize: 7
            }

            Text {
                id: status
                Layout.fillWidth: true
                color: mutedColor
                font.pointSize: 7
                elide: Text.ElideRight
            }
        }
    }
}
