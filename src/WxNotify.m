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
#import <stdarg.h>
#import <unistd.h>
#import <stdlib.h>
#import <string.h>

#define WXN_BUNDLE_ID   "com.tencent.xin"
#define WXN_VERSION     "1.8"
#define WXN_PREF_PATH   "/var/mobile/Library/Preferences/cn.qwq.wxnotify.plist"
#define WXN_CHANGED_NOT "cn.qwq.wxnotify.changed"
#define WXN_TEST_NOT    "cn.qwq.wxnotify.test"
#define WXN_DIAG_NOT    "cn.qwq.wxnotify.diag"

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

// 日志：优先写进微信自己的沙盒 Documents（不依赖沙盒越权，Filza 里一定能看到），
// 写不进去再退到全局 Preferences。
static NSString *WXNLogPath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSMutableArray *cands = [NSMutableArray array];

        NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (docs.count) [cands addObject:[docs[0] stringByAppendingPathComponent:@"wxnotify.log"]];
        [cands addObject:@"/var/mobile/Library/Preferences/wxnotify.log"];

        for (NSString *p in cands) {
            NSString *dir = [p stringByDeletingLastPathComponent];
            if ([fm fileExistsAtPath:dir] && [fm isWritableFileAtPath:dir]) {
                path = p;
                break;
            }
        }
    });
    return path;
}

static void WXNLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSLog(@"[WxNotify] %@", msg);

    NSString *p = WXNLogPath();
    if (!p) return;

    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&lock);
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attr = [fm attributesOfItemAtPath:p error:NULL];
        if (attr && [attr fileSize] > 256 * 1024) [fm removeItemAtPath:p error:NULL];

        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"MM-dd HH:mm:ss";
        NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                                                    [df stringFromDate:[NSDate date]], msg];
        NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];

        if (![fm fileExistsAtPath:p]) {
            [d writeToFile:p atomically:YES];
        } else {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
            [fh seekToEndOfFile];
            [fh writeData:d];
            [fh closeFile];
        }
    } @catch (__unused NSException *e) {
    }
    pthread_mutex_unlock(&lock);
}

// 总是记：加载、挂钩结果、投递失败这类
#define WXN_ALOG(fmt, ...) WXNLog(fmt, ##__VA_ARGS__)

// 只在 debug=1 时记：每条消息的判断细节
#define WXN_LOG(fmt, ...)                                                     \
    do {                                                                      \
        if (WXNDebug()) WXNLog(fmt, ##__VA_ARGS__);                           \
    } while (0)

static void WXNLoadConfig(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@WXN_PREF_PATH];
    WXN_ALOG(@"读配置 %@：%@", @WXN_PREF_PATH, d ?: @"(读不到，全部用默认值)");
    WXNConfig c;
    c.enabled     = d[@"enabled"]     ? [d[@"enabled"] boolValue]     : YES;
    c.showContent = d[@"showContent"] ? [d[@"showContent"] boolValue] : YES;
    // 默认静音：提示音交给微信自己那一声，避免一声消息两声提示
    c.sound       = d[@"sound"]       ? [d[@"sound"] boolValue]       : NO;
    c.respectMute = d[@"respectMute"] ? [d[@"respectMute"] boolValue] : NO;
    c.debug       = d[@"debug"]       ? [d[@"debug"] boolValue]       : YES;
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
        case 47: return @"[动画表情]";
        case 48: return @"[位置]";
        case 49: return @"[链接/文件]";
        case 50: return @"[语音通话]";
        case 62: return @"[视频号]";
        default: return @"新消息";
    }
}

// 从 XML 里取一个标签，优先认 CDATA
static NSString *WXNXMLField(NSString *xml, NSString *tag) {
    if (!xml.length || !tag.length) return nil;
    NSRange o = [xml rangeOfString:[NSString stringWithFormat:@"<%@>", tag]];
    if (o.location == NSNotFound) return nil;
    NSUInteger start = NSMaxRange(o);
    if (start > xml.length) return nil;
    NSRange rest = NSMakeRange(start, xml.length - start);
    NSRange cdata = [xml rangeOfString:@"<![CDATA[" options:0 range:rest];
    if (cdata.location != NSNotFound && cdata.location <= start + 64) {
        NSUInteger cs = NSMaxRange(cdata);
        NSRange tail = NSMakeRange(cs, xml.length - cs);
        NSRange ce = [xml rangeOfString:@"]]>" options:0 range:tail];
        if (ce.location != NSNotFound) return [xml substringWithRange:NSMakeRange(cs, ce.location - cs)];
    }
    NSRange end = [xml rangeOfString:[NSString stringWithFormat:@"</%@>", tag] options:0 range:rest];
    if (end.location == NSNotFound) return nil;
    return [xml substringWithRange:NSMakeRange(start, end.location - start)];
}

// type=49 的应用消息，真正的类型藏在 <appmsg><type> 里
static NSString *WXNAppMsgText(NSString *xml) {
    NSInteger sub = [WXNXMLField(xml, @"type") integerValue];
    NSString *title = WXNXMLField(xml, @"title");
    switch (sub) {
        case 57: // 引用回复：正文就是那句回复
            return title.length ? title : @"[引用消息]";
        case 6:  case 74:
            return title.length ? [NSString stringWithFormat:@"[文件] %@", title] : @"[文件]";
        case 5:  case 4:
            return title.length ? [NSString stringWithFormat:@"[链接] %@", title] : @"[链接]";
        case 33: case 36:
            return title.length ? [NSString stringWithFormat:@"[小程序] %@", title] : @"[小程序]";
        case 3:
            return title.length ? [NSString stringWithFormat:@"[音乐] %@", title] : @"[音乐]";
        case 19:   return @"[聊天记录]";
        case 2000: return @"[转账]";
        case 2001: return @"[红包]";
        case 51: case 63: return @"[视频号]";
        default:
            if (title.length) return title;
            return @"[链接/文件]";
    }
}

static NSString *WXNBody(id wrap, unsigned int type) {
    NSString *content = WXNStr(wrap, @"m_nsContent");
    if (type == 1 && content.length) return content;
    if (type == 49 && content.length) return WXNAppMsgText(content);

    // 微信自己渲染的显示内容：对得上的版本会直接给出「[图片]」这种文案
    SEL dispSel = NSSelectorFromString(@"GetDisplayContent");
    if ([wrap respondsToSelector:dispSel]) {
        @try {
            id v = ((id (*)(id, SEL))objc_msgSend)(wrap, dispSel);
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] &&
                ![(NSString *)v hasPrefix:@"<"]) {
                return (NSString *)v;
            }
        } @catch (__unused NSException *e) {
        }
    }
    if (content.length && ![content hasPrefix:@"<"]) return content;
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
        if (!h) {
            WXN_ALOG(@"SpringBoardServices dlopen 失败：%s", dlerror() ?: "(无信息)");
            h = dlopen("/usr/lib/libSpringBoardServices.dylib", RTLD_LAZY);
        }
        if (!h) WXN_ALOG(@"libSpringBoardServices.dylib 也打不开");
        if (h) {
            fn = (WXNCopyFrontmostFn)dlsym(h, "SBSCopyFrontmostApplicationDisplayIdentifier");
            if (!fn) WXN_ALOG(@"找不到 SBSCopyFrontmostApplicationDisplayIdentifier 符号");
        }
    });
    return fn;
}

// 只是诊断用：看看 scene 到底被 Immortalizer 糊成什么样了
static NSString *WXNSceneInfo(void) {
    NSMutableString *s = [NSMutableString string];
    @try {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            [s appendFormat:@"%@/%ld ", NSStringFromClass(object_getClass(sc)),
                              (long)sc.activationState];
        }
    } @catch (__unused NSException *e) {
    }
    return s.length ? s : @"(没有 scene)";
}

static NSString *WXNCurrentFrontmostBundle(void) {
    WXNCopyFrontmostFn fn = WXNFrontmostFn();
    if (!fn) return nil;
    NSString *bundle = nil;
    @try {
        CFStringRef s = fn();
        bundle = s ? CFBridgingRelease(s) : nil;
    } @catch (__unused NSException *e) {
        bundle = nil;
    }
    return bundle;
}

static BOOL WXNAppIsFrontmost(void) {
    NSString *b = WXNCurrentFrontmostBundle();
    if (!b) return NO; // 问不到就当作"不在前台"，宁可多弹
    return [b isEqualToString:@WXN_BUNDLE_ID];
}

static BOOL WXNShouldNotify(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return NO;

    // 只有真的退到后台才交给微信自己（那时它的通知链路是正常的，再补一条会双弹）；
    // Immortalizer 保活的 Active、锁屏过渡中的 Inactive，都归我们补。
    if (app.applicationState == UIApplicationStateBackground) return NO;

    // 人就在微信里就别弹
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

static void WXNSetupPresentationHooks(void);
static void WXNDumpDelivered(NSString *tag);

// 微信的富消息（表情/图片/链接）正文是 XML，直接当通知正文会很难看
static NSString *WXNCleanBody(NSString *s, unsigned int type) {
    if (!s.length) return WXNPlaceholder(type);
    NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([t hasPrefix:@"<"] || [t rangeOfString:@"<msg>"].location != NSNotFound)
        return WXNPlaceholder(type);
    return t;
}

// 微信自己的未读总数，用来给通知带角标。取不到就不动，免得把角标误清零。
static NSNumber *WXNUnreadCount(void) {
    id mgr = WXNService(@"CMessageMgr");
    if (!mgr) return nil;

    NSArray *cands = @[ @"GetAllUnreadCount", @"getAllUnreadCount",
                        @"GetTotalUnreadCount", @"getTotalUnreadCount",
                        @"GetUnreadCount", @"getUnreadCount" ];
    for (NSString *name in cands) {
        SEL s = NSSelectorFromString(name);
        if (![mgr respondsToSelector:s]) continue;
        @try {
            NSMethodSignature *sig = [mgr methodSignatureForSelector:s];
            if (!sig || sig.numberOfArguments != 2) continue;
            const char *rt = [sig methodReturnType];
            if (!rt) continue;
            long long v = 0;
            if (rt[0] == 'Q' || rt[0] == 'I' || rt[0] == 'L') {
                v = (long long)((unsigned long long (*)(id, SEL))objc_msgSend)(mgr, s);
            } else if (rt[0] == 'q' || rt[0] == 'i' || rt[0] == 'l') {
                v = ((long long (*)(id, SEL))objc_msgSend)(mgr, s);
            } else {
                continue;
            }
            WXN_LOG(@"未读数 %@ -> %lld", name, v);
            return v > 0 ? @(v) : nil;
        } @catch (__unused NSException *e) {
        }
    }
    return nil;
}

// 自己的 wxid，群聊通讯通知要用它当收件人
static NSString *WXNSelfUsr(void) {
    @try {
        id mgr = WXNService(@"CContactMgr");
        SEL s = NSSelectorFromString(@"getSelfContact");
        if (mgr && [mgr respondsToSelector:s]) {
            id c = ((id (*)(id, SEL))objc_msgSend)(mgr, s);
            NSString *usr = WXNStr(c, @"m_nsUsrName");
            if (usr.length) return usr;
        }
    } @catch (__unused NSException *e) {
    }
    return nil;
}

// 用系统原生的「通讯通知」把横幅画成微信那种带头像的样子。
// 全部走运行时反射，任何一步对不上就安静退回普通通知，绝不崩。
static UNNotificationContent *WXNCommunicationContent(UNNotificationContent *base,
                                                      NSString *senderUsr,
                                                      NSString *senderName,
                                                      BOOL isGroup,
                                                      NSString *session) {
    Class handleCls = NSClassFromString(@"INPersonHandle");
    Class personCls = NSClassFromString(@"INPerson");
    Class intentCls = NSClassFromString(@"INSendMessageIntent");
    Class speakCls = NSClassFromString(@"INSpeakableString");
    SEL updSel = NSSelectorFromString(@"contentByUpdatingWithProvider:error:");
    SEL personInit = NSSelectorFromString(@"initWithPersonHandle:nameComponents:displayName:image:contactIdentifier:customIdentifier:");
    SEL handleInit = NSSelectorFromString(@"initWithValue:type:");
    SEL intentInit = NSSelectorFromString(@"initWithRecipients:outgoingMessageType:content:speakableGroupName:conversationIdentifier:serviceName:sender:");

    if (!handleCls || !personCls || !intentCls) {
        WXN_ALOG(@"头像：系统里没有 Intents");
        return nil;
    }
    if (![base respondsToSelector:updSel]) {
        WXN_ALOG(@"头像：系统不支持 contentByUpdatingWithProvider:");
        return nil;
    }
    if (![personCls instancesRespondToSelector:personInit] ||
        ![handleCls instancesRespondToSelector:handleInit] ||
        ![intentCls instancesRespondToSelector:intentInit]) {
        WXN_ALOG(@"头像：初始化方法对不上");
        return nil;
    }

    @try {
        id handle = ((id (*)(id, SEL, id, NSInteger))objc_msgSend)(
            [handleCls alloc], handleInit, senderUsr, (NSInteger)0);
        id sender = ((id (*)(id, SEL, id, id, id, id, id, id))objc_msgSend)(
            [personCls alloc], personInit, handle, nil, senderName ?: senderUsr, nil, nil, senderUsr);

        NSString *me = WXNSelfUsr();
        id myHandle = ((id (*)(id, SEL, id, NSInteger))objc_msgSend)(
            [handleCls alloc], handleInit, me ?: @"self", (NSInteger)0);
        id mePerson = ((id (*)(id, SEL, id, id, id, id, id, id))objc_msgSend)(
            [personCls alloc], personInit, myHandle, nil, nil, nil, nil, me ?: @"self");

        id groupName = nil;
        if (isGroup) {
            NSString *gn = WXNDisplayName(session) ?: @"群聊";
            if (speakCls && [speakCls instancesRespondToSelector:NSSelectorFromString(@"initWithSpokenPhrase:")]) {
                groupName = ((id (*)(id, SEL, id))objc_msgSend)(
                    [speakCls alloc], NSSelectorFromString(@"initWithSpokenPhrase:"), gn);
            }
        }

        id intent = ((id (*)(id, SEL, id, NSInteger, id, id, id, id, id))objc_msgSend)(
            [intentCls alloc], intentInit, @[mePerson], (NSInteger)0, base.body,
            groupName, session, @"WeChat", sender);

        NSError *err = nil;
        id updated = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(base, updSel, intent, &err);
        if ([updated isKindOfClass:[UNNotificationContent class]]) return (UNNotificationContent *)updated;
        WXN_ALOG(@"头像：合成失败 %@", err.localizedDescription ?: @"返回空");
    } @catch (NSException *e) {
        WXN_ALOG(@"头像：异常 %@", e.reason);
    }
    return nil;
}

static void WXNPost(NSString *identifier, NSString *title, NSString *subtitle, NSString *body,
                    NSString *thread, NSString *senderUsr, BOOL isGroup) {
    WXNConfig c = WXNConfigCopy();

    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = title.length ? title : @"微信";
    if (subtitle.length) content.subtitle = subtitle;
    content.body = body.length ? body : @"新消息";
    if (c.sound) content.sound = [UNNotificationSound defaultSound];
    if (thread.length) content.threadIdentifier = thread;
    content.userInfo = @{ @"wxsession": thread ?: @"" };

    NSNumber *unread = WXNUnreadCount();
    if (unread) content.badge = unread;

    UNNotificationContent *payload = content;
    if (senderUsr.length) {
        NSString *nick = WXNDisplayName(senderUsr) ?: subtitle;
        UNNotificationContent *c2 = WXNCommunicationContent(content, senderUsr, nick, isGroup, thread);
        if (c2) payload = c2;
    }

    // 投递前保证 willPresent 已经被我们接管，否则可能被当成前台通知吞掉
    WXNSetupPresentationHooks();
    WXN_ALOG(@"投递前 delegate=%@", NSStringFromClass(object_getClass(
                 [UNUserNotificationCenter currentNotificationCenter].delegate)) ?: @"(无)");

    UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:identifier
                                                                     content:payload
                                                                     trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter]
        addNotificationRequest:req
             withCompletionHandler:^(NSError *error) {
                 if (error) WXN_ALOG(@"投递失败 %@: %@", identifier, error);
                 else {
                     WXN_LOG(@"已投递 %@", identifier);
                     dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                                    dispatch_get_main_queue(), ^{
                                        WXNDumpDelivered(identifier);
                                    });
                 }
             }];
}

// where 是命中的钩子名，日志里靠它判断到底是哪条链路把消息送上来的
static void WXNHandleMessage(id msgMgr, id wrap, NSString *where) {
    if (!wrap) {
        WXN_ALOG(@"[%@] 参数里没有 CMessageWrap，跳过", where);
        return;
    }

    WXNConfig cfg = WXNConfigCopy();
    unsigned int type = WXNUInt(wrap, @"m_uiMessageType");
    NSString *rawFrom = WXNStr(wrap, @"m_nsFromUsr");
    NSString *rawChat = WXNStr(wrap, @"m_nsRealChatUsr");
    NSString *rawContent = WXNStr(wrap, @"m_nsContent");

    // 进来的每一条都先记一笔，理由都在后面分步写，绝不静默 return
    WXN_ALOG(@"[%@] 命中 type=%u from=%@ chat=%@ svr=%lld content=%@", where, type,
             rawFrom ?: @"(空)", rawChat ?: @"(空)", WXNLongLong(wrap, @"m_n64MesSvrID"),
             WXNTrim(rawContent ?: @"(空)", 60));

    if (!cfg.enabled) {
        WXN_ALOG(@"  跳过：插件已关闭");
        return;
    }
    if (WXNIsSystemType(type)) {
        WXN_ALOG(@"  跳过：系统消息 type=%u", type);
        return;
    }

    // 人在微信里，或者微信已经正常退到后台（那边它自己会发）都不管
    if (!WXNShouldNotify()) {
        WXN_ALOG(@"  跳过：微信就在屏幕上 state=%ld frontmost=%@",
                 (long)[UIApplication sharedApplication].applicationState,
                 WXNCurrentFrontmostBundle() ?: @"(未知)");
        return;
    }

    // 自己发出去的消息不提醒
    Class wrapCls = NSClassFromString(@"CMessageWrap");
    if (wrapCls && [(id)wrapCls respondsToSelector:@selector(isSenderFromMsgWrap:)]) {
        @try {
            BOOL isSender = ((BOOL (*)(id, SEL, id))objc_msgSend)((id)wrapCls,
                                                                  @selector(isSenderFromMsgWrap:), wrap);
            if (isSender) {
                WXN_ALOG(@"  跳过：这条是我自己发的");
                return;
            }
        } @catch (__unused NSException *e) {
            WXN_ALOG(@"  注意：isSenderFromMsgWrap: 抛异常，按对方消息处理");
        }
    } else {
        WXN_ALOG(@"  注意：没有 +isSenderFromMsgWrap:，没法区分收发");
    }

    // 冷启动补拉历史消息时会灌一堆，超过两分钟的直接丢掉
    unsigned int created = WXNUInt(wrap, @"m_uiCreateTime");
    if (created) {
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        NSTimeInterval age = now - (NSTimeInterval)created;
        if (age > 120) {
            WXN_ALOG(@"  跳过：消息太旧（%.0f 秒前）", age);
            return;
        }
        if (age < -3600) WXN_ALOG(@"  注意：createTime 看着是毫秒/别的单位，差 %.0f 秒", age);
    } else {
        WXN_ALOG(@"  注意：createTime 取不到，不做新旧判断");
    }

    if (WXNIsMuted(msgMgr, wrap)) {
        WXN_ALOG(@"  跳过：会话免打扰");
        return;
    }

    NSString *session = rawChat.length ? rawChat : rawFrom;
    if (!session.length) {
        WXN_ALOG(@"  跳过：from 和 chat 都取不到");
        return;
    }

    WXN_ALOG(@"  准备补发 session=%@", session);

    unsigned int localID = WXNUInt(wrap, @"m_uiMesLocalID");
    long long svrID = WXNLongLong(wrap, @"m_n64MesSvrID");
    NSString *key = [NSString stringWithFormat:@"%@|%u|%lld|%u", session, localID, svrID, created];
    if (WXNSeenBefore(key)) {
        WXN_ALOG(@"  跳过：这条已经发过 %@", key);
        return;
    }

    BOOL isGroup = [session hasSuffix:@"@chatroom"];

    NSString *body = WXNBody(wrap, type);
    NSString *senderUsr = rawFrom;
    if (isGroup) body = WXNSplitGroupSender(body, &senderUsr);

    // 群聊：主标题群名、副标题昵称；单聊：主标题就是对方
    NSString *title = WXNDisplayName(session);
    NSString *subtitle = nil;
    if (isGroup) {
        if (!title.length) title = @"群聊";
        NSString *nick = WXNDisplayName(senderUsr);
        subtitle = nick.length ? nick : senderUsr;
    } else {
        if (!title.length) title = WXNDisplayName(rawFrom);
        if (!title.length) title = @"微信";
    }

    if (!cfg.showContent) {
        title = isGroup ? (title ?: @"群聊") : @"微信";
        subtitle = nil;
        body = @"你收到一条新消息";
    }

    body = WXNTrim(WXNCleanBody(body, type) ?: @"新消息", WXN_BODY_MAX);

    WXNPost([@"wxn-" stringByAppendingString:key], title, subtitle, body, session, senderUsr, isGroup);
}

// ---------------------------------------------------------------------------
// 钩子
// ---------------------------------------------------------------------------

static IMP gOrigForSessionNotify; // AsyncOnAddMsgForSession:MsgWrap:NewMsgArriveNotify:
static NSMutableArray *gHookNames;  // 已挂上的消息钩子

static void WXNForSessionNotify(id self, SEL _cmd, id session, id wrap, BOOL notify) {
    if (gOrigForSessionNotify) {
        ((void (*)(id, SEL, id, id, BOOL))gOrigForSessionNotify)(self, _cmd, session, wrap, notify);
    }
    if (!notify) {
        WXN_ALOG(@"[ForSessionNotify] notify=NO，微信自己都不想提醒，跳过");
        return;
    }
    @autoreleasepool {
        WXNHandleMessage(self, wrap, @"AsyncOnAddMsgForSession:MsgWrap:NewMsgArriveNotify:");
    }
}

// 两参数的消息钩子统一走这里：先调原实现，再从入参里把 CMessageWrap 拎出来
static NSMutableDictionary *gOrigMap; // 选择器名 -> NSValue(原 IMP)
static pthread_mutex_t gOrigLock = PTHREAD_MUTEX_INITIALIZER;

// 入参可能是任何东西（也可能根本不是对象），先做最基本的指针校验再往上面发消息
static BOOL WXNSaneObj(id o) {
    if (!o) return NO;
    uintptr_t p = (uintptr_t)o;
    if (p < 0x10000000UL || (p & 0x7)) return NO;
    return YES;
}

static id WXNPickWrap(id a, id b) {
    Class wc = NSClassFromString(@"CMessageWrap");
    if (!wc) return nil;
    @try {
        if (WXNSaneObj(a) && [a isKindOfClass:wc]) return a;
        if (WXNSaneObj(b) && [b isKindOfClass:wc]) return b;
    } @catch (__unused NSException *e) {
    }
    return nil;
}

static void WXNMsgHook2(id self, SEL _cmd, id a1, id a2) {
    IMP orig = NULL;
    NSString *name = NSStringFromSelector(_cmd);
    pthread_mutex_lock(&gOrigLock);
    orig = (IMP)[[gOrigMap objectForKey:name] pointerValue];
    pthread_mutex_unlock(&gOrigLock);
    if (orig) ((void (*)(id, SEL, id, id))orig)(self, _cmd, a1, a2);

    @autoreleasepool {
        WXNHandleMessage(self, WXNPickWrap(a1, a2), name);
    }
}

// 微信在决定「要不要对外提醒」时会走这里，记一下就知道它到底想不想发通知
static IMP gOrigNotifyToExt;

static void WXNNotifyToExt(id self, SEL _cmd, id a1) {
    if (WXNSaneObj(a1)) {
        @try {
            WXN_ALOG(@"[MainThreadNotifyToExt] 微信要对外提醒 arg=%@ (%@)", a1,
                     NSStringFromClass(object_getClass(a1)));
        } @catch (__unused NSException *e) {
            WXN_ALOG(@"[MainThreadNotifyToExt] 命中，但入参打印失败");
        }
    } else {
        WXN_ALOG(@"[MainThreadNotifyToExt] 命中，入参不是对象(%p)", a1);
    }
    if (gOrigNotifyToExt) ((void (*)(id, SEL, id))gOrigNotifyToExt)(self, _cmd, a1);
}

// 投递后把系统里当前存在的通知 id 抄一份，用来分清屏上的第二张横幅是谁的
static void WXNDumpDelivered(NSString *tag) {
    [[UNUserNotificationCenter currentNotificationCenter]
        getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> *list) {
            NSMutableArray<NSString *> *ids = [NSMutableArray array];
            for (UNNotification *n in list) [ids addObject:n.request.identifier];
            WXN_ALOG(@"[已送达] %@ 之后2秒，系统里共 %lu 条：%@", tag, (unsigned long)ids.count,
                     [ids componentsJoinedByString:@" | "] ?: @"(空)");
        }];
}

static BOOL WXNSwizzle(Class cls, NSString *selName, IMP replacement, IMP *outOrig) {
    SEL sel = NSSelectorFromString(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        WXN_ALOG(@"没有 %@，跳过", selName);
        return NO;
    }
    IMP orig = method_getImplementation(m);
    if (orig == replacement) return NO;
    if (outOrig) *outOrig = orig;
    method_setImplementation(m, replacement);
    WXN_ALOG(@"已挂 %@", selName);
    return YES;
}

// ---------------------------------------------------------------------------
// 前台呈现
//
// 即使通知投递成功，只要 UNS 认为微信在前台，就会走 willPresent（前台呈现）
// 而不是弹横幅；微信自己的代理返回 None，于是就是「没横幅没声音」。
// 这里直接接管 willPresent：只要人不在微信里，就强制给出横幅/列表/声音/角标。
// 这样即使 Immortalizer 那个「前台通知」开关没开，也不会被吞。
// ---------------------------------------------------------------------------

static IMP gOrigWillPresent;

// 自检通知要能当面弹出来（用户这时往往就在微信里），单独给一个开关
static BOOL gForceNextBanner = NO;

static BOOL WXNForcePresentation(void) {
    if (gForceNextBanner) return YES;
    return !WXNAppIsFrontmost();
}

static void WXNWillPresent(id self, SEL _cmd, id center, id notification,
                           void (^completion)(NSUInteger)) {
    WXN_ALOG(@"[willPresent] 进入 %@ force=%d frontmost=%@",
             NSStringFromClass(object_getClass(self)), (int)gForceNextBanner,
             WXNCurrentFrontmostBundle() ?: @"(未知)");
    if (WXNForcePresentation()) {
        NSUInteger opts = UNNotificationPresentationOptionBanner |
                          UNNotificationPresentationOptionList |
                          UNNotificationPresentationOptionSound |
                          UNNotificationPresentationOptionBadge;
        WXN_ALOG(@"前台呈现 -> 强制横幅+声音+角标");
        if (completion) completion(opts);
        return;
    }
    if (gOrigWillPresent) {
        ((void (*)(id, SEL, id, id, void (^)(NSUInteger)))gOrigWillPresent)(self, _cmd, center,
                                                                         notification, completion);
    } else if (completion) {
        completion(UNNotificationPresentationOptionNone);
    }
}

static void WXNHookDelegateClass(Class cls) {
    if (!cls) return;
    NSString *name = NSStringFromClass(cls);
    static NSMutableSet *seen;
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&lock);
    if (!seen) seen = [[NSMutableSet alloc] init];
    BOOL dup = [seen containsObject:name];
    if (!dup) [seen addObject:name];
    pthread_mutex_unlock(&lock);
    if (dup) return;

    BOOL ok = WXNSwizzle(cls, @"userNotificationCenter:willPresentNotification:withCompletionHandler:",
                         (IMP)WXNWillPresent, &gOrigWillPresent);
    WXN_ALOG(@"通知代理 %@ 的前台呈现钩子：%@", name, ok ? @"已挂" : @"无此方法");
}

// 微信压根没设代理时我们自己装一个，否则前台呈现这条路没人接
@interface WXNDelegateProxy : NSObject <UNUserNotificationCenterDelegate>
@end

@implementation WXNDelegateProxy
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    NSUInteger opts = UNNotificationPresentationOptionNone;
    if (WXNForcePresentation()) {
        opts = UNNotificationPresentationOptionBanner |
               UNNotificationPresentationOptionList |
               UNNotificationPresentationOptionSound |
               UNNotificationPresentationOptionBadge;
    }
    if (completionHandler) completionHandler(opts);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
 didReceiveNotificationResponse:(UNNotificationResponse *)response
          withCompletionHandler:(void (^)(void))completionHandler {
    if (completionHandler) completionHandler();
}
@end

static IMP gOrigSetDelegate;

static void WXNSetDelegate(id self, SEL _cmd, id delegate) {
    if (gOrigSetDelegate) ((void (*)(id, SEL, id))gOrigSetDelegate)(self, _cmd, delegate);
    if (delegate) {
        WXN_ALOG(@"UNUserNotificationCenter 换了代理：%@",
                 NSStringFromClass(object_getClass(delegate)));
        WXNHookDelegateClass(object_getClass(delegate));
    }
}

static IMP gOrigAddRequest;

// 把每一条投递都记下来：能分清是微信自己发的、还是本插件补的
static void WXNAddRequest(id self, SEL _cmd, id req, id handler) {
    @try {
        id content = [req valueForKey:@"content"];
        WXN_ALOG(@"[投递] id=%@ title=%@ sound=%@ badge=%@ body=%@",
                 [req valueForKey:@"identifier"],
                 [content valueForKey:@"title"],
                 [content valueForKey:@"sound"] ? @"有" : @"无",
                 [content valueForKey:@"badge"] ?: @"无",
                 WXNTrim([content valueForKey:@"body"] ?: @"", 40));
    } @catch (__unused NSException *e) {
        WXN_ALOG(@"[投递] 取内容失败");
    }
    if (gOrigAddRequest) ((void (*)(id, SEL, id, id))gOrigAddRequest)(self, _cmd, req, handler);
}

static void WXNSetupPresentationHooks(void) {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    if (!center) return;

    static dispatch_once_t swz;
    dispatch_once(&swz, ^{
        WXNSwizzle([UNUserNotificationCenter class], @"setDelegate:",
                   (IMP)WXNSetDelegate, &gOrigSetDelegate);
        WXNSwizzle([UNUserNotificationCenter class],
                   @"addNotificationRequest:withCompletionHandler:",
                   (IMP)WXNAddRequest, &gOrigAddRequest);
    });

    id delegate = center.delegate;
    if (delegate) {
        WXNHookDelegateClass(object_getClass(delegate));
        return;
    }

    static WXNDelegateProxy *proxy;
    static dispatch_once_t pOnce;
    dispatch_once(&pOnce, ^{ proxy = [[WXNDelegateProxy alloc] init]; });
    if (center.delegate != proxy) {
        center.delegate = proxy;
        WXN_ALOG(@"微信没有设通知代理，已装上自己的代理");
    }
}

static BOOL WXNInstall(void) {
    Class cls = NSClassFromString(@"CMessageMgr");
    if (!cls) return NO;

    if (!gOrigMap) gOrigMap = [NSMutableDictionary dictionary];
    if (!gHookNames) gHookNames = [NSMutableArray array];

    BOOL any = NO;

    // 微信各版本的消息到达链路不一样，能挂的全挂上；重复命中由去重挡掉。
    // 只能挂两个参数全为 id 的，带基本类型的（fixTime 那种）参数对不上，不碰。
    NSArray<NSString *> *two = @[
        @"AsyncOnPreAddMsg:MsgWrap:",
        @"AsyncOnAddMsg:MsgWrap:",
        @"AsyncOnAddMsgForSession:MsgWrap:",
        @"AddMsg:MsgWrap:",
        @"AsyncOnAddMsgListForSession:NotifyUsrName:",
        @"onNewSyncAddMsgSessionArray:withUsers:",
    ];
    for (NSString *name in two) {
        Method m = class_getInstanceMethod(cls, NSSelectorFromString(name));
        if (!m) {
            WXN_ALOG(@"没有 %@，跳过", name);
            continue;
        }
        // 入参不是两个对象的就不碰，否则会把非对象入参当 id 用
        NSMethodSignature *sig = [cls instanceMethodSignatureForSelector:NSSelectorFromString(name)];
        if (!sig || sig.numberOfArguments != 4 ||
            strcmp([sig getArgumentTypeAtIndex:2], "@") != 0 ||
            strcmp([sig getArgumentTypeAtIndex:3], "@") != 0) {
            WXN_ALOG(@"%@ 的入参不是两个对象，跳过", name);
            continue;
        }
        IMP orig = method_getImplementation(m);
        if (orig != (IMP)WXNMsgHook2) {
            gOrigMap[name] = [NSValue valueWithPointer:orig];
            method_setImplementation(m, (IMP)WXNMsgHook2);
            WXN_ALOG(@"已挂 %@", name);
        }
        if (![gHookNames containsObject:name]) [gHookNames addObject:name];
        any = YES;
    }

    NSString *three = @"AsyncOnAddMsgForSession:MsgWrap:NewMsgArriveNotify:";
    any |= WXNSwizzle(cls, three, (IMP)WXNForSessionNotify, &gOrigForSessionNotify);
    if (gOrigForSessionNotify && ![gHookNames containsObject:three]) [gHookNames addObject:three];

    // 只记不改：微信到底有没有决定对外提醒
    SEL extSel = NSSelectorFromString(@"MainThreadNotifyToExt:");
    NSMethodSignature *extSig = [cls instanceMethodSignatureForSelector:extSel];
    if (extSig && extSig.numberOfArguments == 3 &&
        strcmp([extSig getArgumentTypeAtIndex:2], "@") == 0) {
        any |= WXNSwizzle(cls, @"MainThreadNotifyToExt:", (IMP)WXNNotifyToExt, &gOrigNotifyToExt);
    } else if (extSig) {
        WXN_ALOG(@"MainThreadNotifyToExt: 入参不是对象，不挂");
    }
    return any;
}

// 类可能比 dylib 的 constructor 晚就绪，最多重试 20 次（约 10 秒）
static void WXNInstallWithRetry(int attempt) {
    if (WXNInstall()) {
        // 微信可能在启动后才设置通知代理，跟着多试几次
        return;
    }
    if (attempt >= 20) {
        WXN_ALOG(@"找不到 CMessageMgr，消息钩子不生效");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       WXNInstallWithRetry(attempt + 1);
                   });
}

static void WXNSetupWithRetry(int attempt) {
    WXNSetupPresentationHooks();
    if (attempt >= 10) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       WXNSetupWithRetry(attempt + 1);
                   });
}

// ---------------------------------------------------------------------------
// 自检：发一条测试通知，确认 UNS 那一半也开了
//   notifyutil -p cn.qwq.wxnotify.test
// ---------------------------------------------------------------------------

static void WXNPostTest(void) {
    WXNPost([@"wxn-test-" stringByAppendingString:[[NSUUID UUID] UUIDString]],
            @"微信后台通知", nil, @"如果你看到这条横幅，说明两半都通了。",
            @"wxn-test", nil, NO);
}

// 诊断：notifyutil -p cn.qwq.wxnotify.diag
// 把环境、钩子、权限、Immortalizer 开关全写进日志文件
static void WXNDumpReport(void) {
    WXN_ALOG(@"======== 诊断开始 ========");
    WXN_ALOG(@"pid=%d bundle=%@ version=%s", (int)getpid(),
             [[NSBundle mainBundle] bundleIdentifier], WXN_VERSION);
    WXN_ALOG(@"日志文件=%@", WXNLogPath() ?: @"(没有可写目录)");

    UIApplication *app = [UIApplication sharedApplication];
    WXN_ALOG(@"applicationState=%ld（0=Active 1=Inactive 2=Background）", (long)app.applicationState);
    WXN_ALOG(@"最前台应用=%@", WXNCurrentFrontmostBundle() ?: @"(取不到)");
    WXN_ALOG(@"scene 列表=%@", WXNSceneInfo());
    WXN_ALOG(@"CMessageMgr=%@ CMessageWrap=%@ CContactMgr=%@",
             NSClassFromString(@"CMessageMgr") ? @"在" : @"不在",
             NSClassFromString(@"CMessageWrap") ? @"在" : @"不在",
             NSClassFromString(@"CContactMgr") ? @"在" : @"不在");
    WXN_ALOG(@"消息钩子(%lu 个)：%@", (unsigned long)gHookNames.count,
             [gHookNames componentsJoinedByString:@" / "] ?: @"(一个也没挂上)");
    WXN_ALOG(@"呈现钩子：willPresent=%@ 截获投递=%@ 当前 delegate=%@",
             gOrigWillPresent ? @"已挂" : @"未挂",
             gOrigAddRequest ? @"已挂" : @"未挂",
             NSStringFromClass(object_getClass(
                 [UNUserNotificationCenter currentNotificationCenter].delegate)) ?: @"(没有代理)");

    // 列出 CMessageMgr 里所有跟消息到达有关的方法，版本对不上时好改钩子
    Class cls = NSClassFromString(@"CMessageMgr");
    if (cls) {
        unsigned int n = 0;
        Method *ms = class_copyMethodList(cls, &n);
        for (unsigned int i = 0; i < n; i++) {
            const char *nm = sel_getName(method_getName(ms[i]));
            if (strstr(nm, "AddMsg") || strstr(nm, "NewMsg") || strstr(nm, "Notify"))
                WXN_ALOG(@"  sel %s", nm);
        }
        free(ms);
    }

    // 通知权限
    [[UNUserNotificationCenter currentNotificationCenter]
        getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *s) {
            WXN_ALOG(@"通知权限：authorization=%ld alertStyle=%ld sound=%ld badge=%ld",
                     (long)s.authorizationStatus, (long)s.alertStyle,
                     (long)s.soundSetting, (long)s.badgeSetting);
        }];

    // Immortalizer 的「前台通知」开关（沙盒里多半读不到，读到就直接说明问题）
    @try {
        NSUserDefaults *ip = [[NSUserDefaults alloc] initWithSuiteName:@"com.sergy.immortalizer.prefs"];
        NSArray *sel = [ip objectForKey:@"selectedApplications"];
        // 头像的本地路径藏在 CContact 的某个字段里，先把名字记下来
    Class cc = NSClassFromString(@"CContact");
    if (cc) {
        NSMutableArray *hits = [NSMutableArray array];
        unsigned int cnt = 0;
        Ivar *ivars = class_copyIvarList(cc, &cnt);
        for (unsigned int i = 0; i < cnt; i++) {
            const char *n = ivar_getName(ivars[i]);
            if (!n) continue;
            NSString *name = @(n);
            if ([name rangeOfString:@"ead" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [name rangeOfString:@"mg" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [hits addObject:name];
            }
        }
        if (ivars) free(ivars);
        WXN_ALOG(@"CContact 头像相关字段：%@",
                 hits.count ? [hits componentsJoinedByString:@" / "] : @"(没找到)");
    }

    WXN_ALOG(@"Immortalizer selectedApplications=%@，含微信=%@", sel,
                 [sel containsObject:@WXN_BUNDLE_ID] ? @"是" : @"否");
    } @catch (__unused NSException *e) {
        WXN_ALOG(@"读 Immortalizer 配置失败");
    }
    WXN_ALOG(@"======== 诊断结束 ========");
}

static void WXNPostBootOnce(void) {
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (!docs.count) return;
    NSString *marker = [docs[0] stringByAppendingPathComponent:
                                   [@".wxn_boot_" stringByAppendingString:@WXN_VERSION]];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:marker]) return;
    if (![@"1" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:NULL]) return;

    gForceNextBanner = YES;
    NSString *where = WXNLogPath() ?: @"(日志没写成功)";
    WXN_ALOG(@"首次启动，投一条自检通知：%@", where);

    // 两条间隔 2 秒：一条在微信里（走 willPresent 强制），一条应当直接当普通通知弹
    for (int i = 0; i < 2; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           WXNPost([NSString stringWithFormat:@"wxn-boot-%d-%@", i,
                                    [[NSUUID UUID] UUIDString]],
                                   [NSString stringWithFormat:@"WxNotify %s 已加载", WXN_VERSION],
                                   nil,
                                   [NSString stringWithFormat:@"第 %d 条。收到消息会补发横幅。日志：%@",
                                    i + 1, where],
                                   @"wxn-boot", nil, NO);
                       });
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       gForceNextBanner = NO;
                   });
}

__attribute__((constructor))
static void WXNInit(void) {
    WXN_ALOG(@"======== WxNotify %s 已加载 pid=%d ========", WXN_VERSION, (int)getpid());
    WXNLoadConfig();

    static int changedToken = -1;
    notify_register_dispatch(WXN_CHANGED_NOT, &changedToken, dispatch_get_main_queue(), ^(int t) {
        WXNLoadConfig();
    });

    static int testToken = -1;
    notify_register_dispatch(WXN_TEST_NOT, &testToken, dispatch_get_main_queue(), ^(int t) {
        WXNLoadConfig();
        WXN_ALOG(@"收到测试通知请求");
        WXNPostTest();
    });

    static int diagToken = -1;
    notify_register_dispatch(WXN_DIAG_NOT, &diagToken, dispatch_get_main_queue(), ^(int t) {
        WXNDumpReport();
    });

    WXNInstallWithRetry(0);
    WXNSetupWithRetry(0);

    // 用户那边跑不了命令，所以启动后自己写一份诊断到沙盒，并弹一条自检
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       WXNSetupPresentationHooks();
                       WXNDumpReport();
                       WXNPostBootOnce();
                   });
    // 有些机器上 CMessageMgr 注册得很晚，20 秒再补一次
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       WXNSetupPresentationHooks();
                       WXNDumpReport();
                   });
}
