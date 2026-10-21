"""Publish this verified beta by release ID, including a still-untagged draft."""
import hashlib
import json
import mimetypes
import os
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request

repo = os.environ['GH_REPO']
tag = os.environ['RELEASE_TAG']
commit = os.environ['APP_COMMIT']
release_id = 420006589
headers = {
    'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
}


def request(path, *, method='GET', payload=None, upload=None):
    base = 'https://uploads.github.com/' if upload else 'https://api.github.com/'
    data = upload.read_bytes() if upload else None
    current_headers = dict(headers)
    if upload:
        current_headers['Content-Type'] = mimetypes.guess_type(upload.name)[0] or 'application/octet-stream'
    elif payload is not None:
        data = json.dumps(payload).encode()
        current_headers['Content-Type'] = 'application/json'
    call = urllib.request.Request(base + path, data=data, headers=current_headers, method=method)
    try:
        with urllib.request.urlopen(call, timeout=180) as response:
            body = response.read()
            return json.loads(body) if body else None
    except urllib.error.HTTPError as error:
        # Never log request headers, credentials, or redirected download URLs.
        raise SystemExit(f'GitHub release request failed: HTTP {error.code}') from None


release_path = f'repos/{repo}/releases/{release_id}'
release = request(release_path)
assert release['tag_name'] == tag
assert release['target_commitish'] == commit, 'Unexpected app source'
assets = sorted(Path('release-assets').iterdir())
assert {p.name for p in assets} == {
    'Gnarly-57-Continuity.ipa', 'Gnarly-Icon.png', 'INSTALAR.md', 'SHA256SUMS.txt', 'source.json'
}


def verify_assets(remote):
    by_name = {item['name']: item for item in remote['assets']}
    for file in assets:
        item = by_name[file.name]
        assert item['size'] == file.stat().st_size, file.name
        digest = 'sha256:' + hashlib.file_digest(file.open('rb'), 'sha256').hexdigest()
        assert item.get('digest') in (None, digest), file.name


if release['draft']:
    existing = {item['name']: item for item in release['assets']}
    for file in assets:
        if file.name in existing:
            request(f'repos/{repo}/releases/assets/{existing[file.name]["id"]}', method='DELETE')
        path = release_path + '/assets?name=' + urllib.parse.quote(file.name, safe='')
        uploaded = request(path, method='POST', upload=file)
        assert uploaded['size'] == file.stat().st_size
        print('Uploaded', file.name, uploaded['size'], 'bytes', flush=True)
    verify_assets(request(release_path))
    release = request(release_path, method='PATCH', payload={
        'draft': False,
        'prerelease': True,
        'name': 'Gnarly 57 — beta para LiveContainer',
        'body': Path('distribution/livecontainer/RELEASE-NOTES.md').read_text(),
        'target_commitish': commit,
    })

assert not release['draft'] and release['prerelease']
verify_assets(request(release_path))
ref = request(f'repos/{repo}/git/ref/tags/{tag}')['object']
if ref['type'] == 'tag':
    ref = request(f'repos/{repo}/git/tags/{ref["sha"]}')['object']
assert ref['sha'] == commit, 'Published tag points at a different app'
print('Published and verified:', release['html_url'])
