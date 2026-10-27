#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""等待 GitHub Actions 构建完成并下载 dylib 产物到 out/。"""
import io
import json
import os
import sys
import time
import urllib.error
import urllib.request
import zipfile

TOK = open('/mnt/data/catpaw/home/.meituan-catpaw/2973599039/.ghtok').read().strip()
OWNER, REPO = '777qwq', 'WxNotify'
API = 'https://api.github.com'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'out')
os.makedirs(OUT, exist_ok=True)


def api(path):
    req = urllib.request.Request(API + path, headers={
        'Authorization': 'Bearer ' + TOK,
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'catpaw',
    })
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read() or b'{}')


SHA_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '.last_sha')


def want_sha():
    """要等的是哪一次提交：命令行 --sha 优先，其次 push.py 落下的 .last_sha。"""
    if '--sha' in sys.argv:
        return sys.argv[sys.argv.index('--sha') + 1]
    if os.path.exists(SHA_FILE):
        return open(SHA_FILE).read().strip() or None
    return None


def latest_run(sha=None):
    runs = api(f'/repos/{OWNER}/{REPO}/actions/workflows/build.yml/runs?per_page=10')['workflow_runs']
    if sha:
        # 只认这次提交对应的 run。以前按 id 取最新，push 完 run 还没建出来时
        # 会拿到上一次的旧产物（2.12 就这么被打成了 2.11）
        runs = [r for r in runs if r['head_sha'] == sha]
    runs.sort(key=lambda r: r['id'], reverse=True)
    return runs[0] if runs else None


def wait_run(timeout=1200, sha=None):
    t0 = time.time()
    while time.time() - t0 < timeout:
        r = latest_run(sha)
        if r:
            print('run', r['id'], r['head_sha'][:8], r['status'], r.get('conclusion'),
                  r['head_commit']['message'][:40], flush=True)
            if r['status'] == 'completed':
                return r
        else:
            print('等这次提交的 run 出现…', flush=True)
        time.sleep(10)
    raise SystemExit('timeout waiting for run')


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def artifact_zip(aid):
    """302 到 blob 存储后不能再带 Authorization，否则 401。"""
    opener = urllib.request.build_opener(_NoRedirect)
    req = urllib.request.Request(
        f'{API}/repos/{OWNER}/{REPO}/actions/artifacts/{aid}/zip',
        headers={'Authorization': 'Bearer ' + TOK, 'User-Agent': 'catpaw'})
    try:
        loc = opener.open(req, timeout=120).headers.get('Location')
    except urllib.error.HTTPError as e:
        if e.code not in (301, 302, 303, 307, 308):
            raise
        loc = e.headers.get('Location')
    if not loc:
        raise SystemExit('no redirect location for artifact zip')
    req2 = urllib.request.Request(loc, headers={'User-Agent': 'catpaw'})
    with urllib.request.urlopen(req2, timeout=300) as r:
        return r.read()


def download(run_id):
    arts = api(f'/repos/{OWNER}/{REPO}/actions/runs/{run_id}/artifacts')['artifacts']
    for a in arts:
        print('artifact', a['name'], a.get('size_in_bytes'))
    target = next((a for a in arts if a['name'] == 'dylib'), None)
    if not target:
        raise SystemExit('no dylib artifact')
    z = zipfile.ZipFile(io.BytesIO(artifact_zip(target['id'])))
    for n in z.namelist():
        dest = os.path.join(OUT, os.path.basename(n))
        data = z.read(n)
        with open(dest, 'wb') as f:
            f.write(data)
        print('saved', os.path.relpath(dest), len(data))


if __name__ == '__main__':
    r = wait_run(sha=want_sha())
    print('conclusion:', r.get('conclusion'))
    if r.get('conclusion') != 'success':
        raise SystemExit('build failed: %s' % r.get('conclusion'))
    download(r['id'])
