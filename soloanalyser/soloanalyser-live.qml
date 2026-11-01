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
/* of the current bar relative to the chord symbols. Optionally writes the analyse in the score,
/* and removes it when the window is closed.
/* All the options are the ones of "Interactive" (opened with the ⚙ button).
/* MuseScore 4 does not emit onScoreStateChanged to plugins, so the score is polled with a Timer.
/* MuseScore 4 cannot dock plugins in its side panels: only "dialog" windows are supported.
/* ChangeLog:
/*  - 1.0.0: Initial version
/*  - 1.1.0: Options taken from "Interactive"; analyse removed from the score when closing
/**********************************************/

MuseScore {
    menuPath: "Plugins.Solo Analyser." + pluginName
    description: "Live panel showing the role of the notes of the current bar relative to the chord symbols."
    version: "1.1.0"

    readonly property var pluginName: qsTr("Live")

    title: "Solo Analyser Live"
    thumbnailName: "logoSoloAnalyserInteractive.png"
    categoryCode: "color-notes"

    pluginType: "dialog"
    width: 380
    height: 200

    id: mainWindow

    property int lastFocusTick: -1
    property string lastKey: ""
    property string lastWriteKey: ""
    property bool cleanedUp: false
    readonly property var categories: ["root", "bass", "chord", "altered", "scale", "outside"]

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
        property alias writeInScore: chkWrite.checked
    }

    Timer {
        id: poller
        interval: 400
        repeat: true
        running: !chkPause.checked && !cleanedUp
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
        if (!chkWrite.checked) return;
        try {
            clearScore();
        } catch (err) {
            console.log("Solo Analyser Live: " + err);
        }
    }

    function clearScore() {
        if (!curScore) return;
        Live.clearScore(categories.map(categoryColor));
        lastWriteKey = "";
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
            "ignoreBrackettedChords": opt("ignoreBrackettedChords", Core.defIgnoreBrackettedChords)
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
            var tick = Live.getSelectionTick();
            if (tick >= 0) lastFocusTick = tick; // keep the last position when the selection is cleared

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
            if (force || res.key + settingsKey !== lastKey) {
                lastKey = res.key + settingsKey;
                output.text = render(res);
                legend.text = categories.map(function (c) {
                    return "<span style='color:" + categoryColor(c) + "'>■ " + c + "</span>";
                }).join(" ");
                status.text = qsTr("Updated") + " " + Qt.formatTime(new Date(), "hh:mm:ss");
            }
            if (chkWrite.checked) {
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

    function render(res) {
        var html = "";
        for (var b = 0; b < res.bars.length; b++) {
            var bar = res.bars[b];
            var label = (bar.number === "pickup") ? qsTr("Pickup") : qsTr("Bar") + " " + bar.number;
            html += "<p style='margin-top:4px; margin-bottom:0px'><b>" + esc(label) + "</b>";
            if (bar.chords.length > 0) html += " &nbsp;<span style='color:#555555'>" + bar.chords.map(esc).join(" · ") + "</span>";
            html += "</p>";
            if (bar.staves.length === 0) {
                html += "<p style='margin:0px 0px 0px 6px; color:#999999'><i>" + qsTr("no notes") + "</i></p>";
                continue;
            }
            for (var s = 0; s < bar.staves.length; s++) {
                var st = bar.staves[s];
                html += "<p style='margin:0px 0px 0px 6px'>";
                if (bar.staves.length > 1)
                    html += "<span style='color:#555555'>" + esc(st.name) + ":</span> ";
                for (var e = 0; e < st.events.length; e++) {
                    var ev = st.events[e];
                    if (ev.chord !== null) html += "<span style='color:#555555'>[" + esc(ev.chord) + "]</span> ";
                    if (e > 0 && ev.chord === null && ev.chordName === null && st.events[e - 1].chordName !== null)
                        html += "<span style='color:#555555'>[–]</span> ";
                    html += ev.notes.map(function (n) {
                        var c = categoryColor(n.category);
                        return "<span style='color:" + c + "'>" + esc(n.name) + (n.degree ? " <b>" + esc(n.degree) + "</b>" : "") + "</span>";
                    }).join("+") + " &nbsp;";
                }
                html += "</p>";
            }
        }
        return html;
    }

    component SmallCheck: CheckBox {
        font.pointSize: 8
        padding: 0
        spacing: 3
    }

    Rectangle {
        anchors.fill: parent
        color: "#fafafa"

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 4
            spacing: 2

            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                SmallCheck {
                    id: chkWrite
                    checked: false
                    text: qsTr("Write in score")
                    hoverEnabled: true
                    ToolTip.visible: hovered
                    ToolTip.text: qsTr("Colour and number the notes in the score while you compose, as set in \"Interactive\". Removed when unchecked or when this window is closed. Each update is one undo step.")
                    onCheckedChanged: {
                        if (checked) refresh(true);
                        else if (!cleanedUp) clearScore();
                    }
                }
                SmallCheck {
                    id: chkPause
                    checked: false
                    text: qsTr("Pause")
                }
                Item { Layout.fillWidth: true }
                ToolButton {
                    text: "↻"
                    font.pointSize: 9
                    implicitWidth: 24
                    implicitHeight: 22
                    hoverEnabled: true
                    ToolTip.visible: hovered
                    ToolTip.text: qsTr("Refresh")
                    onClicked: refresh(true)
                }
                ToolButton {
                    text: "⚙"
                    font.pointSize: 9
                    implicitWidth: 24
                    implicitHeight: 22
                    hoverEnabled: true
                    ToolTip.visible: hovered
                    ToolTip.text: qsTr("Options: opens \"Interactive\"")
                    onClicked: openOptions()
                }
            }

            Text {
                id: legend
                Layout.fillWidth: true
                textFormat: Text.RichText
                font.pointSize: 7
            }

            Flickable {
                id: flick
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentWidth: width
                contentHeight: output.paintedHeight
                ScrollBar.vertical: ScrollBar {}

                Text {
                    id: output
                    width: flick.width
                    textFormat: Text.RichText
                    wrapMode: Text.WordWrap
                    color: "#222222"
                    font.pointSize: 10
                }
            }

            Text {
                id: status
                Layout.fillWidth: true
                color: "#888888"
                font.pointSize: 7
                elide: Text.ElideRight
            }
        }
    }
}
