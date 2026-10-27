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

- `applicationState` 不是 `Background`（真后台交给微信自己发，避免重复弹）；
- 且 `SBSCopyFrontmostApplicationDisplayIdentifier()` 不是 `com.tencent.xin`（人没在微信里）。

另外会跳过：自己发出的消息、系统消息（10000/10002/51）、创建时间超过 120 秒的补拉历史消息、
以及 128 条内的重复消息（按 会话 + localID + svrID + 时间 去重）。

### 为什么还要接管 willPresent

仅仅把通知投递出去不够。只要 UNS 认为微信在前台，投递进来的通知会走
`userNotificationCenter:willPresentNotification:withCompletionHandler:`（前台呈现），
由微信自己的代理决定弹不弹；微信在“前台”时返回的是 `.none`，于是横幅和声音全无。

所以本库还会接管这个回调：只要人不在微信里，就强制返回
`banner | list | sound | badge`。这样即使 Immortalizer 的「选定应用启用前台通知」开关没开，
通知也不会被吞。微信没设代理时，本库自己装一个代理把这条路补上。

角标取自微信自己的未读总数（`CMessageMgr` 的 `GetAllUnreadCount` 等，取不到就不动）。

## 日志与自检

日志写在**微信自己的沙盒**里，不需要越权、也不需要敲命令：

```
/var/mobile/Containers/Data/Application/<微信的 UUID>/Documents/wxnotify.log
```

（Documents 写不进去才退到 `/var/mobile/Library/Preferences/wxnotify.log`。）

启动 8 秒和 20 秒后会自动写一份完整诊断；装好后第一次打开微信还会弹一条
两条「WxNotify 已加载」的自检通知（间隔 2 秒），看到它就说明库已经注进去了。

之后每条消息都会先记一行「命中」，再逐条写下跳过或补发的理由——包括命中的是哪个钩子、
消息类型、会话、`applicationState`、最前台应用。微信自己投的每一条通知也会被记成
`[投递]`，所以从日志能直接分清「微信没发」还是「发了被吞」。

```sh
notifyutil -p cn.qwq.wxnotify.diag   # 写一份完整诊断：状态、最前台、钩子、权限、Immortalizer 开关
notifyutil -p cn.qwq.wxnotify.test   # 投一条测试通知
```

诊断里的 `sel ...` 行会把 `CMessageMgr` 里所有含 `AddMsg` / `NewMsg` / `Notify` 的方法名列出来，
微信改名字时可以照着重配钩子。

## 配置

`/var/mobile/Library/Preferences/cn.qwq.wxnotify.plist`，改完 `killall -9 WeChat`
或 `notifyutil -p cn.qwq.wxnotify.changed` 生效：

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `enabled` | `true` | 总开关 |
| `showContent` | `true` | 横幅显示正文；关掉只显示「你收到一条新消息」 |
| `sound` | `true` | 提示音（优先用微信包里那条原生提示音，找不到才用系统默认） |
| `respectMute` | `true` | 是否尊重会话免打扰。命中 `isChatStatusNotifyOpenForMsgWrap:` 为关就不提醒 |
| `nativeNotify` | `true` | 原生优先：消息到达时先把 `applicationState` 读成 `Background`（只骗读接口，不动真实生命周期），让微信自己走它那条通知链路；1.2 秒内它没投递才由本插件兜底 |
| `avatar` | `false` | 用系统通讯通知显示发送者。没有 `INImage` 时 iOS 会自己加一条「你与 <wxid>」副标题，所以默认关 |
| `debug` | `true` | 打日志 |

自检：`notifyutil -p cn.qwq.wxnotify.test` 投一条测试通知，能看到横幅就说明两半都通了。
`debug` 打开后每条消息的判断过程都会进日志；排查完可以关掉。

`CMessageMgr` / `CMessageWrap` / `CContactMgr` 都是私有类，所有取值走 `respondsToSelector` + KVC，
版本对不上时静默降级（例如找不到 `AsyncOnAddMsgForSession:` 时本库什么都不做，不会崩）。

## 待真机确认

- `+[CMessageWrap isSenderFromMsgWrap:]` 在当前版本是否仍在（不在则自己发的消息也会提醒一次）；
- 群消息 `m_nsContent` 是否仍是 `wxid_xxx:\n正文` 格式（决定群标题里的昵称能否拆出来）；
- `isChatStatusNotifyOpenForMsgWrap:` 的语义到底是「会话免打扰」还是「会话当前打开」，
  确认后再决定是否把 `respectMute` 默认打开。
