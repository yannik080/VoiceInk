# VoiceInk Design-Charta (Fork yannik/local)

> Nordstern für eigene Änderungen an VoiceInk. Lebendes Dokument: jedes Urteil des Owners wird als
> geschärftes Prinzip, Anti-Muster oder Worked Example mit Datum ergänzt (Gelernt-Log unten).
> Gilt für Flächen, die dieser Fork selbst umbaut; Upstream-Flächen bleiben, wie sie sind.

## Boden und Decke

Die Gesetze (Skill `native-app-design`) und der Preflight sind der Boden. Diese Charta ist die Decke:
VoiceInk soll sich anfühlen wie ein Teil von macOS, nicht wie ein Programm, das sich darüberlegt.

## Die Prinzipien (je mit „nie wieder")

**1. Ein Held pro Fläche.** Beim Diktieren ist das die Stimme: die Welle. Alles andere tritt zurück.
*Nie wieder:* drei gleich laute Elemente in einer 40-pt-Leiste.

**2. Effekte verdienen ihren Platz.** Liquid Glass nur auf schwebendem Chrome (Recorder, Panels),
nie auf Inhaltskarten. Glas über beliebigem Hintergrund braucht eine dunkle Tönung, sonst verliert
weißer Inhalt auf hellen Dokumenten den Kontrast. Auf macOS ignoriert `.regular`-Glas die Tönung
über hellem Grund (auch mit Dark Aqua); dort trägt nur `.clear` mit Tönung. Die Tönung ist so hell,
wie der Inhalt erlaubt, damit das Glas glasig bleibt; eine Lichtkante oben gibt ihm Tiefe und hält
die Kante über dunklen Editoren sichtbar.
*Nie wieder:* ungetöntes Glas mit weißem Inhalt über Weiß.

**3. Eigene Palette, nicht geliehen.** Farben aus `AppTheme` (`DesignSystem/Theme/AppTheme.swift`);
Rot ausschließlich für Aufnahme (`AppTheme.Status.error` = `systemRed`): die laufende Aufnahme und
der Knopf, der sie unter dem Zeiger startet oder stoppt. Ein Zustand ohne Aufnahme trägt kein Rot.
Wo Rot auf Weiß
sitzt (Punkt im Rand, Stopp-Quadrat auf der Hover-Scheibe), wird es um ein Viertel abgedunkelt
(`.mix(with: .black, by: 0.25)`): reines Systemrot erreicht auf Weiß nur 2,8:1.
*Nie wieder:* rohe Hex-Werte, ein zweiter Akzent ohne Bedeutung.

**4. Jeder Zustand ist entworfen.** Bereit, Start, Aufnahme, Transkribieren, Verbessern, Assistent:
jeder Zustand hat eine eigene, ruhige Form in derselben Fläche.
*Nie wieder:* ein Textwechsel, der 100 ms aufblitzt, oder ein Layoutsprung zwischen Zuständen.

**5. Ein Rhythmus über alle Flächen.** 4-pt-Raster, Radien aus `AppTheme.Radius`, Recorder-Leiste
34 pt hoch, Kapselform (Radius 17) auch für ausgeklappte Recorder-Flächen, mit kreisförmigen Ecken:
eine kontinuierliche 17-pt-Ecke wirkt enger als die Kapselenden.
*Nie wieder:* mal Radius 14, mal 20 in derselben Fläche.

**6. Erkennbar VoiceInk.** Die Welle aus runden Balken mit schmaler, linsenförmiger Hüllkurve und der
rote Punkt mit weißem Rand. Die Welle füllt bei lauter Stimme rund zwei Drittel der Leiste; die
Außenbalken bleiben bei rund einem Fünftel der Mitte, sonst liest sie sich als Balkenreihe.
*Nie wieder:* ein austauschbares Mikrofon-Symbol als Held.

## Negativ-Liste (steht in jedem Brief)

- [ ] mehr als eine gefüllte Fläche pro Screen
- [ ] zweiter Akzent-Farbton ohne Semantik
- [ ] Glow, Gradient, Konfetti ohne seltenen Anlass
- [ ] Emoji als Ikonografie
- [ ] Demo- oder Fake-Zahlen in einem Screenshot, der beurteilt wird
- [ ] Sheet mit Loch (Detent größer als Inhalt)
- [ ] Komponente neu gebaut, obwohl eine im Register steht

## Token-Cheatsheet

| Zweck | Token |
|---|---|
| Spacing | 4-pt-Raster (4, 6, 8, 12, 16) |
| Radius | `AppTheme.Radius.card` 12, `.control` 14, `.pill` 22; Recorder: 17 (halbe Leistenhöhe) |
| Farbe | `AppTheme.Status.error` für Aufnahme, sonst `.primary`/`.secondary` bzw. Weiß auf dunklem Glas |
| Typo | Systemschrift, 11 bis 12 pt in schwebenden Panels |
| Surface | macOS 26+: `glassEffect(.clear.tint(.black.opacity(0.38)))` für Leiste und Live-Text, `0.66` für den Assistenten (`RecorderGlassTint`), dazu eine Lichtkante als Verlauf (Weiß 55 % oben, 8 % Mitte, 22 % unten, 1 pt); darunter `NSVisualEffectView(.hudWindow)`. Über Weiß muss der schwächste Inhalt halten: Welle und Punkt 3:1, Live-Text 4,5:1; die helleren Chat-Blasen brauchen die dunklere Tönung |
| Motion | Jede Bewegung nennt ihre Frequenzklasse. Recorder (Dutzende pro Tag): Erscheinen unter 150 ms, Verschwinden schneller; Ausklappen und Wachsen des Assistenten 150 ms, Text nach 60 ms in 80 ms, Einklappen 60 ms, neue Nachrichten blenden in 150 ms. Schleifen nur, solange die App arbeitet (Schimmer 1,05 s, Atmen 1,6 s). Reduce Motion: keine Skalierung, keine Größenanimation, Schleifen nur über Helligkeit; eine Blende bleibt als Rückfallebene |
| Runde Knöpfe | `RecorderRoundButton`: 21-pt-Scheibe, Weiß 13 %, Rand Weiß 18 % bei 0,6 pt, Symbol 9 pt semibold Weiß 86 %; aktiv (Senden): Weiß 88 % mit dunklem Symbol. Gilt für Schließen, Kopieren und Senden |
| Trefferfläche | 28 × 28 pt für Knöpfe im Recorder |

## Der Test vor „fertig"

1. Genau ein Held? 2. Jede Farbe und Größe aus einem Token? 3. Alle Zustände gestaltet?
4. Auf weißem Dokument, dunklem Editor und buntem Hintergrund gleich gut lesbar?

## Gelernt-Log

- 2026-09-28: Yannik wählt für den Mini-Recorder Variante B „Minimal: nur Punkt + Welle" aus drei
  gerenderten Konzepten (A getöntes Glas mit Modus-Symbol, C schwarzes Glas). → Prinzip 1:
  im Recorder so wenig Chrome wie möglich; Modus wechselt über Menüleiste und Tastenkürzel.
- 2026-09-28: Glasprüfung auf macOS 26 mit echter Renderung über weißem Dokument, dunklem Editor
  und buntem Hintergrund. Daraus stammen die Regeln zu `.clear` mit Tönung und zur Lichtkante
  (Prinzip 2) sowie die hellere Tönung 0,38 für Leiste und Live-Text (Commit dad40b5).
  Der Wortlaut dieses Eintrags ist rekonstruiert: Die Quelle endete mitten im Satz.
- 2026-11-04: Charta aus geretteten Sitzungsprotokollen wiederhergestellt, nachdem der Quellordner
  verloren ging. Prinzipien, Negativ-Liste und Token-Tabelle sind wörtlich erhalten. Spätere
  Einträge im Gelernt-Log nach dem 28.09. sind nicht erhalten.
