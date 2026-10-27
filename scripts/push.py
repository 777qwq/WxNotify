"""把本地改动以【单个提交】推到 GitHub，触发一次 Actions 构建。

走 Git Data API：blobs -> tree(base_tree) -> commit -> 更新 ref，
一次推送只有一个提交，也只跑一次 macos 构建。
仓库不存在时会自动新建（公开）。

用法（仓库根目录）：python3 scripts/push.py
"""
import base64
import json
import urllib.error
import time
import urllib.request

TOK = open('/mnt/data/catpaw/home/.meituan-catpaw/2973599039/.ghtok').read().strip()
OWNER, REPO = '777qwq', 'WxNotify'
BRANCH = 'main'
API = 'https://api.github.com'

FILES = [
    ('src/WxNotify.m', 'src/WxNotify.m'),
    ('src/WxNotify.plist', 'src/WxNotify.plist'),
    ('.github/workflows/build.yml', '.github/workflows/build.yml'),
    ('scripts/package.py', 'scripts/package.py'),
    ('scripts/push.py', 'scripts/push.py'),
    ('scripts/fetch.py', 'scripts/fetch.py'),
    ('scripts/upload_wss.py', 'scripts/upload_wss.py'),
    ('README.md', 'README.md'),
    ('.gitignore', '.gitignore'),
    ('build/DEBIAN/control', 'build/DEBIAN/control'),
    ('build/DEBIAN/postinst', 'build/DEBIAN/postinst'),
]


def req(path, method='GET', data=None):
    body = json.dumps(data).encode() if data is not None else None
    r = urllib.request.Request(API + path, data=body, method=method, headers={
        'Authorization': 'Bearer ' + TOK, 'Accept': 'application/vnd.github+json',
        'Content-Type': 'application/json', 'User-Agent': 'catpaw'})
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            return resp.status, json.loads(resp.read() or b'{}')
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b'{}')


def ensure_repo():
    st, d = req(f'/repos/{OWNER}/{REPO}')
    if st == 200:
        print('仓库已存在', d['full_name'], 'private=', d['private'])
        return
    st, d = req('/user/repos', 'POST', {
        'name': REPO,
        'description': '微信后台通知补发：给被 Immortalizer 保活的微信补回横幅',
        'private': False,
        'has_issues': False,
        'has_wiki': False,
    })
    if st not in (200, 201):
        raise SystemExit(f'建仓失败 {st}: {d.get("message")}')
    print('已新建仓库', d['full_name'])


def main():
    ensure_repo()

    st, ref = req(f'/repos/{OWNER}/{REPO}/git/ref/heads/{BRANCH}')
    if st in (404, 409):
        # 空仓库（GitHub 对空库的 Git Data 接口一律 409），先用 Contents API 塞一个
        # 占位 README 把仓库初始化出来，后面照常走原子提交
        print('仓库为空，先初始化')
        st0, d0 = req(f'/repos/{OWNER}/{REPO}/contents/README.md', 'PUT', {
            'message': 'init', 'content': base64.b64encode(b'# WxNotify\n').decode()})
        if st0 not in (200, 201):
            raise SystemExit(f'初始化失败 {st0}: {d0.get("message")}')
        time.sleep(1)
        st, ref = req(f'/repos/{OWNER}/{REPO}/git/ref/heads/{BRANCH}')
    if st == 200:
        parent = ref['object']['sha']
        st2, commit = req(f'/repos/{OWNER}/{REPO}/git/commits/{parent}')
        if st2 != 200:
            raise SystemExit(f'取 commit 失败 {st2}: {commit.get("message")}')
        base_tree = commit['tree']['sha']
        print('当前 HEAD', parent[:8], 'tree', base_tree[:8])
    else:
        raise SystemExit(f'取 ref 失败 {st}: {ref.get("message")}')

    entries = []
    for dst, src in FILES:
        raw = open(src, 'rb').read()
        st, blob = req(f'/repos/{OWNER}/{REPO}/git/blobs', 'POST',
                       {'content': base64.b64encode(raw).decode(), 'encoding': 'base64'})
        if st not in (200, 201):
            raise SystemExit(f'建 blob 失败 {dst} {st}: {blob.get("message")}')
        entries.append({'path': dst, 'mode': '100644', 'type': 'blob', 'sha': blob['sha']})
        print('  blob', dst, len(raw))

    tree_body = {'tree': entries}
    if base_tree:
        tree_body['base_tree'] = base_tree
    st, tree = req(f'/repos/{OWNER}/{REPO}/git/trees', 'POST', tree_body)
    if st not in (200, 201):
        raise SystemExit(f'建 tree 失败 {st}: {tree.get("message")}')

    body = {'message': 'WxNotify: 微信保活状态下补发后台通知', 'tree': tree['sha']}
    if parent:
        body['parents'] = [parent]
    st, nc = req(f'/repos/{OWNER}/{REPO}/git/commits', 'POST', body)
    if st not in (200, 201):
        raise SystemExit(f'建 commit 失败 {st}: {nc.get("message")}')
    print('新提交', nc['sha'][:8])

    if parent:
        st, upd = req(f'/repos/{OWNER}/{REPO}/git/refs/heads/{BRANCH}', 'PATCH',
                      {'sha': nc['sha'], 'force': False})
    else:
        st, upd = req(f'/repos/{OWNER}/{REPO}/git/refs', 'POST',
                      {'ref': 'refs/heads/' + BRANCH, 'sha': nc['sha']})
    if st not in (200, 201):
        raise SystemExit(f'更新 ref 失败 {st}: {upd.get("message")}')
    print('已推送 ->', BRANCH, nc['sha'][:8])


if __name__ == '__main__':
    main()
