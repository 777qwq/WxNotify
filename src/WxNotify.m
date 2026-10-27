// WxNotify - 为 Immortalizer 保活的微信补发本地通知
//
// 注入进程：com.tencent.xin
//
// 为什么需要这个库：
//   Immortalizer 通过两处 SpringBoard 侧钩子让微信一直"停在前台"：
//     * 吞掉 FBScene -updateSettings:withTransitionContext:completion:
//     * 丢掉 UIMutableApplicationSceneSettings 的非零 deactivationReasons
//   于是微信自己始终认为自己是前台活跃的，收到长连接消息后不会去创建
//   本地通知（UNNotificationRequest），后台横幅就没了。
//
//   Immortalizer 自带的「选定应用启用前台通知」只修另一半：它在
//   UserNotificationsServer 侧调用 -_didChangeApplicationState:4，让通知
//   服务以为微信在后台。两半缺一不可：
//     - Immortalizer 那个开关  -> UNS 不再把通知按"前台"处理
//     - 本库                  -> 微信真的把通知投递出去
//   只开一个，横幅都不会出现。
//
// 设计要点：
//   * 只钩"新消息到达"那一处，且不覆盖微信自己的行为（先调原实现）；
//   * 所有私有类/属性都走 respondsToSelector + KVC，版本漂移时静默降级
//     而不是崩；
//   * 只在"微信认为自己在前台、但 SpringBoard 说最前台不是它"时投递，
//     正常退到后台时不会和微信自己的通知重复弹两次；
//   * 只在 debug=1 时打日志。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <notify.h>
#import <pthread.h>
#import <stdlib.h>
#import <string.h>

#define WXN_BUNDLE_ID   "com.tencent.xin"
#define WXN_PREF_PATH   "/var/mobile/Library/Preferences/cn.qwq.wxnotify.plist"
#define WXN_CHANGED_NOT "cn.qwq.wxnotify.changed"
#define WXN_TEST_NOT    "cn.qwq.wxnotify.test"

// 通知里显示的内容上限，防止超长消息把横幅撑爆
#define WXN_BODY_MAX    240

// ---------------------------------------------------------------------------
// 配置
// ---------------------------------------------------------------------------

typedef struct {
    BOOL enabled;      // 总开关
    BOOL showContent;  // 显示消息正文；关掉就只显示"你收到一条新消息"
    BOOL sound;        // 播放提示音
    BOOL respectMute;  // 尊重微信的会话免打扰（默认关，宁可多弹也不要漏）
    BOOL debug;        // 打日志
} WXNConfig;

static WXNConfig gCfg;
static pthread_mutex_t gCfgLock = PTHREAD_MUTEX_INITIALIZER;

static WXNConfig WXNConfigCopy(void) {
    WXNConfig c;
    pthread_mutex_lock(&gCfgLock);
    c = gCfg;
    pthread_mutex_unlock(&gCfgLock);
    return c;
}

static BOOL WXNDebug(void) {
    WXNConfig c = WXNConfigCopy();
    return c.debug;
}

#define WXN_LOG(fmt, ...)                                                     \
    do {                                                                      \
        if (WXNDebug()) NSLog(@"[WxNotify] " fmt, ##__VA_ARGS__);             \
    } while (0)

static void WXNLoadConfig(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@WXN_PREF_PATH];
    WXNConfig c;
    c.enabled     = d[@"enabled"]     ? [d[@"enabled"] boolValue]     : YES;
    c.showContent = d[@"showContent"] ? [d[@"showContent"] boolValue] : YES;
    c.sound       = d[@"sound"]       ? [d[@"sound"] boolValue]       : YES;
    c.respectMute = d[@"respectMute"] ? [d[@"respectMute"] boolValue] : NO;
    c.debug       = d[@"debug"]       ? [d[@"debug"] boolValue]       : NO;
    pthread_mutex_lock(&gCfgLock);
    gCfg = c;
    pthread_mutex_unlock(&gCfgLock);
    WXN_LOG(@"config enabled=%d showContent=%d sound=%d respectMute=%d debug=%d",
            c.enabled, c.showContent, c.sound, c.respectMute, c.debug);
}

// ---------------------------------------------------------------------------
// 通用取值：微信的属性大多是 unsigned int / _Bool，不能直接 objc_msgSend 成 id，
// 统一走 KVC（标量会被装箱成 NSNumber）。
// ---------------------------------------------------------------------------

static id WXNGet(id obj, NSString *key) {
    if (!obj || !key) return nil;
    if (![obj respondsToSelector:NSSelectorFromString(key)]) return nil;
    @try {
        return [obj valueForKey:key];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static NSString *WXNStr(id obj, NSString *key) {
    id v = WXNGet(obj, key);
    return [v isKindOfClass:[NSString class]] ? (NSString *)v : nil;
}

static unsigned int WXNUInt(id obj, NSString *key) {
    id v = WXNGet(obj, key);
    return [v isKindOfClass:[NSNumber class]] ? [(NSNumber *)v unsignedIntValue] : 0;
}

static long long WXNLongLong(id obj, NSString *key) {
    id v = WXNGet(obj, key);
    return [v isKindOfClass:[NSNumber class]] ? [(NSNumber *)v longLongValue] : 0;
}

// ---------------------------------------------------------------------------
// 微信服务 / 联系人
// ---------------------------------------------------------------------------

static id WXNService(NSString *clsName) {
    Class centerCls = NSClassFromString(@"MMServiceCenter");
    Class svcCls = NSClassFromString(clsName);
    if (!centerCls || !svcCls) return nil;

    SEL dcSel = NSSelectorFromString(@"defaultCenter");
    if (![(id)centerCls respondsToSelector:dcSel]) return nil;

    id center = ((id (*)(id, SEL))objc_msgSend)((id)centerCls, dcSel);
    if (!center || ![center respondsToSelector:@selector(getService:)]) return nil;

    @try {
        return ((id (*)(id, SEL, Class))objc_msgSend)(center, @selector(getService:), svcCls);
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static id WXNContact(NSString *usr) {
    if (!usr.length) return nil;
    id mgr = WXNService(@"CContactMgr");
    if (!mgr) return nil;

    // 不同版本的方法名不一样，挨个试
    NSArray<NSString *> *cands = @[ @"getContactByName:", @"getContactByUserName:",
                                    @"getContactByUsrName:", @"getContact:" ];
    for (NSString *name in cands) {
        SEL s = NSSelectorFromString(name);
        if (![mgr respondsToSelector:s]) continue;
        @try {
            id c = ((id (*)(id, SEL, id))objc_msgSend)(mgr, s, usr);
            if (c) return c;
        } @catch (__unused NSException *e) {
            // 换下一个
        }
    }
    return nil;
}

// 备注 > 昵称 > 微信自己的显示名
static NSString *WXNDisplayName(NSString *usr) {
    if (!usr.length) return nil;
    id c = WXNContact(usr);
    NSString *remark = WXNStr(c, @"m_nsRemark");
    if (remark.length) return remark;
    NSString *nick = WXNStr(c, @"m_nsNickName");
    if (nick.length) return nick;
    NSString *label = WXNStr(c, @"m_nsDisplayName");
    if (label.length) return label;
    return nil;
}

// ---------------------------------------------------------------------------
// 消息内容
// ---------------------------------------------------------------------------

static BOOL WXNIsSystemType(unsigned int type) {
    // 10000/10002 是系统提示，51 是状态通知，都不该弹横幅
    return type == 10000 || type == 10002 || type == 51;
}

// 群消息的 m_nsContent 形如 "wxid_xxx:\n正文"，把发送人摘出来
static NSString *WXNSplitGroupSender(NSString *content, NSString **outSender) {
    if (outSender) *outSender = nil;
    if (!content.length) return content;
    NSRange r = [content rangeOfString:@":\n"];
    if (r.location == NSNotFound || r.location == 0 || r.location > 64) return content;
    NSString *head = [content substringToIndex:r.location];
    if (outSender) *outSender = head;
    return [content substringFromIndex:r.location + r.length];
}

static NSString *WXNPlaceholder(unsigned int type) {
    switch (type) {
        case 3:  return @"[图片]";
        case 34: return @"[语音]";
        case 42: return @"[名片]";
        case 43: return @"[视频]";
        case 47: return @"[表情]";
        case 48: return @"[位置]";
        case 49: return @"[链接/文件]";
        case 50: return @"[语音通话]";
        default: return @"新消息";
    }
}

static NSString *WXNBody(id wrap, unsigned int type) {
    NSString *content = WXNStr(wrap, @"m_nsContent");
    if (type == 1 && content.length) return content;

    // 微信自己渲染的显示内容：图片->[图片]、语音->[语音] …… 版本对得上就用它
    SEL dispSel = NSSelectorFromString(@"GetDisplayContent");
    if ([wrap respondsToSelector:dispSel]) {
        @try {
            id v = ((id (*)(id, SEL))objc_msgSend)(wrap, dispSel);
            if ([v isKindOfClass:[NSString class]] && [v length]) return (NSString *)v;
        } @catch (__unused NSException *e) {
        }
    }
    if (content.length) return content;
    return WXNPlaceholder(type);
}

static NSString *WXNTrim(NSString *s, NSUInteger max) {
    if (s.length <= max) return s;
    return [[s substringToIndex:max] stringByAppendingString:@"…"];
}

// 微信自己的「消息免打扰」。默认不采信（尊重它就设 respectMute=1），
// 因为这个选择器在不同版本里的语义没有百分百把握，宁可按"没免打扰"处理。
static BOOL WXNIsMuted(id msgMgr, id wrap) {
    WXNConfig c = WXNConfigCopy();
    if (!c.respectMute) return NO;

    SEL s = NSSelectorFromString(@"isChatStatusNotifyOpenForMsgWrap:");
    if (!msgMgr || ![msgMgr respondsToSelector:s]) return NO;
    @try {
        BOOL open = ((BOOL (*)(id, SEL, id))objc_msgSend)(msgMgr, s, wrap);
        return open ? NO : YES;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

// ---------------------------------------------------------------------------
// "微信到底在不在屏幕上"
//
// Immortalizer 把 applicationState 钉死在 Active，光看它区分不出"真的在微信里"
// 和"被保活但人在别的 App"。所以再问一次 SpringBoard 谁在最前面。
// ---------------------------------------------------------------------------

typedef CFStringRef (*WXNCopyFrontmostFn)(void);

static WXNCopyFrontmostFn WXNFrontmostFn(void) {
    static WXNCopyFrontmostFn fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
        if (!h) h = dlopen("/usr/lib/libSpringBoardServices.dylib", RTLD_LAZY);
        if (h) fn = (WXNCopyFrontmostFn)dlsym(h, "SBSCopyFrontmostApplicationDisplayIdentifier");
    });
    return fn;
}

static BOOL WXNAppIsFrontmost(void) {
    WXNCopyFrontmostFn fn = WXNFrontmostFn();
    if (!fn) return NO; // 问不到就当作"不在前台"，宁可多弹
    NSString *bundle = nil;
    @try {
        CFStringRef s = fn();
        bundle = s ? CFBridgingRelease(s) : nil;
    } @catch (__unused NSException *e) {
        bundle = nil;
    }
    return [bundle isEqualToString:@WXN_BUNDLE_ID];
}

static BOOL WXNShouldNotify(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return NO;

    // 真退到后台时微信自己的通知链路是好的，再补一条会双弹
    if (app.applicationState != UIApplicationStateActive) return NO;

    // 被保活（或真的在前台）时 applicationState 都是 Active，用最前台 App 兜底
    if (WXNAppIsFrontmost()) return NO;

    return YES;
}

// ---------------------------------------------------------------------------
// 去重
// ---------------------------------------------------------------------------

static NSMutableOrderedSet *gSeen;
static pthread_mutex_t gSeenLock = PTHREAD_MUTEX_INITIALIZER;

// 返回 YES 表示这条已经发过
static BOOL WXNSeenBefore(NSString *key) {
    if (!key.length) return NO;
    pthread_mutex_lock(&gSeenLock);
    if (!gSeen) gSeen = [[NSMutableOrderedSet alloc] init];
    BOOL dup = [gSeen containsObject:key];
    if (!dup) {
        [gSeen addObject:key];
        if (gSeen.count > 128) [gSeen removeObjectAtIndex:0];
    }
    pthread_mutex_unlock(&gSeenLock);
    return dup;
}

// ---------------------------------------------------------------------------
// 投递
// ---------------------------------------------------------------------------

static void WXNPost(NSString *identifier, NSString *title, NSString *body, NSString *thread) {
    WXNConfig c = WXNConfigCopy();

    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = title.length ? title : @"微信";
    content.body = body.length ? body : @"新消息";
    if (c.sound) content.sound = [UNNotificationSound defaultSound];
    if (thread.length) content.threadIdentifier = thread;
    content.userInfo = @{ @"wxsession": thread ?: @"" };

    UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:identifier
                                                                     content:content
                                                                     trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter]
        addNotificationRequest:req
             withCompletionHandler:^(NSError *error) {
                 if (error) NSLog(@"[WxNotify] 投递失败: %@", error);
                 else WXN_LOG(@"已投递 %@", identifier);
             }];
}

static void WXNHandleMessage(id msgMgr, id wrap) {
    if (!wrap) return;

    WXNConfig cfg = WXNConfigCopy();
    if (!cfg.enabled) return;

    unsigned int type = WXNUInt(wrap, @"m_uiMessageType");
    if (WXNIsSystemType(type)) return;

    // 人在微信里，或者微信已经正常退到后台（那边它自己会发）都不管
    if (!WXNShouldNotify()) return;

    // 自己发出去的消息不提醒
    Class wrapCls = NSClassFromString(@"CMessageWrap");
    if (wrapCls && [(id)wrapCls respondsToSelector:@selector(isSenderFromMsgWrap:)]) {
        @try {
            BOOL isSender = ((BOOL (*)(id, SEL, id))objc_msgSend)((id)wrapCls,
                                                                  @selector(isSenderFromMsgWrap:), wrap);
            if (isSender) return;
        } @catch (__unused NSException *e) {
        }
    }

    // 冷启动补拉历史消息时会灌一堆，超过两分钟的直接丢掉
    unsigned int created = WXNUInt(wrap, @"m_uiCreateTime");
    if (created) {
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - (NSTimeInterval)created > 120) return;
    }

    if (WXNIsMuted(msgMgr, wrap)) {
        WXN_LOG(@"会话免打扰，跳过");
        return;
    }

    NSString *fromUsr = WXNStr(wrap, @"m_nsFromUsr");
    NSString *realChat = WXNStr(wrap, @"m_nsRealChatUsr");
    NSString *session = realChat.length ? realChat : fromUsr;
    if (!session.length) return;

    unsigned int localID = WXNUInt(wrap, @"m_uiMesLocalID");
    long long svrID = WXNLongLong(wrap, @"m_n64MesSvrID");
    NSString *key = [NSString stringWithFormat:@"%@|%u|%lld|%u", session, localID, svrID, created];
    if (WXNSeenBefore(key)) return;

    BOOL isGroup = [session hasSuffix:@"@chatroom"];

    NSString *body = WXNBody(wrap, type);
    NSString *senderUsr = nil;
    if (isGroup) body = WXNSplitGroupSender(body, &senderUsr);

    NSString *title = nil;
    if (isGroup) {
        title = WXNDisplayName(session);
        if (!title.length) title = @"群聊";
        NSString *nick = WXNDisplayName(senderUsr);
        if (!nick.length) nick = senderUsr;
        if (nick.length) body = [NSString stringWithFormat:@"%@: %@", nick, body];
    } else {
        title = WXNDisplayName(session);
        if (!title.length) title = WXNDisplayName(fromUsr);
        if (!title.length) title = @"微信";
    }

    if (!cfg.showContent) {
        title = isGroup ? (title ?: @"群聊") : @"微信";
        body = @"你收到一条新消息";
    }

    body = WXNTrim(body ?: @"新消息", WXN_BODY_MAX);

    WXNPost([@"wxn-" stringByAppendingString:key], title, body, session);
}

// ---------------------------------------------------------------------------
// 钩子
// ---------------------------------------------------------------------------

static IMP gOrigForSessionNotify; // AsyncOnAddMsgForSession:MsgWrap:NewMsgArriveNotify:
static IMP gOrigForSession;       // AsyncOnAddMsgForSession:MsgWrap:

static void WXNForSessionNotify(id self, SEL _cmd, id session, id wrap, BOOL notify) {
    if (gOrigForSessionNotify) {
        ((void (*)(id, SEL, id, id, BOOL))gOrigForSessionNotify)(self, _cmd, session, wrap, notify);
    }
    if (!notify) return;
    @autoreleasepool {
        WXNHandleMessage(self, wrap);
    }
}

static void WXNForSession(id self, SEL _cmd, id session, id wrap) {
    if (gOrigForSession) {
        ((void (*)(id, SEL, id, id))gOrigForSession)(self, _cmd, session, wrap);
    }
    @autoreleasepool {
        WXNHandleMessage(self, wrap);
    }
}

static BOOL WXNSwizzle(Class cls, NSString *selName, IMP replacement, IMP *outOrig) {
    SEL sel = NSSelectorFromString(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        WXN_LOG(@"没有 %@，跳过", selName);
        return NO;
    }
    IMP orig = method_getImplementation(m);
    if (orig == replacement) return NO;
    if (outOrig) *outOrig = orig;
    method_setImplementation(m, replacement);
    WXN_LOG(@"已挂 %@", selName);
    return YES;
}

static BOOL WXNInstall(void) {
    Class cls = NSClassFromString(@"CMessageMgr");
    if (!cls) return NO;

    BOOL any = NO;
    any |= WXNSwizzle(cls, @"AsyncOnAddMsgForSession:MsgWrap:NewMsgArriveNotify:",
                      (IMP)WXNForSessionNotify, &gOrigForSessionNotify);
    // 老版本/部分分支只有三参数版本，一起挂上；重复的那次会被去重挡掉
    any |= WXNSwizzle(cls, @"AsyncOnAddMsgForSession:MsgWrap:",
                      (IMP)WXNForSession, &gOrigForSession);
    return any;
}

// 类可能比 dylib 的 constructor 晚就绪，最多重试 20 次（约 10 秒）
static void WXNInstallWithRetry(int attempt) {
    if (WXNInstall()) return;
    if (attempt >= 20) {
        NSLog(@"[WxNotify] 找不到 CMessageMgr，本库不生效");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       WXNInstallWithRetry(attempt + 1);
                   });
}

// ---------------------------------------------------------------------------
// 自检：发一条测试通知，确认 UNS 那一半也开了
//   notifyutil -p cn.qwq.wxnotify.test
// ---------------------------------------------------------------------------

static void WXNPostTest(void) {
    WXNPost([@"wxn-test-" stringByAppendingString:[[NSUUID UUID] UUIDString]],
            @"微信后台通知", @"如果你看到这条横幅，说明两半都通了。", @"wxn-test");
}

__attribute__((constructor))
static void WXNInit(void) {
    WXNLoadConfig();

    static int changedToken = -1;
    notify_register_dispatch(WXN_CHANGED_NOT, &changedToken, dispatch_get_main_queue(), ^(int t) {
        WXNLoadConfig();
    });

    static int testToken = -1;
    notify_register_dispatch(WXN_TEST_NOT, &testToken, dispatch_get_main_queue(), ^(int t) {
        WXNLoadConfig();
        WXNPostTest();
    });

    WXNInstallWithRetry(0);
}
