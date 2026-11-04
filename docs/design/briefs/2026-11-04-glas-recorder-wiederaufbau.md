# UI-Brief: Mini-Recorder in Liquid Glass (Wiederaufbau)

> Wiederaufbau der verlorenen Commits `846eccc` und `dad40b5` (YAN-257, 28.09.2026) nach der
> Charta `docs/design/charta.md`. Der Originalcode ist nicht erhalten; Maße und Farben stammen aus
> der Token-Tabelle der Charta und dem Island-Brief vom 02.10.2026, der die Welle 1:1 übernahm.

flaeche:            Mini-Recorder unten am Bildschirm. Dateien: MiniRecorderView, RecorderGlassComponents,
                    RecorderComponents (nur AssistantPanelView bekommt einen Glas-Stil). Structs:
                    RecorderGlassSurface, VoiceWaveform, VoiceWaveformActivity, RecorderLiveDotButton,
                    RecorderRoundButton, RecorderCopyButton, RecorderGlassLiveText.
vorbild_innen:      Upstream-Stand `MiniRecorderView.swift` (schwarze 184 × 40-Leiste mit Knopf, Welle,
                    Modus-Knopf) und `RecorderComponents.swift` (Schließen-Scheibe 21 pt, Weiß 13 %/18 %, die
                    Vorlage für `RecorderRoundButton`). Übernommen: Zustandsmodell `RecordingState`,
                    Assistent-Sitzung, Pegelkurve `pow(level, 0.7)`. Anders: Glas statt Schwarz, Kapsel
                    118 × 34, kein Modus-Symbol (Variante B), Kopieren der Unterhaltung direkt rechts neben der Leiste
                    gespiegelt zum Schließen. Notch-Recorder bleibt unverändert (Upstream-Fläche).
vorbild_aussen:     Entfällt: Wiederaufbau einer von Yannik am 28.09.2026 gewählten Variante; keine offene
                    Gestaltungsfrage.
held:               Die Welle: 13 runde Balken, 3 pt breit, 2,5 pt Abstand, 3 bis 24 pt hoch, Linsen-Hüllkurve
                    (Außenbalken ein Fünftel der Mitte), schwingt ±7 % um den Pegel.
navigation:         Keine. Klick auf den Punkt startet oder stoppt; Schließen beendet die Assistent-Antwort.
                    Ziehen am Glas verschiebt das Fenster.
motion:             Dutzende pro Tag: Erscheinen 120 ms, Ausklappen und Wachsen des Assistenten 150 ms, Text
                    nach 60 ms in 80 ms, Einklappen 60 ms, neue Nachrichten 150 ms. Schleifen nur bei Arbeit
                    (Schimmer 1,05 s, Atmen 1,6 s). Reduce Motion: keine Skalierung, keine Größenanimation,
                    Schleifen nur über Helligkeit.
zustaende:          Bereit: weißer Punkt 75 %, ruhende Welle. Start: Punkt gedimmt. Aufnahme: roter Punkt mit
                    weißem Rand, lebende Welle. Transkribieren: System-Spinner am Platz des Punkts, Schimmer.
                    Verbessern und Assistent denkt: Funkeln (deaktiviert), atmende Linse. Belegt: Ring 85 %.
                    Hover zeigt Start (Punkt) oder Stopp (Quadrat) auf weißer Scheibe, Rot um ein Viertel
                    abgedunkelt. Live-Text: reines Weiß, Höhe folgt dem Text bis drei Zeilen (56 pt), dann Scrollen.
                    Assistent: Tönung 0,66, Feld mit Platzhalter „Folgefrage stellen“, gedimmt auf 50 %, wenn
                    keine Folgefrage möglich ist.
negativ:            [x] zweiter Akzent (Rot nur für Aufnahme) [x] Glow ohne Anlass (Lichtkante ist Tiefe, kein
                    Glow) [x] neu gebaut statt Komponente (runde Knöpfe aus einer Komponente)
                    [ ] gefüllte Flächen [ ] Emoji [ ] Demo-Zahlen [ ] Sheet mit Loch
geometrie:          Aus der Referenz-App vom 04.11.2026 ausgelesen (Maschinencode von MiniRecorderView,
                    RecorderLiveDotButton, VoiceWaveform, LiveTranscriptView): Die Leiste aus Punkt und Welle
                    bleibt in jedem Zustand 118 × 34 und steht mittig, auch wenn das Glas für Live-Text (300) oder
                    Assistent (520) wächst; Innenabstand links 3, rechts 12; Punktfläche 28. Haarlinie 0,5 pt
                    Weiß 12 % zwischen Text und Leiste. Punkt: bereit 8 pt Weiß 75 %; Start Ring 12 pt Weiß
                    50 % mit Rot 60 %; Aufnahme Ring 12 pt Weiß 95 % mit 9 pt Rot; Hover Scheibe 20 pt Weiß 95 %
                    mit 9-pt-Punkt bzw. 8-pt-Quadrat (Radius 2). Live-Text 12 pt, Innenabstand 16 × 6,
                    höchstens 56 pt hoch. Erscheinen als Feder 0,14 s / 0,85 aus 90 %.
zahlen:             Keine.
konzeptfreigabe:    Variante B „Minimal“, gewählt von Yannik am 28.09.2026 (Charta, Gelernt-Log). Sichtprüfung
                    des Wiederaufbaus über weißem Dokument, dunklem Editor und buntem Hintergrund vor der
                    Installation.
