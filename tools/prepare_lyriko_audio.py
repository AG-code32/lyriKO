#!/usr/bin/env python3
"""Prepare all 9 existing Lyriko lyric JSON tracks for local iPhone development.
Usage: python3 tools/prepare_lyriko_audio.py '/path/to/MP3s'
Only use audio you are entitled to use. Do not commit or distribute commercial MP3s.
"""
import json, pathlib, re, shutil, subprocess, sys, struct

if len(sys.argv) != 2:
    sys.exit('Usage: python3 tools/prepare_lyriko_audio.py "/path/to/MP3s"')
source = pathlib.Path(sys.argv[1]).expanduser()
project = pathlib.Path(__file__).resolve().parents[1]
lyrics = project / 'assets' / 'lyrics'
audio_dest = project / 'assets' / 'audio'
audio_dest.mkdir(parents=True, exist_ok=True)
if not source.is_dir(): sys.exit(f'Audio directory not found: {source}')
if not lyrics.is_dir(): sys.exit(f'Lyrics directory not found: {lyrics}')
if shutil.which('ffmpeg') is None: sys.exit('Missing ffmpeg: install it with brew install ffmpeg')

def key(value):
    return re.sub(r'[^a-z0-9]+', '', value.lower().replace('(o)', 'o'))

tracks = sorted(lyrics.glob('Avenged Sevenfold - *.json'))
tracks = [x for x in tracks if not x.name.endswith('.waveform.json')]
files = [p for p in source.rglob('*') if p.is_file() and p.suffix.lower() in {'.mp3','.m4a','.wav','.flac','.aac'}]
missing = []
for lyric in tracks:
    title = lyric.stem.split(' - ', 1)[1]
    target_key = key(title)
    # Remove optional album track numbers (e.g. '08. G.mp3') before matching.
    def clean_stem(path):
        return re.sub(r'^\d{1,3}\s*[.\-_ ]+\s*', '', path.stem)

    exact = [p for p in files if key(clean_stem(p)) == target_key]
    # Use legacy suffix matching only for descriptive titles, never 1-letter titles.
    candidates = exact if exact else ([p for p in files if key(p.stem).endswith(target_key)] if len(target_key) >= 4 else [])
    if len(candidates) != 1:
        print(f'NOT FOUND or ambiguous: {title} ({len(candidates)} matches)')
        missing.append(title)
        continue
    original = candidates[0]
    mp3 = audio_dest / (lyric.stem + '.mp3')
    if original.suffix.lower() == '.mp3':
        shutil.copy2(original, mp3)
    else:
        subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-i',str(original),'-vn','-codec:a','libmp3lame','-qscale:a','3',str(mp3)],check=True)
    waveform = lyric.with_suffix('.waveform.json')
    if not waveform.is_file():
        decoded = subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-i',str(original),'-vn','-ac','1','-ar','8000','-f','s16le','-acodec','pcm_s16le','pipe:1'], capture_output=True,check=True).stdout
        points = 5000
        total = len(decoded)//2
        bucket_size = max(1,(total+points-1)//points)
        peaks=[]
        for start in range(0,total,bucket_size):
            chunk=decoded[start*2:min(total,start+bucket_size)*2]
            peaks.append(min(1.0,max((abs(x) for (x,) in struct.iter_unpack('<h',chunk)),default=0)/32768.0))
        waveform.write_text(json.dumps({'version':1,'samples':peaks},separators=(',',':')),encoding='utf-8')
        print(f'GENERATED waveform: {title}')
    else:
        print(f'EXISTING waveform: {title}')
    print(f'PREPARED audio: {mp3.name}')
print(f'\nPrepared {len(tracks)-len(missing)}/{len(tracks)} songs.')
if missing: print('Missing:',', '.join(missing))
print('Now run: flutter pub get && flutter analyze lib/screens/lyrics_edit_screen.dart lib/services/waveform_cache_service.dart')
