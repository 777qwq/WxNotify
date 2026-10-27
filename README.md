# WxNotify · 微信后台通知补发

给被 **Immortalizer** 保活的微信补回后台横幅通知（rootless / arm64 + arm64e）。

本仓库是构建仓：只放源码、打包脚本和 CI 配置，不放成品二进制。

## 为什么需要它

Immortalizer 的「真后台」本质是骗 SpringBoard：它吞掉
`FBScene -updateSettings:withTransitionContext:completion:`（`transitionContext` 为空时直接返回），
并丢掉 `UIMutableApplicationSceneSettings` 的非零 `deactivationReasons`。
微信的场景因此永远不会退到后台，`applicationState` 一直是 `Active`，
收到长连接消息后压根不会创建本地通知 —— 后台横幅就没了。

WxNotify 补的是另一半：钩住 `CMessageMgr` 的消息到达，
在「微信自认前台、但 SpringBoard 说真正的前台不是它」时自己投一条本地通知。

## 两半必须同时开

只装本插件不生效，**两份缺一不可**：

1. 手机「设置 → Immortalizer → 通知 → 选定应用启用前台通知」勾上微信。
   这一步让 `UNSUserNotificationServer` 对微信调用 `_didChangeApplicationState:4`，
   不再把通知当成前台呈现；不做的话，我们投递的通知会被微信的前台代理静默丢掉
   （不报错，也不显示任何东西）。
2. 装本包，重启微信后注入 WxNotify。

## 结构

```
src/WxNotify.m                       注入库源码（com.tencent.xin）
src/WxNotify.plist                   filter，只注入微信
build/DEBIAN/                        control / postinst
scripts/package.py                   切片 → 签名 → FAT → deb
scripts/push.py                      单提交推送（Git Data API），自动建仓
scripts/fetch.py                     等构建完成并下载产物
.github/workflows/build.yml          云端构建（macos-14，真 Apple 工具链）
```

## 构建

推送到 `main` 即触发 Actions，产出 2 个 thin slice：`WxNotify-arm64.dylib`、`WxNotify-arm64e.dylib`。

```sh
python3 scripts/push.py       # 单提交推送 + 触发构建
python3 scripts/fetch.py      # 等待并下载到 out/
python3 scripts/package.py --slices out --out dist --ldid ./bin/ldid
```

编译参数：`-fobjc-arc -O2 -dynamiclib -fno-omit-frame-pointer -Wl,-undefined,dynamic_lookup`，
链接 `UIKit` / `Foundation` / `UserNotifications`。

> **为什么要手动改 cputype**：ldid 给 FAT 签名时会把第二个架构的 cputype 归一成
> `0x0100000c`（arm64），arm64e 设备会按 arm64 加载甚至直接不加载。所以签名之后
> 必须把 header 偏移 28–31 写回 `0x0200000c`。

## 行为

只钩 `CMessageMgr` 的 `AsyncOnAddMsgForSession:MsgWrap:NewMsgArriveNotify:`
（以及三参数旧版 `AsyncOnAddMsgForSession:MsgWrap:`）。触发条件是：

- `UIApplication.applicationState == Active`（真后台交给微信自己发，避免重复弹）；
- 且 `SBSCopyFrontmostApplicationDisplayIdentifier()` 不是 `com.tencent.xin`（人没在微信里）。

另外会跳过：自己发出的消息、系统消息（10000/10002/51）、创建时间超过 120 秒的补拉历史消息、
以及 128 条内的重复消息（按 会话 + localID + svrID + 时间 去重）。

## 配置

`/var/mobile/Library/Preferences/cn.qwq.wxnotify.plist`，改完 `killall -9 WeChat`
或 `notifyutil -p cn.qwq.wxnotify.changed` 生效：

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `enabled` | `true` | 总开关 |
| `showContent` | `true` | 横幅显示正文；关掉只显示「你收到一条新消息」 |
| `sound` | `true` | 提示音 |
| `respectMute` | `false` | 是否尊重会话免打扰。默认关：这个判断依赖私有选择器，各版本语义没把握，宁可多弹也不漏 |
| `debug` | `false` | 打日志 |

自检：`notifyutil -p cn.qwq.wxnotify.test` 投一条测试通知，能看到横幅就说明两半都通了。

`CMessageMgr` / `CMessageWrap` / `CContactMgr` 都是私有类，所有取值走 `respondsToSelector` + KVC，
版本对不上时静默降级（例如找不到 `AsyncOnAddMsgForSession:` 时本库什么都不做，不会崩）。

## 待真机确认

- `+[CMessageWrap isSenderFromMsgWrap:]` 在当前版本是否仍在（不在则自己发的消息也会提醒一次）；
- 群消息 `m_nsContent` 是否仍是 `wxid_xxx:\n正文` 格式（决定群标题里的昵称能否拆出来）；
- `isChatStatusNotifyOpenForMsgWrap:` 的语义到底是「会话免打扰」还是「会话当前打开」，
  确认后再决定是否把 `respectMute` 默认打开。
