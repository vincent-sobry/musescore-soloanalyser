/**********************
/* Parking B - MuseScore - Solo Analyser - Live analyse
/* Analyse used by soloanalyser-live.qml: analyse() reads the score without modifying it and returns
/* a data structure for the panel; writeToScore() and clearScore() write and remove that analyse in
/* the score, touching only what differs, so that unchanged scores produce no undo steps.
/* Requires "notehelper.js" as NoteHelper and "chordanalyser.js" as ChordHelper in the importing QML.
/* ChangeLog:
/*  - 1.0.0: Initial version
/*  - 1.1.0: Parts can be excluded from the analyse; beats of the bars; short part names
/**********************************************/

// Parsed chords, by chord symbol text. ChordHelper.chordFromText is costly and verbose, and the
// live analyse runs several times per second, so each distinct chord symbol is parsed only once.
var chordCache = {};

function parseChord(text) {
    if (!chordCache.hasOwnProperty(text)) {
        chordCache[text] = ChordHelper.chordFromText(text);
    }
    return chordCache[text];
}

/**
* The position of the selection: {tick, note}, tick -1 when nothing is selected,
* note the selected note, if any (null otherwise).
*/
function getSelection() {
    var res = {
        "tick": -1,
        "note": null
    };
    if (!curScore) return res;
    var sel = curScore.selection;
    if (sel.isRange && sel.startSegment) {
        res.tick = sel.startSegment.tick;
        return res;
    }
    var els = sel.elements;
    for (var i = 0; i < els.length; i++) {
        var el = els[i];
        if (el.type === Element.NOTE) res.note = el;
        while (el && el.type !== Element.SEGMENT) {
            el = el.parent;
        }
        if (el) {
            res.tick = el.tick;
            return res;
        }
    }
    return res;
}

/**
* The parts of the score, with a key that identifies them across sessions: the part name, numbered
* when several parts have the same name (part indexes and tracks change when instruments are added).
* @return [{key, name, shortName, drum, startTrack, endTrack}]
*/
function getParts() {
    var res = [];
    if (!curScore) return res;
    var count = {};
    var countShort = {};
    for (var p = 0; p < curScore.parts.length; p++) {
        var part = curScore.parts[p];
        var name = part.longName || part.partName || ("Part " + (p + 1));
        var shortName = part.shortName || name;
        count[name] = (count[name] || 0) + 1;
        countShort[shortName] = (countShort[shortName] || 0) + 1;
        res.push({
            "key": name + "#" + count[name],
            "name": (count[name] > 1) ? name + " " + count[name] : name,
            "shortName": (countShort[shortName] > 1) ? shortName + " " + countShort[shortName] : shortName,
            "drum": part.hasDrumStaff,
            "startTrack": part.startTrack,
            "endTrack": part.endTrack
        });
    }
    return res;
}

/**
* Length and beats of a measure, in ticks (a quarter note is 480 ticks).
* The beat is the denominator of the time signature, or a dotted note in compound metres (6/8, 9/8, 12/8...).
* @return {length, beat}
*/
function measureBeats(m, nextTick) {
    var num = 4;
    var den = 4;
    var ts = m.timesigNominal;
    if (ts && ts.numerator > 0 && ts.denominator > 0) {
        num = ts.numerator;
        den = ts.denominator;
    }
    var beat = 1920 / den;
    if (den >= 8 && num > 3 && num % 3 === 0) beat *= 3;
    var length = (m.ticks && m.ticks.ticks > 0) ? m.ticks.ticks : (nextTick !== null ? nextTick - m.firstSegment.tick : num * 1920 / den);
    return {
        "length": length,
        "beat": beat
    };
}

/**
* Analyse the bar at a given tick, or the whole score.
* @param focusTick  the tick of the bar to analyse (-1: first bar)
* @param options    {wholeScore, useAboveSymbols, useBelowSymbols, lookAhead, ignoreBrackettedChords,
*                   excludedParts: [part keys, see getParts()] not analysed (their chord symbols are still used)}
* @return {key, bars: [{number, chords: [string], beats: [{tick, chords: [string]}],
*           staves: [{name, events: [{tick, chordRest, chord, chordName, notes: [{note, name, degree, category, explicitOutside}]}]}]}]}
*   key is a fingerprint of everything the result depends on, so that the caller can skip rendering when nothing changed.
*/
function analyse(focusTick, options) {
    if (!curScore || !curScore.firstMeasure) return null;

    // 1) Measures and analyse window
    var measures = [];
    for (var m = curScore.firstMeasure; m; m = m.nextMeasure) {
        // measure.no (MuseScore 4.6+) follows the score numbering (pickups, excluded measures, offsets)
        var no = (m.no !== undefined) ? m.no + 1 : measures.length + 1;
        measures.push({
            "number": m.irregular ? ((measures.length === 0) ? "pickup" : no + " (unnumbered)") : "" + no,
            "tick": m.firstSegment.tick,
            "measure": m
        });
    }
    var focus = 0;
    for (var i = 0; i < measures.length; i++) {
        if (measures[i].tick <= focusTick) focus = i;
    }
    var first = options.wholeScore ? 0 : focus;
    var last = options.wholeScore ? measures.length - 1 : focus;

    var ntracks = curScore.ntracks;
    var nstaves = ntracks / 4;
    var key = [first, last];

    // 2) Chord symbols, consolidated by staff (as core.js does on the 1st voice of each staff)
    var byStaff = [];
    for (var s = 0; s < nstaves; s++) byStaff.push([]);
    var segments = [];
    for (var seg = curScore.firstMeasure.firstSegment; seg; seg = seg.next) {
        var anns = seg.annotations;
        for (var a = 0; a < anns.length; a++) {
            var ann = anns[a];
            if (ann.type !== Element.HARMONY || ann.harmonyType !== HarmonyType.STANDARD) continue;
            if (!ann.text) continue;
            if (options.ignoreBrackettedChords && (ann.text.search(/^\(.+\)$/g) !== -1)) continue;
            var chord = parseChord(ann.text);
            if (chord === null) continue;
            byStaff[(ann.track / 4) | 0].push({
                "tick": seg.tick,
                "chord": chord
            });
            key.push(seg.tick + "@" + ann.track + "=" + ann.text);
        }
    }

    // Segments of the window, taken measure by measure so that each one is attached to its own bar
    // (matching segments to bars by tick failed on some scores)
    for (var b = first; b <= last; b++) {
        for (var seg = measures[b].measure.firstSegment; seg; seg = seg.nextInMeasure) {
            if (seg.segmentType === Segment.ChordRest) {
                segments.push({
                    "segment": seg,
                    "bar": b - first
                });
            }
        }
    }

    if (options.useAboveSymbols) {
        for (var s = 1; s < nstaves; s++) {
            if (byStaff[s].length === 0) byStaff[s] = byStaff[s - 1];
        }
    }
    if (options.useBelowSymbols) {
        for (var s = nstaves - 2; s >= 0; s--) {
            if (byStaff[s].length === 0) byStaff[s] = byStaff[s + 1];
        }
    }

    // 3) Staves to analyse (no drum staves, no excluded parts)
    var parts = getParts();
    var excluded = options.excludedParts || [];
    var staves = [];
    for (var s = 0; s < nstaves; s++) {
        var name = "Staff " + (s + 1);
        var skip = false;
        var partIdx = -1;
        for (var p = 0; p < parts.length; p++) {
            var part = parts[p];
            if (s * 4 >= part.startTrack && s * 4 < part.endTrack) {
                name = part.shortName;
                skip = part.drum || excluded.indexOf(part.key) >= 0;
                partIdx = p;
                break;
            }
        }
        staves.push({
            "name": name,
            "skip": skip,
            "part": partIdx,
            "signature": []
        });
    }

    // 4) Notes in the window
    var bars = [];
    for (var b = first; b <= last; b++) {
        var barStart = measures[b].tick;
        var barEnd = (b + 1 < measures.length) ? measures[b + 1].tick : Infinity;
        var mb = measureBeats(measures[b].measure, (b + 1 < measures.length) ? barEnd : null);
        key.push(mb.length + "/" + mb.beat);
        var nbeats = Math.max(1, Math.ceil(mb.length / mb.beat));
        var beats = [];
        for (var i = 0; i < nbeats; i++) {
            var bt = barStart + i * mb.beat;
            beats.push({
                "tick": bt,
                "chords": chordNamesBetween(byStaff, bt, Math.min(bt + mb.beat, barEnd))
            });
        }
        bars.push({
            "number": measures[b].number,
            "chords": chordNamesBetween(byStaff, barStart, barEnd),
            "beats": beats,
            "staves": staves.map(function () {
                return {
                    "events": []
                };
            })
        });
    }

    for (var g = 0; g < segments.length; g++) {
        var seg = segments[g].segment;
        var bar = bars[segments[g].bar];
        for (var t = 0; t < ntracks; t++) {
            var s = (t / 4) | 0;
            if (staves[s].skip) continue;
            var el = seg.elementAt(t);
            if (!el || el.type !== Element.CHORD) continue;
            var curChord = chordAt(byStaff[s], seg.tick, options.lookAhead);
            var notes = [];
            for (var n = 0; n < el.notes.length; n++) {
                var note = el.notes[n];
                if (!note.visible || note.headGroup === NoteHeadGroup.HEAD_SLASH) continue;
                var res = analyseNote(note, curChord);
                res.note = note;
                notes.push(res);
                key.push(seg.tick + "/" + t + ":" + note.pitch + "." + note.tpc);
                staves[s].signature.push(seg.tick + ":" + (t % 4) + ":" + note.pitch);
            }
            if (notes.length === 0) continue;
            var events = bar.staves[s].events;
            var chordName = (curChord !== null) ? curChord.name : null;
            var prev = (events.length > 0) ? events[events.length - 1] : null;
            events.push({
                "tick": seg.tick,
                "chordRest": el,
                "chord": (prev === null || prev.chordName !== chordName) ? chordName : null,
                "chordName": chordName,
                "notes": notes
            });
        }
    }

    // Linked staves (e.g. a guitar's TAB staff) hold the same notes as their main staff. They are analysed
    // only once: shown twice otherwise, and, when writing, each label added on one staff is copied by
    // MuseScore to the linked one, giving double labels. The plugin API does not expose staff links, so
    // a staff with exactly the same notes as a previous staff of the same part is taken as a linked one.
    var duplicate = staves.map(function (st, s) {
        var sig = st.signature.join(",");
        if (sig === "") return false;
        for (var o = 0; o < s; o++) {
            if (staves[o].part === st.part && staves[o].signature.join(",") === sig) return true;
        }
        return false;
    });
    // staff names: the part name, numbered only when the part has several (non linked) staves
    staves.forEach(function (st, s) {
        if (duplicate[s]) return;
        var others = [];
        staves.forEach(function (x, o) {
            if (!duplicate[o] && x.part === st.part) others.push(o);
        });
        if (others.length > 1) st.name += " " + (others.indexOf(s) + 1);
    });

    bars.forEach(function (bar) {
        bar.staves.forEach(function (st, s) {
            st.name = staves[s].name;
        });
        bar.staves = bar.staves.filter(function (st, s) {
            return !duplicate[s] && st.events.length > 0;
        });
    });

    return {
        "key": key.join("|"),
        "bars": bars
    };
}

/**
* The chord in effect at the given tick: the last chord symbol at or before that tick,
* or, with lookAhead, the first one after it (e.g. anacrusis).
*/
function chordAt(chords, tick, lookAhead) {
    var found = null;
    var next = null;
    for (var i = 0; i < chords.length; i++) {
        var c = chords[i];
        if (c.tick <= tick) {
            if (found === null || c.tick >= found.tick) found = c;
        } else if (next === null || c.tick < next.tick) {
            next = c;
        }
    }
    if (found !== null) return found.chord;
    if (lookAhead && next !== null) return next.chord;
    return null;
}

/**
* The distinct chord names found in [from, to[ across all staves, in tick order.
*/
function chordNamesBetween(byStaff, from, to) {
    var all = [];
    var seen = {};
    byStaff.forEach(function (chords) {
        chords.forEach(function (c) {
            var id = c.tick + ":" + c.chord.name;
            if (c.tick >= from && c.tick < to && !seen[id]) {
                seen[id] = true;
                all.push(c);
            }
        });
    });
    all.sort(function (a, b) {
        return a.tick - b.tick;
    });
    var names = [];
    all.forEach(function (c) {
        if (names[names.length - 1] !== c.chord.name) names.push(c.chord.name);
    });
    return names;
}

/**
* Role of a note relative to a chord. Same rules as core.js's analyseNote in "chord" coloring mode,
* with every note named (nameNotes "all"), but nothing written to the score.
* @return {name, degree, category} where category is one of
*   root|bass|chord|altered|scale|outside|nochord
*/
function analyseNote(note, curChord) {
    var name = NoteHelper.pitchToName(note.pitch, note.tpc).fullname;
    if (curChord === null) {
        return {
            "name": name,
            "degree": "",
            "category": "nochord"
        };
    }

    // pitch as displayed (instrument pitch for transposing instruments), as the chord names are
    var tpitch = note.pitch + NoteHelper.deltaTpcToPitch(note.tpc, note.tpc1);
    var p = (tpitch - curChord.pitch + 1200) % 12;

    var cRole = curChord.getChordNote(p);
    var sRole = curChord.getScaleNote(p);
    var degree;
    var category;
    var explicitOutside = false; // explicitely defined as outside by the chord (vs. simply not in the scale)

    if (cRole !== undefined) {
        degree = cRole.role;
        if (p === 0) category = "root";
        else if (curChord.bass != null && p === curChord.bass.key) category = "bass";
        else if (degree.indexOf("b") === 0 || degree.indexOf("#") === 0) category = "altered";
        else category = "chord";
    } else if (curChord.outside.indexOf(p) >= 0) {
        degree = sRole ? sRole.role : "✗";
        category = "outside";
        explicitOutside = true;
    } else if (curChord.keys.indexOf(p) >= 0) {
        degree = sRole ? sRole.role : "?";
        category = "scale";
    } else {
        degree = sRole ? sRole.role : "✗";
        category = "outside";
    }

    return {
        "name": name,
        "degree": degree,
        "category": category,
        "explicitOutside": explicitOutside
    };
}

/**
* Writes the analyse in the score, as note colours and labels, following the colorNotes/nameNotes/textType
* modes of the other Solo Analyser plugins: labels as fingerings (above the notes) or as lyrics (below the
* staff, which leaves the fingerings free for real fingerings). Only what differs is touched, and nothing
* at all (no undo step) when the score already matches the analyse.
* This matters for undo: the caller only writes when the notes or chord symbols changed, so an undo of
* the analyse step is not re-applied, and a next undo reaches the user's own edit.
* @param res        the result of analyse()
* @param modes      {colorNotes: none|chord|all|outside, nameNotes: none|chord|all, textType: fingering|lyrics}
* @param colors     function(category) returning the colour to use for that category
* @return the number of notes and chords modified
*/
function writeToScore(res, modes, colors) {
    var asLyrics = (modes.textType === "lyrics");
    var changes = [];
    res.bars.forEach(function (bar) {
        bar.staves.forEach(function (st) {
            st.events.forEach(function (ev) {
                var degrees = [];
                ev.notes.forEach(function (n) {
                    var want = desiredMarking(n, modes, colors);
                    degrees.push(want.degree);
                    var fingerings = findDegreeFingerings(n.note);
                    var fingering = (fingerings.length > 0) ? fingerings[0] : null;
                    var wantFingering = asLyrics ? null : want.degree;
                    var colorChange = (want.color !== null) && (normalizeColor(n.note.color) !== normalizeColor(want.color));
                    if (colorChange || (fingering ? fingering.text : null) !== wantFingering) {
                        changes.push(function () {
                            if (colorChange) n.note.color = want.color;
                            if (wantFingering === null) {
                                if (fingering) n.note.remove(fingering);
                            } else if (fingering) {
                                fingering.text = wantFingering;
                            } else {
                                var f = newElement(Element.FINGERING);
                                f.text = wantFingering;
                                f.autoplace = true;
                                n.note.add(f);
                            }
                        });
                    }
                });

                // Lyrics: one verse per labelled note, top note first, after the chord's own lyrics (as core.js)
                var wantLyrics = asLyrics ? degrees.filter(function (d) {
                    return d !== null;
                }).reverse() : [];
                var lyrics = findDegreeLyrics(ev.chordRest);
                var curLyrics = lyrics.map(function (l) {
                    return l.text;
                });
                if (curLyrics.join("|") !== wantLyrics.join("|")) {
                    changes.push(function () {
                        lyrics.forEach(function (l) {
                            ev.chordRest.remove(l);
                        });
                        var lastVerse = -1;
                        var others = ev.chordRest.lyrics;
                        for (var i = 0; i < others.length; i++) {
                            lastVerse = Math.max(lastVerse, others[i].verse);
                        }
                        wantLyrics.forEach(function (d) {
                            var l = newElement(Element.LYRICS);
                            l.text = d;
                            l.autoplace = true;
                            l.verse = ++lastVerse;
                            ev.chordRest.add(l);
                        });
                    });
                }
            });
        });
    });

    if (changes.length === 0) return 0;

    curScore.startCmd();
    changes.forEach(function (apply) {
        apply();
    });
    curScore.endCmd();
    return changes.length;
}

/**
* Colour and label for a note, same rules as core.js's analyseNote.
* @return {color: colour or null to leave untouched, degree: text or null for no label}
*/
function desiredMarking(n, modes, colors) {
    var cat = n.category;
    var inChord = (cat === "root" || cat === "bass" || cat === "chord" || cat === "altered");
    var color = "black";
    var degree = null;

    if (cat === "nochord") {
        color = "black";
    } else if (modes.colorNotes === "outside") {
        if (cat === "outside") color = colors("outside");
        else if (cat === "altered") color = colors("altered");
        if (cat === "outside" || cat === "altered" || modes.nameNotes === "all") degree = n.degree;
    } else {
        if (inChord) color = colors(cat);
        else if (n.explicitOutside) color = colors("outside");
        else if (cat === "scale" && modes.colorNotes === "all") color = colors("scale");

        if (modes.nameNotes === "all" || (modes.nameNotes === "chord" && inChord)) degree = n.degree;
    }

    return {
        "color": (modes.colorNotes === "none") ? null : color,
        "degree": (modes.nameNotes === "none" || !degree) ? null : degree
    };
}

// The fingerings previously written by the Solo Analyser on that note (user fingerings are kept)
var degreefinder = /^(\(?(M|m|b|#)?[0-9]{1,2}\)?|✗|n\.f\.)$/;

function findDegreeFingerings(note) {
    var res = [];
    var els = note.elements;
    for (var i = 0; i < els.length; i++) {
        var e = els[i];
        if (e.type === Element.FINGERING && e.text && degreefinder.test(e.text)) res.push(e);
    }
    return res;
}

// The lyrics previously written by the Solo Analyser on that chord (song lyrics are kept), by verse
function findDegreeLyrics(chord) {
    var res = [];
    var lyrics = chord.lyrics;
    for (var i = 0; i < lyrics.length; i++) {
        if (lyrics[i].text && degreefinder.test(lyrics[i].text)) res.push(lyrics[i]);
    }
    return res.sort(function (a, b) {
        return a.verse - b.verse;
    });
}

function normalizeColor(c) {
    return ("" + Qt.lighter(c, 1.0)).toLowerCase();
}

/**
* Removes the analyse written by writeToScore from the whole score: the number fingerings and lyrics,
* and the note colours that are one of the analyse colours (other colours are kept). One undo step,
* or none when there is nothing to remove.
* @param colors     the analyse colours
* @param partKeys   optional: only clear these parts (keys of getParts())
* @return the number of notes and chords modified
*/
function clearScore(colors, partKeys) {
    if (!curScore || !curScore.firstMeasure) return 0;
    var palette = colors.map(normalizeColor);
    var changes = [];
    var ntracks = curScore.ntracks;
    var tracks = [];
    getParts().forEach(function (part) {
        if (partKeys && partKeys.indexOf(part.key) < 0) return;
        for (var t = part.startTrack; t < part.endTrack && t < ntracks; t++) tracks.push(t);
    });
    for (var seg = curScore.firstMeasure.firstSegment; seg; seg = seg.next) {
        if (seg.segmentType !== Segment.ChordRest) continue;
        for (var i = 0; i < tracks.length; i++) {
            var t = tracks[i];
            var el = seg.elementAt(t);
            if (!el || el.type !== Element.CHORD) continue;
            findDegreeLyrics(el).forEach(function (l) {
                changes.push({ "parent": el, "remove": l });
            });
            for (var n = 0; n < el.notes.length; n++) {
                var note = el.notes[n];
                findDegreeFingerings(note).forEach(function (f) {
                    changes.push({ "parent": note, "remove": f });
                });
                if (palette.indexOf(normalizeColor(note.color)) >= 0) {
                    changes.push({ "note": note });
                }
            }
        }
    }

    if (changes.length === 0) return 0;

    curScore.startCmd();
    changes.forEach(function (c) {
        if (c.remove) c.parent.remove(c.remove);
        else c.note.color = "black";
    });
    curScore.endCmd();
    return changes.length;
}
