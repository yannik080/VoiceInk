#!/usr/bin/env bash
# Prüft die eingebauten Aufnahme-Töne: jede Auswahl findet ihre Datei(en), Rand-Samples still,
# Spitze unter -1 dBFS, 48 kHz, höchstens 0,45 s (Paare). Wiederhergestellt 04.11.2026.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import math, re, struct, sys
from pathlib import Path
src = Path('VoiceInk/Infrastructure/Audio/CustomSoundManager.swift').read_text()
body = src[src.index('enum BuiltInSound'):src.index('enum SoundType')]
cases = []
for m in re.finditer(r'^\s*case (\w+)(?: = "([^"]+)")?\s*$', body, re.M):
    cases.append(m.group(2) or m.group(1))
paired = re.search(r'pairedSounds: \[BuiltInSound\] = \[(.*?)\]', body, re.S).group(1)
paired_names = {c.strip().lstrip('.') for c in paired.split(',') if c.strip()}
case_by_ident = {m.group(1): (m.group(2) or m.group(1)) for m in re.finditer(r'^\s*case (\w+)(?: = "([^"]+)")?\s*$', body, re.M)}
paired_raw = {case_by_ident[n] for n in paired_names}
sounds = Path('VoiceInk/Resources/Sounds')
fails = 0; checked = 0
def read_wav(path):
    b = path.read_bytes(); assert b[:4] == b'RIFF' and b[8:12] == b'WAVE', path
    i = 12; fmt = data = None
    while i + 8 <= len(b):
        cid, size = b[i:i+4], struct.unpack('<I', b[i+4:i+8])[0]
        chunk = b[i+8:i+8+size]
        if cid == b'fmt ': fmt = chunk
        elif cid == b'data': data = chunk
        i += 8 + size + (size & 1)
    ch, sr = struct.unpack('<HI', fmt[2:8]); bits = struct.unpack('<H', fmt[14:16])[0]; sw = bits // 8
    vals = [int.from_bytes(data[k:k+sw], 'little', signed=True) for k in range(0, len(data) - sw + 1, sw)]
    return sr, ch, sw, vals
def fail(msg):
    global fails; fails += 1; print('FAIL', msg)
for raw in cases:
    if raw in paired_raw:
        for t in ('start', 'stop'):
            f = sounds / f'{raw}-{t}.wav'
            if not f.exists(): fail(f'{f} fehlt'); continue
            sr, ch, sw, s = read_wav(f)
            n = len(s) // ch
            full = float(1 << (sw*8 - 1))
            peak = max(abs(x) for x in s) / full
            dbfs = 20*math.log10(peak) if peak else -999
            dur = n / sr
            if sr != 48000: fail(f'{f.name}: {sr} Hz')
            if dur > 0.45: fail(f'{f.name}: {dur:.3f} s')
            if dbfs >= -1.0: fail(f'{f.name}: Spitze {dbfs:.2f} dBFS')
            edge = max(abs(x) for x in s[:ch] + s[-ch:]) / full
            if edge > 0.001: fail(f'{f.name}: Rand nicht still ({edge:.4f})')
            checked += 1
    else:
        if not any((sounds / f'{raw}.{e}').exists() for e in ('wav', 'mp3')): fail(f'{raw}: Datei fehlt')
        checked += 1
default = re.search(r'case \.start, \.stop:\s*return \.(\w+)', src)
if not default or case_by_ident.get(default.group(1)) != 'button-deep-solid': fail('Standard ist nicht Knopf tief satt')
print(f'{checked} Klangdateien geprüft, {fails} Fehler')
sys.exit(1 if fails else 0)
PY
