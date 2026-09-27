# Eigener VoiceInk-Build

Dieser Fork verwendet den offiziellen `LOCAL_BUILD`-Weg. Es ist kein gekaufter
VoiceInk-Lizenzschlüssel erforderlich. Die GPLv3 und die Hinweise des Originals gelten
weiterhin. Produktname und Release-Bundle-ID bleiben für vorhandene Benutzerdaten erhalten.

## Repository

- Eigener Fork: https://github.com/yannik080/VoiceInk
- `origin`: eigener Fork
- `upstream`: https://github.com/Beingpax/VoiceInk
- Arbeitsbranch: `yannik/local`
- Ausgangsstand: `5fd71515089f54a2698cda8ec0013b9cd0b3e417` (VoiceInk 2.20)

## Bauen

```sh
make local
```

Siehe [BUILDING.md](BUILDING.md) für Voraussetzungen und Signierung. Der Build liegt
anschließend in `~/Downloads/VoiceInk.app` und `.local-build/Build/Products/Release/VoiceInk.app`.
Wenn mehrere Apple-Development-Zertifikate vorhanden sind, immer dieselbe Identität
über `LOCAL_CODESIGN_IDENTITY` auswählen. Der erste Aufruf baut außerdem whisper.cpp;
weitere Aufrufe verwenden dessen vorhandenes XCFramework.

`LocalBuild.xcconfig` legt absichtlich keine Signierungsidentität fest: Xcodes
`-xcconfig` hat Vorrang vor dem Kommandozeilenwert. Der Makefile-Wert muss wirksam
bleiben, damit spätere Builds mit derselben Identität ihre Berechtigungen behalten.

Falls Xcode die Metal Toolchain vermisst: `xcodebuild -downloadComponent MetalToolchain`.

Zum Installieren zuerst VoiceInk regulär beenden, die bisherige App und ihre Daten
sichern, dann die neue App nach `/Applications/VoiceInk.app` kopieren. Die Download-
und Programme-Kopie nicht gleichzeitig starten. Die Release-Bundle-ID ist
`com.prakashjoshipax.VoiceInk`; `make dev` verwendet dagegen eine andere Preferences-Domain.

## Erhaltene Daten und Grenzen

- Einstellungen: `~/Library/Preferences/com.prakashjoshipax.VoiceInk.plist`
- Verlauf, Wörterbuch und Statistik: `~/Library/Application Support/com.prakashjoshipax.VoiceInk/`
- Eigene Sounds: `~/Library/Application Support/VoiceInk/`
- FluidAudio-Modelle: `~/Library/Application Support/FluidAudio/`

Diese Ordner gehören nicht in Git. Die App muss während einer vollständigen Sicherung
beendet sein; SQLite-WAL-Dateien gegebenenfalls zusammen mit den Datenbanken sichern.

API-Schlüssel des offiziellen Builds liegen im Data-Protection-Keychain. Eigenbuilds
verwenden den separaten Login-Keychain-Dienst `com.prakashjoshipax.VoiceInk.Local`.
Der Einstellungen-Export enthält keine API-Schlüssel. Beim ersten Wechsel können sie
erneut direkt in der App eingegeben werden müssen; vorhandene offizielle Schlüssel
werden nicht gelöscht. Schlüssel niemals in Git, Build-Logs oder Dokumentation schreiben.

Der lokale Build hat keine automatischen Updates und keinen iCloud-Wörterbuch-Sync.
Dieser Fork deaktiviert dafür die Initialisierung und Update-Aktionen von Sparkle bei
`LOCAL_BUILD`; eine gespeicherte Update-Präferenz der offiziellen App bleibt erhalten.
Der Regressionstest läuft nach dem Auflösen der Pakete mit
`bash scripts/check-local-updater.sh` in einer getrennten Preferences-Domain.
Neue Upstream-Stände bewusst prüfen und in den Arbeitsbranch übernehmen. Nach einem
Wechsel der Signierungsidentität kann macOS Mikrofon-, Bedienungshilfe- oder
Bildschirmaufnahme-Berechtigungen erneut verlangen.

Private Änderungen dürfen privat bleiben. Bei Weitergabe der App gelten die
Quellcode- und Lizenzpflichten der GPLv3. Der Fork ist kein offizieller VoiceInk-Release.

## Wenn macOS trotz eingeschaltetem Schalter den Zugriff verweigert

Beim Wechsel von der offiziellen App zum Eigenbuild kann macOS die alte
Signierungsanforderung im Berechtigungseintrag behalten. Einfaches Aus-/Einschalten
genügt dann nicht. Der konkrete Nachweis ist ein `tccd`-Log mit
`SecStaticCodeCheckValidity` / `status: -67050`, das weiterhin das Hersteller-Team
anstatt der eigenen Signatur verlangt. Erst App-Pfad und Signatur prüfen; nicht bei
jedem Fehler pauschal Berechtigungen zurücksetzen.

Wenn dieser Fall bestätigt ist: VoiceInk vollständig beenden und nur die betroffenen
Berechtigungen dieser App zurücksetzen, beispielsweise:

```sh
tccutil reset Accessibility com.prakashjoshipax.VoiceInk
tccutil reset Microphone com.prakashjoshipax.VoiceInk
```

Danach `/Applications/VoiceInk.app` öffnen und die Freigaben in macOS erneut durch
den Benutzer erteilen lassen. VoiceInk anschließend einmal neu starten, damit die
globalen Tastenkürzel mit der neuen Freigabe registriert werden. Den fehlenden
Bedienungshilfen-Hinweis sowie Aufnahme und Einfügen wirklich prüfen.

Diese Befehle löschen weder Einstellungen noch Modelle, Transkriptionen oder
API-Schlüssel. Sie setzen keine Berechtigungen anderer Apps zurück. Ein Wechsel
zurück zum Hersteller-Build kann eine erneute Freigabe erforderlich machen.
