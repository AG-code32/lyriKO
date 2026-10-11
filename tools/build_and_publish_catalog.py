#!/usr/bin/env python3
"""Run on macOS. Downloads all Windows-server MP3s, builds ShazamKit catalog and publishes it."""
import json, os, pathlib, subprocess, sys, tempfile, urllib.request, urllib.parse

BASE = os.environ.get('LYRIKO_SERVER_URL', '').rstrip('/')
TOKEN = os.environ.get('LYRIKO_SERVER_TOKEN', '')
if not BASE or not TOKEN:
    sys.exit('Set LYRIKO_SERVER_URL and LYRIKO_SERVER_TOKEN before running.')

def request(path, method='GET', data=None):
    req = urllib.request.Request(BASE + path, data=data, method=method,
                                 headers={'Authorization': 'Bearer ' + TOKEN})
    return urllib.request.urlopen(req, timeout=120).read()

songs = json.loads(request('/api/songs'))['songs']
script_dir = pathlib.Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='lyriko_catalog_') as folder:
    directory = pathlib.Path(folder)
    manifest = []
    for song in songs:
        if not song.get('audioAvailable'): continue
        song_id = str(song['id'])
        access = json.loads(request('/api/songs/' + urllib.parse.quote(song_id) + '/audio-access'))
        audio_url = access['url']
        if not audio_url.startswith('/api/songs/'):
            sys.exit('Server returned an unexpected audio URL')
        content = request(audio_url)
        filename = song_id + '.mp3'
        (directory / filename).write_bytes(content)
        manifest.append({'file': filename, 'title': song['title'], 'artist': song['artist']})
        print('Downloaded:', song['artist'], '-', song['title'], flush=True)
    if not manifest: sys.exit('No MP3 files available in Windows server')
    manifest_path = directory / 'songs.json'
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False), encoding='utf-8')
    output = directory / 'lyriko.shazamcatalog'
    executable = directory / 'catalog_builder'
    subprocess.run(['swiftc', '-parse-as-library', str(script_dir / 'generate_catalog.swift'), '-o', str(executable)], check=True)
    subprocess.run([str(executable), str(manifest_path), str(output)], check=True)
    data = output.read_bytes()
    result = json.loads(request('/api/catalog/shazam', method='PUT', data=data))
    print('PUBLISHED:', result)
    print('Songs:', len(manifest))
