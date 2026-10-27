# WxNotify · 微信保活状态下的横幅通知

给被 **Immortalizer** 保活的微信补回横幅通知（rootless，arm64 + arm64e，当前版本 **2.23**）。

同一个 dylib 注入两个进程：`com.tencent.xin`（干活）和 `com.apple.springboard`（写真实前台状态）。
本仓库是构建仓：只放源码、打包脚本和 CI 配置，不放成品二进制。

## 为什么需要它

Immortalizer 的「真后台」本质是骗 SpringBoard：它吞掉
`FBScene -updateSettings:withTransitionContext:completion:`（`transitionContext` 为空时直接返回），
并丢掉 `UIMutableApplicationSceneSettings` 的非零 `deactivationReasons`。
微信的场景因此永远不会退到后台，`applicationState` 一直是 `Active`，
收到长连接消息后压根不会创建本地通知 —— 后台横幅就没了。

更麻烦的是第二层：`usernotificationsd` 也认为微信在前台，于是每条通知都会走
`userNotificationCenter:willPresentNotification:withCompletionHandler:`，
由微信自己的代理决定弹不弹。微信在“前台”时返回 `.none`，横幅和声音全无。
所以只把通知投出去没用，呈现这一步也得接管。

## 运行机制

四个环节，缺一不可。

**一、SpringBoard 守卫写真实前台。** 注入 SpringBoard 后起一个定时器（解锁 1 秒、锁屏 60 秒，解锁那一刻由
`com.apple.springboard.lockstate` 事件立即补一拍，锁屏时连前台查询都省掉），
用 `SBSCopyFrontmostApplicationDisplayIdentifier()` 取真正的最前台 bundle id
（主屏 / 锁屏时返回 `(nil)`），连同时间戳、是否锁屏、是否有遮罩写成一行：

```
bundleId|unix时间戳|locked|blanked|接口名
```

落到 `/var/mobile/Library/Preferences/cn.qwq.wxnotify.front`，
同时再写一份到微信容器里的 `Documents/wxnotify.front`（跨容器兜底）。
返回值一律做指针范围、CFTypeID、bundle id 形状校验，任何一项不过就把该接口拉黑，
换下一个接口继续；格式化只用 `snprintf`，绝不把不可信指针喂给 `%@`。
守卫自己还有 `booting` / `ok` / `dead` 三态标记，连续崩溃时自动停手，不会把 SpringBoard 拖进安全模式。

**二、微信侧读文件判定。** 两份文件取时间戳较新的那份，超过 5 秒没更新视为守卫已死（宁可多弹，不要漏弹）。
锁屏时不参与判定；进程刚起的 12 秒内一律当作“还在微信里”，避免冷启动那几秒误判。

**三、认知翻转。** 消息到达时开一个 2.5 秒的窗口，把微信的
`applicationState`、`-isForeground`、`AppMonitorImpl -IsAppInBackground`、
以及 `MMLocalNotificationMgr` 的 `m_isInBackground` 一起翻成“后台”，
让微信自己走它那条原生通知链路（标题、正文、免打扰判断都是它自己的）。
窗口结束立刻回真实值，不干扰保活。6 秒内的通知都认作「刚翻的」。

**四、呈现接管。** `willPresent` 里，只要人不在微信里就强制返回
`banner | list | badge`；属于「刚翻的」那 6 秒内再加 `sound`
（微信以为自己在后台，不会自己响，声音必须由这条通知出）。人真的在微信里则返回 `none`，跟原生行为一致。
同一条消息 3 秒内被呈现第二次时直接压掉，避免横幅“缩回去再弹出来”。

角标我们自己在 `Documents/.wxn_badge` 里计数，投递时写进 `content.badge`。
微信在 Immortalizer 下永远不会经历 `applicationDidBecomeActive`，它那段清角标的代码跑不到，
所以回到微信时由我们代清：`setApplicationIconBadgeNumber:0` + `setBadgeCount:0`，
顺手把 `wxn-` 开头的已投递通知从通知中心撤掉；人在微信里时还会拦住微信自己贴数字。

## 适用范围

只在 **解锁状态 + 人不在微信** 时生效。锁屏之后微信会被系统真正挂起，
那段时间的消息由 APNs / 系统通知负责，不属于本插件的处理范围。

## 结构

```
src/WxNotify.m                       注入库源码（微信 + SpringBoard 双注入）
src/WxNotify.plist                   filter：com.tencent.xin / com.apple.springboard
build/DEBIAN/                        control / postinst
scripts/package.py                   切片 → 签名 → FAT → deb
scripts/push.py                      单提交推送（Git Data API），自动建仓
scripts/fetch.py                     等构建完成并下载产物（按 head_sha 过滤，避免拿旧件）
scripts/upload_wss.py                上传成品，返回下载链接
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

## 配置

`/var/mobile/Library/Preferences/cn.qwq.wxnotify.plist`，改完重开微信生效
（也可以用 `notifyutil -p cn.qwq.wxnotify.changed` 热加载）：

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `enabled` | `true` | 总开关 |
| `showContent` | `true` | 横幅显示正文；关掉只显示「你收到一条新消息」 |
| `sound` | `true` | 提示音（优先用微信包里那条原生提示音，找不到才用系统默认） |
| `respectMute` | `true` | 是否尊重会话免打扰。命中 `isChatStatusNotifyOpenForMsgWrap:` 为关就不提醒 |
| `avatar` | `false` | 用系统通讯通知显示发送者。没有 `INImage` 时 iOS 会自己加一条「你与 <wxid>」副标题，所以默认关 |
| `debug` | `false` | 打日志 |

## 日志

默认关，装完不会有任何输出。要开：在 `/var/mobile/Library/Preferences/` 下放一个空文件
`cn.qwq.wxnotify.debug`（Filza 里新建即可，删掉就重新静音），或者在 plist 里写 `debug = true`。

日志在微信自己的沙盒里：

```
/var/mobile/Containers/Data/Application/<微信的 UUID>/Documents/wxnotify.log
```

（Documents 写不进去才退到 `/var/mobile/Library/Preferences/wxnotify.log`。）

每条消息会先记一行「命中」以及命中的钩子名，再逐条写下跳过或投递的理由，
包括 `applicationState`、最前台 bundle、状态文件的新鲜度和读取到的接口。
微信自己投的每一条通知都记成 `[投递]`，所以从日志能直接分清
「微信没发」「发了被吞」「发了被压掉」三种情况。

## 排查

- 横幅不出来：先看日志里有没有「命中」和「前台判断」两行。没有「命中」说明钩子没挂上（微信改了选择器名）；
  有「命中」但 `前台判断` 是“还在微信里”，说明 SpringBoard 状态文件没写或过期。
- 状态文件不更新：`/var/mobile/Library/Preferences/cn.qwq.wxnotify.guard` 的内容是 `dead`
  说明守卫崩过、已自动停手，重装一次即可复位（`postinst` 会删掉这个标记）。
- 角标清不掉：日志里搜 `角标清理` 和 `拦住这次贴数字`，能看出数字是谁贴的。
- 横幅闪一下：日志里搜 `重复呈现`，有这行说明是同一内容被呈现两次，已经压掉。

## 已知边界与待确认

- 锁屏期间的消息不在本插件范围内（微信被系统真挂起）。
- `+[CMessageWrap isSenderFromMsgWrap:]` 在当前版本是否仍在（不在则自己发的消息也会提醒一次）；
- 群消息 `m_nsContent` 是否仍是 `wxid_xxx:\n正文` 格式（决定群标题里的昵称能否拆出来）；
- `isChatStatusNotifyOpenForMsgWrap:` 的语义到底是「会话免打扰」还是「会话当前打开」，
  确认后再决定是否把 `respectMute` 默认打开。

`CMessageMgr` / `CMessageWrap` / `CContactMgr` / `MMLocalNotificationMgr` 都是私有类，
所有取值走 `respondsToSelector` + KVC，版本对不上时静默降级（例如找不到消息钩子时本库什么都不做，不会崩）。
