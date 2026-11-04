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
                    118 × 34, kein Modus-Symbol (Variante B), Kopieren der Unterhaltung in der Leiste
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
                    abgedunkelt. Live-Text: reines Weiß, Höhe folgt dem Text bis vier Zeilen, dann Scrollen.
                    Assistent: Tönung 0,66, Feld mit Platzhalter „Folgefrage stellen“, gedimmt auf 50 %, wenn
                    keine Folgefrage möglich ist.
negativ:            [x] zweiter Akzent (Rot nur für Aufnahme) [x] Glow ohne Anlass (Lichtkante ist Tiefe, kein
                    Glow) [x] neu gebaut statt Komponente (runde Knöpfe aus einer Komponente)
                    [ ] gefüllte Flächen [ ] Emoji [ ] Demo-Zahlen [ ] Sheet mit Loch
zahlen:             Keine.
konzeptfreigabe:    Variante B „Minimal“, gewählt von Yannik am 28.09.2026 (Charta, Gelernt-Log). Sichtprüfung
                    des Wiederaufbaus über weißem Dokument, dunklem Editor und buntem Hintergrund vor der
                    Installation.
