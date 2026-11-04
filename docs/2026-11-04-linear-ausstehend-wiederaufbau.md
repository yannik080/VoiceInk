# Linear ausstehend: VoiceInk-Wiederaufbau und Live-stumm (04.11.2026)

> Der Vorgang konnte wegen des Free-Limits des Workspaces nicht angelegt werden. Diese Datei sichert
> den Schreibwunsch: Projekt VoiceInk, Label Feature, Status In Progress, Hauptsitzung
> t3-thread://v1/2d25485c-cbca-4765-8212-0b60deecd4a9. Nach Freigabe des Limits einmal nachtragen.

## Auftrag (Yannik, 03./04.11.2026, Chat)

> Wenn ich manchmal zum Beispiel Livestreams gucke oder Fußball oder sowas, was halt Live-Sachen sind, ist es so, dass wenn ich rede, dass pausiert wird und dann nicht mehr live ist. Ich finde, bei Live sollte es nicht pausiert werden, sondern einfach stumm sein. […] Und dass es bei normalen Videos und normaler Musik trotzdem stoppt, dass es die Einstellung gibt.

Danach: „und wie bekommen wir die sachen zurück“ → Entscheidung: **Wiederaufbau starten**.

## Ausgangslage

Der Quellcode des installierten Eigenbuilds (2.20/220) lag in `~/orca/workspaces/localflow/local/repos/VoiceInk` und wurde bei der Mac-Aufräumaktion 22.–25.10.2026 gelöscht (Sicherung schloss `repos/` aus, kein Time Machine). Alle Commits ab 28.09. waren nie gepusht. GitHub `yannik080/VoiceInk` hat nur `yannik/local` vom 27.09. (`adc83fa`).

Verlorene Commits (aus T3-Verlauf belegt): `846eccc`/`dad40b5` Glass-Recorder (YAN-257), `8ff73d5` Wispr-Kurzbefehl (YAN-263), `aa34dfb`/`f9db8e5`/`7f99b16`/`8e04a85` Sounds (YAN-269), `7bd9dea`/`685536d`/`f1626d4` Droppy Island, `12444d5`/`72a025c` Enhancement ohne Doppelschleife, `58899e0` Cerebras-Ersatz, `ba29b1f`/`15ede83`/`1c233ad` Auto-Learn + Medienpause + Schriftvorgabe (YAN-323), `2cc0a53` Doppeltipp-Fix (YAN-263), `9e444ec` Wiederholungs-Fix (YAN-431).

## Rettbare Quellen

* Referenz-App gesichert: `~/Library/Application Support/VoiceInk Local Backups/2026-11-04-referenz-vor-wiederaufbau/` (Binary bitgleich mit /Applications).
* Sound-Dateien im App-Paket.
* T3-Datenbank: vollständige Dateistände vom 08.10. (Auto-Learn-Dateien, VoiceInkEngine.swift u. a.), Befehlsausgaben 08.10./16.10./21.10.
* Codex-Verlauf 21.10. mit apply_patch des Wiederholungs-Fixes.
* Doku `EIGENER_BUILD.md` und Notizen im Patch `~/Developer/_worktree-backups/code-reste-2026-10-25/localflow__local.patch`, Linear-Kommentare der Einzelvorgänge.

## Umfang

1. Neue Arbeitskopie `~/Developer/VoiceInk`, Branch `yannik/wiederaufbau` auf `yannik/local`; jeder Schritt wird committet **und nach GitHub gepusht**.
2. Gerettete Teile einspielen, verlorene Funktionen nach Doku und Referenz-App nachbauen.
3. Neu: Medienpause unterscheidet Live-Inhalte (stumm statt pausieren), eigene Einstellung.
4. Build, Sicherung, Installation erst nach Abnahme durch Yannik.

## Abnahmekriterien

* Jede Funktion aus der Liste oben verhält sich wie in `EIGENER_BUILD.md` und den Linear-Abschlüssen beschrieben; bestehende Logiktests wieder vorhanden und grün.
* Live-Inhalt beim Diktieren: stumm, nicht pausiert, danach wieder hörbar; normale Videos/Musik weiter pausiert; Einstellung schaltbar.
* Nutzerdaten, Einstellungen, Schlüssel und Signatur (Team V6XHQ49B57) unverändert übernommen.
* Code vollständig auf GitHub.

## Fortschritt

* 11fe77a Glass recorder: live text and answer height follow their content, readable spinner
* 3c4cb45 Rebuild the Liquid Glass mini recorder from the design charter
* eb1f18c Restore Latin script hint for Parakeet v3 in automatic language mode
* eb32e34 Restore robust media pause; mute live streams instead of pausing
* b6a9d5e Restore Wispr Flow style hybrid shortcut and double-tap fix
* 2e937e2 Restore recording sound pairs with Deep Solid Button as default

Noch offen: KI-Verbesserungskette (12444d5/72a025c/58899e0/9e444ec) und Auto-Learn (YAN-323) laufen als Worker; danach Integrations-Build, Checks, unabhängige Prüfung, Abnahme durch Yannik, Installation mit Sicherung.
