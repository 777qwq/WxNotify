# -*- coding: utf-8 -*-
"""把 deb 上传到文叔叔(wenshushu.cn)并取回分享链接。

用法: python3 scripts/upload_wss.py dist/cn.qwq.wxnotify_1.0_iphoneos-arm64.deb

踩过的坑:
  - 文叔叔是 Vue3 页面，没有 __vue__，只能用 DOM。
  - 选文件按钮点开后才会动态创建 input[type=file]；PAW 自带的 upload 动作对这种
    隐藏 input 无效（uploaded: 0），必须在页面里用 atob + DataTransfer 自己组装 File
    再派发 input/change 事件。
  - evaluate 的脚本不能顶层写 return，要包在 IIFE 里。
  - 读分享弹窗时必须拿完整 innerText，截断会导致链接尾部丢失、对方点开「文件不存在」。
"""
import base64
import json
import os
import re
import subprocess
import sys
import time

DEB = sys.argv[1] if len(sys.argv) > 1 else 'dist/cn.qwq.wxnotify_1.0_iphoneos-arm64.deb'


def paw(payload):
    r = subprocess.run(['paw', 'browser-action', json.dumps(payload)],
                       capture_output=True, text=True, timeout=300)
    out = (r.stdout or '') + (r.stderr or '')
    try:
        return json.loads(out[out.index('{'):]).get('data', {})
    except Exception:
        return {}


def evaluate(script):
    d = paw({'action': 'evaluate', 'script': script})
    v = d.get('result')
    if isinstance(v, str):
        try:
            return json.loads(v)
        except Exception:
            return v
    return v


def click_text(text, tag='div,span,button,a,p'):
    js = ("(function(){var all=[].slice.call(document.querySelectorAll('%s'));"
          "var hit=all.filter(function(e){return e.textContent.trim()==='%s';});"
          "if(!hit.length)return JSON.stringify({ok:false});"
          "var el=hit[hit.length-1];el.click();"
          "return JSON.stringify({ok:true,tag:el.tagName});})()" % (tag, text))
    return evaluate(js)


data = open(DEB, 'rb').read()
b64 = base64.b64encode(data).decode()
CH = 16000
chunks = [b64[i:i + CH] for i in range(0, len(b64), CH)]
print('deb %d bytes, b64 %d, %d chunks' % (len(data), len(b64), len(chunks)))

# 1. 打开文叔叔
paw({'action': 'navigate', 'url': 'https://www.wenshushu.cn/', 'waitUntil': 'networkidle'})
time.sleep(2)

# 2. 点「单个、多个文件」，页面才会生成 input[type=file]
print('pick:', click_text('单个、多个文件'))
time.sleep(1)
print('inputs:', evaluate("(function(){return JSON.stringify({n:document.querySelectorAll('input[type=file]').length});})()"))

# 3. 分块写入 localStorage
for i, c in enumerate(chunks):
    paw({'action': 'storage_set', 'key': '_z%d' % i, 'value': c})

# 4. 在页面里组装 File 并触发 change
name = os.path.basename(DEB)
script = (
    "(function(){var b64='';"
    + "".join("b64+=localStorage.getItem('_z%d');" % i for i in range(len(chunks)))
    + "var bin=atob(b64);var arr=new Uint8Array(bin.length);"
      "for(var i=0;i<bin.length;i++)arr[i]=bin.charCodeAt(i);"
      "var f=new File([arr],'%s',{type:'application/vnd.debian.binary-package'});"
      "var dt=new DataTransfer();dt.items.add(f);"
      "var inp=document.querySelector('input[type=file]');"
      "if(!inp)return JSON.stringify({ok:false,why:'NO_INPUT'});"
      "inp.files=dt.files;"
      "inp.dispatchEvent(new Event('input',{bubbles:true}));"
      "inp.dispatchEvent(new Event('change',{bubbles:true}));"
      "return JSON.stringify({ok:true,name:f.name,size:f.size});})()" % name
)
print('inject:', evaluate(script))
time.sleep(3)

# 5. 点发送
print('send:', click_text('发送'))
time.sleep(6)

# 6. 读完整弹窗（不能截断！）
res = evaluate("(function(){var t=document.body.innerText||'';"
               "var m=t.match(/https:\\/\\/c\\.wss\\.ink\\/f\\/[A-Za-z0-9]+/);"
               "return JSON.stringify({url:m?m[0]:null,text:t.replace(/\\s+/g,' ')});})()")
if isinstance(res, str):
    try:
        res = json.loads(res)
    except Exception:
        pass
if not isinstance(res, dict):
    raise SystemExit('读分享链接失败: %r' % (res,))
print('url:', res.get('url'))
print('text:', res.get('text', '')[:400])

# 7. 打开链接验证文件确实在
if res.get('url'):
    paw({'action': 'navigate', 'url': res['url'], 'waitUntil': 'networkidle'})
    time.sleep(3)
    chk = evaluate("(function(){var t=document.body.innerText||'';"
                   "return JSON.stringify({t:t.replace(/\\s+/g,' ').slice(0,400)});})()")
    print('check:', chk)
