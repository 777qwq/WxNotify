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
#import <QuartzCore/CADisplayLink.h>
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

#include <time.h>
#define WXN_BUNDLE_ID   "com.tencent.xin"
#define WXN_VERSION     "2.53"
#define WXN_PREF_PATH   "/var/mobile/Library/Preferences/cn.qwq.wxnotify.plist"
#define WXN_CHANGED_NOT "cn.qwq.wxnotify.changed"
// 2.17：放一个空文件就开日志（Filza 里新建），删掉就关
#define WXN_DEBUG_MARK  "/var/mobile/Library/Preferences/cn.qwq.wxnotify.debug"
// 2.12：SpringBoard 侧守卫写的真·最前台状态
#define WXN_FRONT_PATH  "/var/mobile/Library/Preferences/cn.qwq.wxnotify.front"



// 通知里显示的内容上限，防止超长消息把横幅撑爆
#define WXN_BODY_MAX    240

// ---------------------------------------------------------------------------
// 配置
// ---------------------------------------------------------------------------

typedef struct {
    BOOL enabled;      // 总开关
    BOOL showContent;  // 显示消息正文；关掉就只显示"你收到一条新消息"
    BOOL sound;        // 播放提示音
    BOOL respectMute;  // 尊重微信的会话免打扰
    BOOL avatar;       // 用系统通讯通知显示发送者头像
    BOOL fallback;     // 微信没自己发的时候，由我们补一条。2.20 起默认关
    BOOL debug;        // 打日志
} WXNConfig;

static WXNConfig gCfg;
static pthread_mutex_t gCfgLock = PTHREAD_MUTEX_INITIALIZER;

// 「假装在后台」：只在消息到达的那一小段时间里，让微信读到 Background，
// 它就会走自己那条原生通知分支（标题/正文/角标/提示音/免打扰全是原生的）。
static volatile BOOL gFakeBG = NO;
static NSInteger gRealAppState = -1;   // 假装期间的真实状态
static int gFakeBGGen = 0;
static int gNativePosts = 0;  // 微信自己投递的通知条数
static int gNativePostsAtStart = 0;

// 2.11：假装后台的“余期”。willPresent 常常晚于 2.5 秒窗口才进来，
// 所以把截止时间单独记一份，窗口过了也能认出“这条是刚翻出来的原生通知”。
static double gFakeUntil = 0;


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
        NSString *tmp = NSTemporaryDirectory();   // 2.22：放微信沙盒 tmp/，系统会自动清
        if (tmp.length) [cands addObject:[tmp stringByAppendingPathComponent:@"wxnotify.log"]];
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

#define WXN_LOG_MAX  (50 * 1024)   // 2.22：日志上限 50KB，超了清空重写

static void WXNLog(NSString *fmt, ...) {
    // 2.22：日志默认开（plist debug=false 或删标记文件可关）；超 50KB 清空重写
    if (!WXNDebug()) return;

    NSString *lp = WXNLogPath();
    if (lp) {
        NSDictionary *st2 = [[NSFileManager defaultManager] attributesOfItemAtPath:lp error:NULL];
        if (st2 && [st2 fileSize] > WXN_LOG_MAX) [[NSFileManager defaultManager] removeItemAtPath:lp error:NULL];
    }

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
    c.sound       = d[@"sound"]       ? [d[@"sound"] boolValue]       : YES;
    c.respectMute = d[@"respectMute"] ? [d[@"respectMute"] boolValue] : YES;
    c.avatar      = d[@"avatar"]      ? [d[@"avatar"] boolValue]      : NO;
    // 2.20：补发默认关。只让微信自己那条通知出去，避免"我们投一条、
    // 它又投一条"把横幅顶成先收回再弹出。想恢复补发写 fallback=true。
    c.fallback = d[@"fallback"] ? [d[@"fallback"] boolValue] : NO;
    // 日志默认关。想开：plist 里 debug=true，或者放一个空文件
    // /var/mobile/Library/Preferences/cn.qwq.wxnotify.debug（Filza 里新建就行）
    if (d[@"debug"]) c.debug = [d[@"debug"] boolValue];
    else c.debug = YES;   // 2.22：日志默认开（plist debug=false 可关）
    pthread_mutex_lock(&gCfgLock);
    gCfg = c;
    pthread_mutex_unlock(&gCfgLock);
    WXN_LOG(@"config enabled=%d showContent=%d sound=%d respectMute=%d avatar=%d native=%d debug=%d",
            c.enabled, c.showContent, c.sound, c.respectMute, c.avatar, c.fallback, c.debug);
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

// 微信自己的「消息免打扰」。默认采信（respectMute=1），免打扰的会话不提醒。
static BOOL WXNIsMuted(id msgMgr, id wrap) {
    WXNConfig c = WXNConfigCopy();
    if (!c.respectMute) return NO;

    SEL s = NSSelectorFromString(@"isChatStatusNotifyOpenForMsgWrap:");
    if (!msgMgr || ![msgMgr respondsToSelector:s]) return NO;
    BOOL open = YES;
    @try {
        open = ((BOOL (*)(id, SEL, id))objc_msgSend)(msgMgr, s, wrap);
    } @catch (__unused NSException *e) {
        return NO;
    }
    if (open) return NO;

    // 选择器说"别提醒"，再用消息自带的 <silence> 复核一遍：两个都指向免打扰才算。
    // 只信选择器会把不该吞的消息全吞掉（2.0 就是这么把群消息全跳过的）。
    NSString *src = WXNStr(wrap, @"m_nsMsgSource") ?: WXNStr(wrap, @"m_msgSource");
    BOOL silent = [[WXNXMLField(src, @"silence") lowercaseString] isEqualToString:@"1"];
    WXN_ALOG(@"  免打扰探测：open=%d silence=%d", open, silent);
    return silent;
}

// ---------------------------------------------------------------------------
// "微信到底在不在屏幕上"
//
// Immortalizer 把 applicationState 钉死在 Active，光看它区分不出"真的在微信里"
// 和"被保活但人在别的 App"。所以再问一次 SpringBoard 谁在最前面。
// ---------------------------------------------------------------------------

// 锁屏状态：SpringBoard 一直在广播这一位，沙盒里也读得到
static BOOL WXNDeviceLocked(void) {
    static int tok = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (notify_register_check("com.apple.springboard.lockstate", &tok) != NOTIFY_STATUS_OK) tok = -1;
    });
    if (tok < 0) return NO;
    uint64_t v = 0;
    if (notify_get_state(tok, &v) != NOTIFY_STATUS_OK) return NO;
    return v != 0;
}

// 人在不在微信里 —— 2.12 起只信 SpringBoard 写的那份状态。
//
// 帧探针和触摸两版都失败了：帧探针在 Immortalizer 下永远在刷（锁屏时也刷），
// 触摸只在微信里才有，“人在别的 App”和“人在微信里发呆”对进程来说一模一样。
// 进程内再也搾不出更可靠的信号，所以换路线：让 SpringBoard 自己来说。
// 它不受沙盒限制，也骗不到（Immortalizer 骗的是 App 自己），
// 同一个 dylib 注入 com.apple.springboard 后每半秒把真实的 frontmost 写进这个文件：
//     bundle|时间戳|锁屏|熄屏|用的哪个接口
//
// 两份文件取时间戳更新的那份：
//   * Preferences 下那份要沙盒放行才读得到（越狱环境大多放行了，但不保险）；
//   * 微信自己 Documents 下那份一定有权限，SpringBoard 有跨容器访问权，写得进去。
static NSString *WXNFrontLine(void) {
    NSArray *paths = @[
        [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/wxnotify.front"],
        @WXN_FRONT_PATH,
    ];
    NSString *best = @"";
    double bestTs = -1;
    for (NSString *p in paths) {
        NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:NULL];
        s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!s.length) continue;
        NSArray *f = [s componentsSeparatedByString:@"|"];
        double ts = f.count > 1 ? [f[1] doubleValue] : 0;
        if (ts > bestTs) { bestTs = ts; best = s; }
    }
    return best ?: @"";
}

static BOOL WXNInWeChat(NSString **whyOut) {
    NSString *line = WXNFrontLine();
    if (!line.length) {
        if (whyOut) *whyOut = @"SpringBoard 状态文件读不到（装完没注销？或者守卫没注进去）";
        return NO;
    }
    NSArray *f = [line componentsSeparatedByString:@"|"];
    if (f.count < 2) {
        if (whyOut) *whyOut = [@"状态文件格式不对：" stringByAppendingString:WXNTrim(line, 60)];
        return NO;
    }
    double age = [[NSDate date] timeIntervalSince1970] - [f[1] doubleValue];
    BOOL locked = (f.count > 2) && [f[2] boolValue];
    if (whyOut) {
        *whyOut = [NSString stringWithFormat:@"最前台=%@（%.1f 秒前写的，锁屏=%d，接口=%@）",
                   f[0], age, (int)locked, f.count > 4 ? f[4] : @"?"];
    }
    if (age > 5.0) return NO;    // 守卫挂了：宁可多弹，不要漏
    if (locked) return NO;
    return [f[0] isEqualToString:@WXN_BUNDLE_ID];
}

static BOOL WXNInWeChat(NSString **whyOut);

// 进程起来的时间。启动那十来秒 SpringBoard 还没把微信算成最前台，
// 状态文件会是 (nil)，那时候的“人走了”不能信，否则刚开微信就弹一条。
static double gWxnStartAt = 0;

static BOOL WXNInWeChatSafe(NSString **whyOut) {
    NSString *why = nil;
    BOOL in = WXNInWeChat(&why);
    if (!in && !WXNDeviceLocked() && gWxnStartAt > 0 &&
        CFAbsoluteTimeGetCurrent() - gWxnStartAt < 12.0) {
        why = [why stringByAppendingString:@"（刚启动，当还在微信里）"];
        in = YES;
    }
    if (whyOut) *whyOut = why;
    return in;
}

static BOOL WXNShouldNotify(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return NO;

    // 真的退到后台（没装 Immortalizer 或它没生效）就交给微信自己，别双弹
    NSInteger st = gFakeBG ? gRealAppState : (NSInteger)app.applicationState;
    if (st == UIApplicationStateBackground) return NO;

    // 锁屏了：肯定要提醒
    if (WXNDeviceLocked()) {
        WXN_ALOG(@"  锁屏中，要提醒");
        return YES;
    }

    NSString *why = nil;
    BOOL inWeChat = WXNInWeChatSafe(&why);
    WXN_ALOG(@"  前台判断：%@ -> %@", why ?: @"(无)", inWeChat ? @"人在微信里" : @"人不在微信里");
    return !inWeChat;
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
static BOOL WXNSwizzle(Class cls, NSString *selName, IMP replacement, IMP *outOrig);
static void WXNBeginFakeBackground(NSString *why);
static void WXNEndFakeBackground(NSString *why);

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

// ---------------------------------------------------------------------------
// 角标
//
// 2.2 的日志：同一轮里两次都打出 "角标：0 -> 1"，说明投递完系统的
// applicationIconBadgeNumber 并不会回写，读它永远是旧值，角标就永远停在 1。
// 改成自己数：每投一条 +1，用户回到微信（碰屏幕）或者微信自己清零时归零。
// ---------------------------------------------------------------------------

static NSInteger gBadge = -1;

static NSString *WXNBadgePath(void) {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (!dir.length) dir = NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@".wxn_badge"];
}

static void WXNBadgeWrite(void) {
    NSString *p = WXNBadgePath();
    [[NSString stringWithFormat:@"%ld", (long)(gBadge < 0 ? 0 : gBadge)]
        writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static NSInteger WXNBadgeNext(void) {
    if (gBadge < 0) {
        NSString *v = [NSString stringWithContentsOfFile:WXNBadgePath()
                                                encoding:NSUTF8StringEncoding
                                                   error:NULL];
        gBadge = v ? [v integerValue] : 0;
    }
    gBadge += 1;
    WXNBadgeWrite();
    return gBadge;
}





// 人在不在微信里，钩子里随时要问，先声明
static BOOL WXNInWeChatSafe(NSString **whyOut);



// 把微信自己那条提示音拷到 Library/Sounds，让通知用它
static NSString *WXNToneName(void) {
    static NSString *name;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *bundle = [[NSBundle mainBundle] bundlePath];
        NSArray *list = [fm contentsOfDirectoryAtPath:bundle error:NULL];
        NSMutableArray *found = [NSMutableArray array];
        for (NSString *f in list) {
            NSString *ext = [f.pathExtension lowercaseString];
            if ([ext isEqualToString:@"caf"] || [ext isEqualToString:@"wav"]) [found addObject:f];
        }
        WXN_ALOG(@"包根目录音频：%@", found.count ? [found componentsJoinedByString:@", "] : @"(没有)");

        NSArray *prefer = @[@"in.caf", @"msg.caf", @"newmsg.caf", @"notify.caf",
                            @"message.caf", @"in.wav", @"msg.wav"];
        NSString *pick = nil;
        for (NSString *p in prefer) {
            if ([found containsObject:p]) { pick = p; break; }
        }
        if (!pick && found.count) pick = found.firstObject;
        if (!pick) return;

        NSString *lib = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject];
        NSString *sounds = [lib stringByAppendingPathComponent:@"Sounds"];
        [fm createDirectoryAtPath:sounds withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *dst = [[sounds stringByAppendingPathComponent:@"wxn-tone"]
                         stringByAppendingPathExtension:pick.pathExtension];
        [fm removeItemAtPath:dst error:NULL];
        if ([fm copyItemAtPath:[bundle stringByAppendingPathComponent:pick] toPath:dst error:NULL]) {
            name = dst.lastPathComponent;
        }
        NSDictionary *attr = [fm attributesOfItemAtPath:dst error:NULL];
        WXN_ALOG(@"提示音选用：%@ -> %@（%lld 字节，在 %@）", pick, name ?: @"(拷贝失败)",
                 (long long)[attr[NSFileSize] longLongValue], sounds);
    });
    return name;
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
// 2.53 前向引用（会话级记账，定义在 WXNInstall 段）
static NSInteger gNAMCount;
static NSMutableDictionary *gSessionUnread;
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
    if (c.sound) {
        NSString *tone = WXNToneName();
        content.sound = tone.length ? [UNNotificationSound soundNamed:tone]
                                    : [UNNotificationSound defaultSound];
    }
    if (thread.length) content.threadIdentifier = thread;
    content.userInfo = @{ @"wxsession": thread ?: @"" };

    // 角标：微信被保活时自己从不设角标，这里自己数
    NSInteger nextBadge = WXNBadgeNext();
    content.badge = @(nextBadge);
    WXN_ALOG(@"角标：-> %ld", (long)nextBadge);

    UNNotificationContent *payload = content;
    if (c.avatar && senderUsr.length) {
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
                 else WXN_LOG(@"已投递 %@", identifier);
             }];
}

// 原生优先：先让微信自己发，它不发我们再补
// ---------------------------------------------------------------------------
// 场景停用信号
//
// SpringBoard 在用户切走 / 上滑回桌面 / 锁屏时，会通过 FBScene 把
// deactivationReasons 推给应用。Immortalizer 就是在这里把它抹掉的。
// 我们不去改它（改了就没保活了），只在它抹之前看一眼：看到了，就说明人真的走了。
// ---------------------------------------------------------------------------

// 每个类各自保留原来的 IMP："类名|选择器" -> NSValue(IMP)
// 不能只存一份，因为同一个选择器可能被好几个类各自实现，调用时得找回"这一个实例"的上一层。
static NSMutableDictionary *gSceneOrig = nil;

// 从实例的真实类往上找：谁是我们接管的，就返回它原来的 IMP
static NSTimeInterval gLastSceneLogAt = 0;

// 在运行时里把"自己实现了这个方法"的类全部接管。
// 只认自己的方法列表（不认继承来的），这样每个类只挂一次，且子类实例调用时
// WXNOrigFor 一路往上找一定能找到对应的原实现。
// 可以反复调用：后来才加载的类、以及被别人又盖回去的方法，都会被重新接管
static void WXNDeliver(NSString *identifier, NSString *title, NSString *subtitle, NSString *body,
                       NSString *thread, NSString *senderUsr, BOOL isGroup) {
    WXNConfig c = WXNConfigCopy();

    if (!gFakeBG) {
        // 微信当时真的在后台，它自己会发，补发关了就不插手
        if (!c.fallback) {
            WXN_ALOG(@"补发已关闭，这条交给微信自己（%@）", identifier);
            return;
        }
        WXNPost(identifier, title, subtitle, body, thread, senderUsr, isGroup);
        return;
    }
    int base = gNativePostsAtStart;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        int now = gNativePosts;
        if (now > base) {
            WXN_ALOG(@"微信自己发了 %d 条通知，本次不再补发", now - base);
            WXNEndFakeBackground(@"交给微信");
            return;
        }
        WXNEndFakeBackground(@"微信没发");
        if (!c.fallback) {
            WXN_ALOG(@"微信没有自己发，补发已关闭，这条不出横幅");
            return;
        }
        WXN_ALOG(@"微信没有自己发，改由本插件补发");
        WXNPost(identifier, title, subtitle, body, thread, senderUsr, isGroup);
    });
}

// where 是命中的钩子名，日志里靠它判断到底是哪条链路把消息送上来的
static void WXNBeginFakeBackground(NSString *why);   // 定义在后面

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
        WXN_ALOG(@"  跳过：前台判断为“人在微信里”");
        // 2.53：前台来消息（非自己发）= 未读 +1（微信不写角标，我们自己记账）
        Class wrapCls2 = NSClassFromString(@"CMessageWrap");
        BOOL isSender = NO;
        if (wrapCls2 && [(id)wrapCls2 respondsToSelector:@selector(isSenderFromMsgWrap:)]) {
            @try { isSender = ((BOOL (*)(id, SEL, id))objc_msgSend)((id)wrapCls2, @selector(isSenderFromMsgWrap:), wrap); }
            @catch (__unused NSException *e) {}
        }
        if (!isSender) {
            NSString *sess = rawChat.length ? rawChat : rawFrom;
            if (sess.length) {
                gNAMCount += 1;
                gSessionUnread[sess] = @([gSessionUnread[sess] integerValue] + 1);
                WXN_ALOG(@"  [计数] 前台来消息 %ld（会话 %@ 记账 %d）", (long)gNAMCount, sess, [gSessionUnread[sess] intValue]);
            }
        }
        return;
    }

    // 人不在微信里：真正要投递之前再翻它的认知（见 WXNBeginFakeBackground），
    // 因为这里之后还可能因为“自己发的/免打扰/太旧/重复”而跳过

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

    // 群消息的字段很容易搞反：m_nsFromUsr 是群 id（xxx@chatroom），
    // m_nsRealChatUsr 反而是发消息那个人的 wxid。2.2 拿后者当会话，于是
    // 群消息被当成了单聊、标题变成了对方的昵称。
    NSString *session = nil;
    BOOL isGroup = NO;
    if ([rawFrom hasSuffix:@"@chatroom"]) {
        session = rawFrom;
        isGroup = YES;
    } else if ([rawChat hasSuffix:@"@chatroom"]) {
        session = rawChat;
        isGroup = YES;
    } else {
        session = rawChat.length ? rawChat : rawFrom;
    }
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

    NSString *body = WXNBody(wrap, type);
    NSString *senderUsr = rawFrom;
    if (isGroup) {
        // 正文开头的 "wxid_xxx:\n" 是发送者，有的版本会被微信自己剥掉，
        // 那种情况发送者就在 m_nsRealChatUsr 里
        NSString *fromBody = nil;
        body = WXNSplitGroupSender(body, &fromBody);
        senderUsr = fromBody;
        if (!senderUsr.length || [senderUsr isEqualToString:session] ||
            [senderUsr hasSuffix:@"@chatroom"]) {
            senderUsr = rawChat.length ? rawChat : session;
        }
    }

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

    WXNBeginFakeBackground(@"消息到达");
    WXNDeliver([@"wxn-" stringByAppendingString:key], title, subtitle, body, session, senderUsr, isGroup);
}

// ---------------------------------------------------------------------------
// 钩子
// ---------------------------------------------------------------------------

static IMP gOrigForSessionNotify; // AsyncOnAddMsgForSession:MsgWrap:NewMsgArriveNotify:
static NSMutableArray *gHookNames;  // 已挂上的消息钩子

static BOOL WXNForSessionNotify(id self, SEL _cmd, id session, id wrap, BOOL notify) {
    BOOL r = NO;
    if (gOrigForSessionNotify) {
        r = ((BOOL (*)(id, SEL, id, id, BOOL))gOrigForSessionNotify)(self, _cmd, session, wrap, notify);
    }
    if (!notify) {
        WXN_ALOG(@"[ForSessionNotify] notify=%d 原返回=%d", (int)notify, (int)r);
        return r;
    }
    @autoreleasepool {
        WXNHandleMessage(self, wrap, @"AsyncOnAddMsgForSession:MsgWrap:NewMsgArriveNotify:");
    }
    return r;
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

static BOOL WXNMsgHook2(id self, SEL _cmd, id a1, id a2) {
    IMP orig = NULL;
    NSString *name = NSStringFromSelector(_cmd);
    pthread_mutex_lock(&gOrigLock);
    orig = (IMP)[[gOrigMap objectForKey:name] pointerValue];
    pthread_mutex_unlock(&gOrigLock);
    // 2.25：原实现返回值原样带回——2.22/2.24 微信内无声的头号嫌疑就是
    // void 直调把有返回值的方法冲成垃圾，微信的提醒决策变成抽签
    BOOL r = NO;
    if (orig) r = ((BOOL (*)(id, SEL, id, id))orig)(self, _cmd, a1, a2);

    @autoreleasepool {
        WXNHandleMessage(self, WXNPickWrap(a1, a2), name);
    }
    return r;
}

// 微信在决定「要不要对外提醒」时会走这里，记一下就知道它到底想不想发通知
static IMP gOrigNotifyToExt;


// 推送决策点：CMessageMgr 收到消息后会在这两个方法里决定「要不要弹提醒」。
// 2.9 的日志里连这两个方法都没出现，说明它在更前面就认定「我在前台」了；
// 2.10 把它们记下来，就能看出是“没走到”还是“走到了但被拦”。
static BOOL WXNReadLNBG(void);   // 定义在后面，这里先声明



// 投递后把系统里当前存在的通知 id 抄一份，用来分清屏上的第二张横幅是谁的
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
    return !WXNInWeChatSafe(NULL);
}

// 2.19：同一条消息在几秒内被呈现两次时，iOS 会把前一条横幅收回去、
// 再把后一条放出来——看上去就是“缩回去又弹出来”。第二次的来路可能是
// 微信自己也补了一条、APNs 又下来一条，或者同一个请求被重复呈现；
// 不去分辨来路，一律按「会话+标题+正文」在 3 秒内压掉。
static NSString *gLastPresentFP = nil;
static double gLastPresentAt = 0;

static BOOL WXNDuplicatePresentation(NSString *fp) {
    if (!fp.length) return NO;
    double now = CFAbsoluteTimeGetCurrent();
    BOOL dup = gLastPresentFP && [gLastPresentFP isEqualToString:fp] && now - gLastPresentAt < 3.0;
    gLastPresentFP = fp;
    gLastPresentAt = now;
    return dup;
}

static void WXNWillPresent(id self, SEL _cmd, id center, id notification,
                           void (^completion)(NSUInteger)) {
    double now = CFAbsoluteTimeGetCurrent();
    BOOL faked = (now < gFakeUntil);
    NSString *why = nil;
    BOOL inWeChat = !gForceNextBanner && !faked && WXNInWeChatSafe(&why);

    // 系统只在"它认为微信在前台"时才调这里。所以这里的判断就是最后一道闸：
    // 人在微信里 -> 静默（横幅、声音、角标全不要），跟原生前台行为一致；
    // 人不在微信里（或这条是我们刚翻出来的）-> 给足横幅+声音+角标。
    WXN_ALOG(@"[willPresent] 进入 %@ 在微信里=%d 刚翻的=%d 强制=%d（%@）",
             NSStringFromClass(object_getClass(self)), (int)inWeChat, (int)faked,
             (int)gForceNextBanner, why ?: @"(无)");

    if (inWeChat) {
        // 2.23：人在微信里 -> 原实现奉还。8.0.80 的前台提示音就走在微信自己的
        // delegate 上，我们接管后返回 None 是掐声的根源。这里不替微信做任何
        // 决定，声音/角标/呈现全部由它自己的逻辑处理。
        WXN_ALOG(@"前台呈现 -> 人在微信里，原实现奉还");
        if (gOrigWillPresent) {
            ((void (*)(id, SEL, id, id, void (^)(NSUInteger)))gOrigWillPresent)(
                self, _cmd, center, notification, completion);
        } else if (completion) {
            completion(UNNotificationPresentationOptionNone);
        }
        return;
    }

    // 同一条消息的第二份（不管是谁发的）不再呈现，否则横幅会先收回再弹出
    NSString *fp = nil;
    @try {
        id content = [[notification valueForKey:@"request"] valueForKey:@"content"];
        fp = [NSString stringWithFormat:@"%@|%@|%@",
              [content valueForKey:@"threadIdentifier"] ?: @"",
              [content valueForKey:@"title"] ?: @"",
              [content valueForKey:@"body"] ?: @""];
    } @catch (__unused NSException *e) { fp = nil; }
    if (WXNDuplicatePresentation(fp)) {
        WXN_ALOG(@"前台呈现 -> 3 秒内同一条消息重复呈现，压掉后一条（%@）", WXNTrim(fp, 60));
        if (completion) completion(UNNotificationPresentationOptionNone);
        return;
    }

    NSUInteger opts = UNNotificationPresentationOptionBanner |
                      UNNotificationPresentationOptionList |
                      UNNotificationPresentationOptionBadge;
    if (faked) {
        // 微信以为自己在后台，它自己那一声根本不会响 —— 声音必须由这条通知出，
        // 否则就是“有横幅没声音”。
        opts |= UNNotificationPresentationOptionSound;
        WXN_ALOG(@"前台呈现 -> 强制横幅+声音+角标（微信以为在后台，自己没响）");
    } else {
        // 没翻过：说明微信当时在前台，它自己的提示音已经响过，再加声音就是双响
        WXN_ALOG(@"前台呈现 -> 强制横幅+角标（不重复出声）");
    }
    if (completion) completion(opts);
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
static id gNAMInstance;   // 2.44 前向引用（声明在 WXNInstall 段）

static void WXNSetDelegate(id self, SEL _cmd, id delegate) {
    if (gOrigSetDelegate) ((void (*)(id, SEL, id))gOrigSetDelegate)(self, _cmd, delegate);
    if (delegate) {
        WXN_ALOG(@"UNUserNotificationCenter 换了代理：%@",
                 NSStringFromClass(object_getClass(delegate)));
        // 2.44：NotificationActionsMgr 当代理的瞬间抓单例——总未读 ivar 的宿主
        Class nam = NSClassFromString(@"NotificationActionsMgr");
        if (nam && [delegate isKindOfClass:nam] && !gNAMInstance) {
            gNAMInstance = delegate;
            WXN_ALOG(@"[退出清理] 已抓到 NAM 单例（setDelegate）");
        }
        WXNHookDelegateClass(object_getClass(delegate));
    }
}

// ---------------------------------------------------------------------------
// 「假装在后台」：让微信自己走原生那条通知链路
//
// Immortalizer 把 scene 按住不放，微信永远以为自己在前台，于是只走内部逻辑，
// 从不发本地通知。我们没法真的把它送进后台（那等于放弃保活），但可以在消息
// 到达的那一小段时间里，让 applicationState 读出来是 Background。
// 只骗读接口，不触发任何真实生命周期回调，所以保活、长连接、界面都不受影响。
// ---------------------------------------------------------------------------

static NSInteger (*gOrigAppState)(id, SEL);

static NSInteger WXNAppState(id self, SEL _cmd) {
    if (gFakeBG) return UIApplicationStateBackground;
    return gOrigAppState ? gOrigAppState(self, _cmd) : UIApplicationStateActive;
}

static void WXNInstallFakeBG(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class app = NSClassFromString(@"UIApplication");
        if (!app) { WXN_ALOG(@"假装后台：找不到 UIApplication"); return; }
        BOOL ok = WXNSwizzle(app, @"applicationState", (IMP)WXNAppState, &gOrigAppState);
        WXN_ALOG(@"假装后台：applicationState 接管%@", ok ? @"成功" : @"失败");
    });
}

// ---------------------------------------------------------------------------
// 让微信自己发：改它自己的认知
//
// 8.0.5x 头文件里查到了：微信判“要不要发本地通知”看的是
// MMLocalNotificationMgr 自己的 ivar m_isInBackground，
// 而它只在 onServiceEnterBackground / onServiceEnterForeground 里被改。
// 这两个回调跟着生命周期一起被 Immortalizer 抹掉了，所以它永远是 0，
// 微信就永远认为“我在前台，不用发”。
// 我们在消息到达的那一刻把它改成 1，让微信自己的整条通知链路跑起来。
// ---------------------------------------------------------------------------

static id gLN = nil;
static Ivar gLNIsBG = NULL;
static void (*gOrigLNInit)(id, SEL);
static void (*gOrigLNShowPush3)(id, SEL, id, id, id, BOOL, BOOL);

static void WXNGrabLN(id self) {
    if (gLN != self) {
        gLN = self;
        WXN_ALOG(@"拿到 MMLocalNotificationMgr：%@", self);
    }
    if (!gLNIsBG) {
        gLNIsBG = class_getInstanceVariable(object_getClass(self), "m_isInBackground");
        if (!gLNIsBG) gLNIsBG = class_getInstanceVariable(object_getClass(self), "_m_isInBackground");
        WXN_ALOG(@"m_isInBackground 字段：%@", gLNIsBG ? @"找到" : @"没找到");
    }
}

static BOOL WXNReadLNBG(void) {
    if (!gLN || !gLNIsBG) return NO;
    BOOL *p = (BOOL *)((char *)(__bridge void *)gLN + ivar_getOffset(gLNIsBG));
    return *p ? YES : NO;
}

static void WXNCognitionForce(BOOL bg) {
    if (!gLN || !gLNIsBG) return;
    BOOL *p = (BOOL *)((char *)(__bridge void *)gLN + ivar_getOffset(gLNIsBG));
    if ((*p ? YES : NO) == bg) return;
    *p = bg;
    WXN_ALOG(@"微信的认知：m_isInBackground = %d", (int)bg);
}

static NSInteger WXNUnreadTotal(void);
static IMP gOrigBadgeSet;            // 2.39 前向引用（声明在 WXNInstall 段）
static id gNAMInstance;              // 2.43 前向引用
static NSInteger gNAMCount = -1;     // 2.45 前向引用
static void WXNDumpNAMIvars(void);   // 2.51 前向引用
// 2.53：会话级记账——前台来消息 gNAMCount+1 并记会话债，ClearUnRead 时还债。
// 解决「前台读消息不触发 onAppIconTotalUnreadCountChange 回调」的计数过期问题。
static NSMutableDictionary *gSessionUnread = nil;
static IMP gOrigClearUnRead = nil;
static void WXNClearUnReadHook(id self, SEL _cmd, id from, id to);
// 2.39：诚实窗口——离开时停 2 秒干预，让微信自己的监控撞上真实状态、
// 走原生退出清理链。2 秒后看探针：微信自己写过角标就收手，没写才代笔。
static BOOL gWeChatWroteBadge = NO;   // 窗口期内微信是否自己写过角标
static void WXNNativeExitCleanup(void) {
    // 2.52：收官版——拆掉 UnReadChange 错误口径写入器后，退出时写 gNAMCount
    //（onAppIconTotalUnreadCountChange: 参数捕获的微信自己的总未读，2.45 实锤）。
    // 真身解析保留：gLN 可能是 MMServiceWrapper 容器。
    if (!gLN) { WXN_ALOG(@"[退出清理] LN 未就绪"); return; }
    if (gNAMCount < 0) {
        WXN_ALOG(@"[退出清理] 未捕获过未读数，不动角标");
        return;
    }
    Class nam = NSClassFromString(@"NotificationActionsMgr");
    if (!nam || !gOrigBadgeSet) return;
    WXN_ALOG(@"[退出清理] 退出写总未读：角标 = %ld", (long)gNAMCount);
    @try {
        ((void (*)(id, SEL, NSInteger))gOrigBadgeSet)((id)nam, @selector(setApplicationIconBadgeNumber:), gNAMCount);
    } @catch (NSException *e) {
        WXN_ALOG(@"[退出清理] 异常 %@", e);
    }
}

static void WXNCognitionRestore(void) {
    WXNCognitionForce(NO);
}

// ---- 2.10：把微信各处的“我在前台”缓存一起翻 -------------------------------
//
// 2.9 只翻 MMLocalNotificationMgr 一个字段，而且连实例都没拿到：
// onServiceInit 早就跑完了，钩子挂上时已经没人再调它。
// 现在改成主动去 MMServiceCenter 里把它提出来，同时把另外两处也一并翻：
//   MicroMessengerAppDelegate -isForeground
//   AppMonitorImpl            -IsAppInBackground
// 全部是可逆的取值钩子，只在“假装后台”的 2.5 秒内生效。
static BOOL (*gOrigIsForeground)(id, SEL);
static BOOL (*gOrigAppMonitorBG)(id, SEL);
static id (*gOrigGetService)(id, SEL, Class);
static double gLastStateDump = 0;

// 把对象上所有“状态类”的布尔字段读一遍，看微信到底认为自己在哪
// 字段名对不上的时候，得能看到真实存在哪些名字
static id WXNServiceCenter(void) {
    Class msc = NSClassFromString(@"MMServiceCenter");
    if (!msc) return nil;
    for (NSString *n in @[ @"defaultCenter", @"sharedInstance", @"sharedCenter",
                           @"defaultServiceCenter", @"GlobalInstance" ]) {
        SEL s = NSSelectorFromString(n);
        if (![msc respondsToSelector:s]) continue;
        id v = nil;
        @try { v = ((id (*)(id, SEL))objc_msgSend)((id)msc, s); }
        @catch (__unused NSException *e) { v = nil; }
        if (v) {
            WXN_ALOG(@"MMServiceCenter 用 +%@ 取到了", n);
            return v;
        }
    }
    // 没有现成入口时，把它的类方法列出来，下一版直接按名字调
    unsigned int n = 0;
    Method *ms = class_copyMethodList(object_getClass(msc), &n);
    NSMutableArray *names = [NSMutableArray array];
    for (unsigned int i = 0; i < n; i++) [names addObject:NSStringFromSelector(method_getName(ms[i]))];
    if (ms) free(ms);
    WXN_ALOG(@"MMServiceCenter 没有单例入口，类方法有：%@", [names componentsJoinedByString:@" "]);
    return nil;
}

static void WXNTryGrabLN(NSString *why) {
    if (gLN) return;
    Class ln = NSClassFromString(@"MMLocalNotificationMgr");
    if (!ln) {
        WXN_ALOG(@"没有 MMLocalNotificationMgr 这个类");
        return;
    }
    id center = WXNServiceCenter();
    if (!center) return;
    SEL g = NSSelectorFromString(@"getService:");
    if (![center respondsToSelector:g]) {
        WXN_ALOG(@"MMServiceCenter 没有 getService:");
        return;
    }
    id svc = nil;
    @try { svc = ((id (*)(id, SEL, Class))objc_msgSend)(center, g, ln); }
    @catch (__unused NSException *e) { svc = nil; }
    if (svc) {
        WXN_ALOG(@"%@@ 时从服务里提到了 MMLocalNotificationMgr", why);
        WXNGrabLN(svc);
    } else {
        WXN_ALOG(@"%@@ 时服务里还没有 MMLocalNotificationMgr", why);
    }
}

// 微信向服务容器要东西的时候顺手看一眼，正好给它时就抓住
static id gMsgMgr = nil;   // 2.32：CMessageMgr 真身（角标同步用）

static id WXNGetServiceHook(id self, SEL _cmd, Class cls) {
    id svc = gOrigGetService ? gOrigGetService(self, _cmd, cls) : nil;
    if (svc && cls == NSClassFromString(@"MMLocalNotificationMgr")) WXNGrabLN(svc);
    // 2.32：微信自己来拿 CMessageMgr 时顺手抓真身（getService 会给包装对象，
    // 直接调拿不到能响应 GetUnReadCount 的实例）
    if (svc && cls == NSClassFromString(@"CMessageMgr") && gMsgMgr != svc) {
        gMsgMgr = svc;
        WXN_ALOG(@"[角标同步] 抓到 CMessageMgr 真身：%@", NSStringFromClass(object_getClass(svc)));
    }
    return svc;
}

// 只在“假装后台”的窗口内生效，窗口一关立刻回真实值
static BOOL WXNIsForegroundHook(id self, SEL _cmd) {
    if (gFakeBG) {
        if (CFAbsoluteTimeGetCurrent() - gLastStateDump > 1.0) {
            gLastStateDump = CFAbsoluteTimeGetCurrent();
            WXN_ALOG(@"  [假装后台] -isForeground 被问了，回答 NO");
        }
        return NO;
    }
    return gOrigIsForeground ? gOrigIsForeground(self, _cmd) : YES;
}

static BOOL WXNAppMonitorBGHook(id self, SEL _cmd) {
    if (gFakeBG) return YES;
    return gOrigAppMonitorBG ? gOrigAppMonitorBG(self, _cmd) : NO;
}

static void WXNInstallCognitionHooks(void) {
    Class app = NSClassFromString(@"MicroMessengerAppDelegate");
    if (app) {
        WXNSwizzle(app, @"isForeground", (IMP)WXNIsForegroundHook, &gOrigIsForeground);
    } else {
        WXN_ALOG(@"没有 MicroMessengerAppDelegate");
    }

    Class mon = NSClassFromString(@"AppMonitorImpl");
    if (mon) {
        WXNSwizzle(mon, @"IsAppInBackground", (IMP)WXNAppMonitorBGHook, &gOrigAppMonitorBG);
    } else {
        WXN_ALOG(@"没有 AppMonitorImpl");
    }

    // 以后微信再要这个服务时能抓到
    Class msc = NSClassFromString(@"MMServiceCenter");
    if (msc) WXNSwizzle(msc, @"getService:", (IMP)WXNGetServiceHook, &gOrigGetService);

    // 微信的版本号很关键：字段名对不上时得知道是哪个版本
    WXN_ALOG(@"微信版本=%@", [[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"] ?: @"(取不到)");
}

// 取实例 / 读状态：只能在 App 真的起来之后调，构造器里会太早
static void WXNLNInit(id self, SEL _cmd) {
    WXNGrabLN(self);
    WXN_ALOG(@"微信服务启动：MMLocalNotificationMgr（当前认知 后台=%d）", (int)WXNReadLNBG());
    if (gOrigLNInit) gOrigLNInit(self, _cmd);
}

static void WXNLNShowPush3(id self, SEL _cmd, id wrap, id ident, id fireDate,
                           BOOL voip, BOOL silent) {
    WXNGrabLN(self);
    if (gFakeBG) WXNCognitionForce(YES);
    WXN_ALOG(@"微信要发本地推送（全参数）voip=%d silent=%d 认知后台=%d id=%@",
             (int)voip, (int)silent, (int)WXNReadLNBG(), ident);
    if (gOrigLNShowPush3) gOrigLNShowPush3(self, _cmd, wrap, ident, fireDate, voip, silent);
}

static void WXNInstallLocalNotificationProbe(void) {
    Class c = NSClassFromString(@"MMLocalNotificationMgr");
    if (!c) {
        WXN_ALOG(@"本地通知探针：没有 MMLocalNotificationMgr 这个类");
        return;
    }
    // 只留两个真正有用的：onServiceInit 是抓实例最早的时机，
    // ShowPush 那一条里有一句"坐实认知"，其余全是日志，删掉。
    {
        Method m1 = class_getInstanceMethod(c, NSSelectorFromString(@"showPushWithMessageWrap:identifier:fireDate:isFromVoipPush:shouldSilent:"));
        if (m1) {
            char *rt = method_copyReturnType(m1);
            WXN_ALOG(@"[类型侦察] showPush3 返回类型=%s", (rt ? rt : "?"));
            free(rt);
        }
    }
    BOOL a = WXNSwizzle(c, @"onServiceInit", (IMP)WXNLNInit, &gOrigLNInit);
    BOOL g = WXNSwizzle(c,
        @"showPushWithMessageWrap:identifier:fireDate:isFromVoipPush:shouldSilent:",
        (IMP)WXNLNShowPush3, &gOrigLNShowPush3);
    WXN_ALOG(@"本地通知钩子：init=%@ 发push=%@", a ? @"已挂" : @"没挂", g ? @"已挂" : @"没挂");
}

static void WXNEndFakeBackground(NSString *why) {
    if (!gFakeBG) return;
    gFakeBG = NO;
    WXNCognitionRestore();
    WXN_ALOG(@"认知实验结束（%@）", why);
}

// 在把消息交回微信之前调用：先骗它一会儿，看它会不会自己发通知
static void WXNBeginFakeBackground(NSString *why) {
    if (gFakeBG) return;

    gNativePostsAtStart = gNativePosts;

    // 2.10：不再二选一。applicationState、isForeground、IsAppInBackground、
    // m_isInBackground 四处一起翻，窗口只有 2.5 秒，结束后全部回真实值。
    UIApplication *app = [UIApplication sharedApplication];
    if (app) {
        WXNInstallFakeBG();
        NSInteger real = gOrigAppState ? gOrigAppState(app, @selector(applicationState))
                                       : UIApplicationStateActive;
        if (real == UIApplicationStateBackground) {
            WXN_ALOG(@"微信真的在后台，交给它自己（%@）", why);
            return;
        }
        gRealAppState = real;
    } else {
        gRealAppState = UIApplicationStateActive;
    }

    WXNTryGrabLN(why);
    WXN_ALOG(@"认知实验：%@（LN=%@ 改前 后台=%d）", why, gLN ? @"拿到" : @"没拿到",
             (int)WXNReadLNBG());
    WXNCognitionForce(YES);

    gFakeBG = YES;
    gFakeUntil = CFAbsoluteTimeGetCurrent() + 6.0;   // willPresent 可能晚到，窗口单独放宽
    int gen = ++gFakeBGGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       if (gen != gFakeBGGen || !gFakeBG) return;
                       WXNEndFakeBackground(@"2.5 秒到点");
                   });
}

static IMP gOrigAddRequest;

// 把每一条投递都记下来：能分清是微信自己发的、还是本插件补的
static void WXNAddRequest(id self, SEL _cmd, id req, id handler) {
    @try {
        NSString *rid = [req valueForKey:@"identifier"];
        if (rid && ![rid hasPrefix:@"wxn-"]) {
            __sync_fetch_and_add(&gNativePosts, 1);
            WXN_ALOG(@"[微信自己投递] id=%@ title=%@", rid, [req valueForKey:@"content"] ?
                     [[req valueForKey:@"content"] valueForKey:@"title"] : @"");
        }
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

static IMP gOrigUnReadChange;   // 2.31
// 2.36：清零路径探针——开保活时 closeMainFrameWithoutReset 跑没跑？无参方法，安全。
static IMP gOrigCloseMainFrame;
static void WXNCloseMainFrameHook(id self, SEL _cmd);
static void WXNUnReadChangeHook(id self, SEL _cmd, id a1);

// 2.34：8.0.79 静态分析实锤——角标真链在 NotificationActionsMgr，
// 清零点在 -[MicroMessengerAppDelegate closeMainFrameWithoutReset]（"User exit"）。
// 探针：只记日志不干预。用 IMP 直调转发，签名固定不依赖 method 编码。
static IMP gOrigIconCountChange;    // 实例方法 onAppIconTotalUnreadCountChange:
static IMP gOrigBadgeSet;           // 类方法   +setApplicationIconBadgeNumber:
static void WXNIconCountChangeHook(id self, SEL _cmd, void *a1);
static void WXNBadgeSetHook(id self, SEL _cmd, NSInteger n);
// 2.43：NotificationActionsMgr 单例——ivar 0x20（int）= 微信自己维护的总未读
// （8.0.79 反汇编：onAppIconTotalUnreadCountChange 链路 ldr w10,[x0,#0x20] → "set count %u"）
static id gNAMInstance = nil;

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
            char *rt = method_copyReturnType(m);
            WXN_ALOG(@"已挂 %@ 返回类型=%s", name, (rt ? rt : "?"));
            free(rt);
            gOrigMap[name] = [NSValue valueWithPointer:orig];
            method_setImplementation(m, (IMP)WXNMsgHook2);
        }
        if (![gHookNames containsObject:name]) [gHookNames addObject:name];
        any = YES;
    }

    {
        // 2.31：未读变更事件——钩它做角标同步（忠实转发）
        Method mu = class_getInstanceMethod(cls, NSSelectorFromString(@"AsyncOnUnReadChange:"));
        if (mu) {
            IMP origU = method_getImplementation(mu);
            if (origU != (IMP)WXNUnReadChangeHook) {
                gOrigUnReadChange = origU;
                method_setImplementation(mu, (IMP)WXNUnReadChangeHook);
                WXN_ALOG(@"已挂 AsyncOnUnReadChange:（角标同步）");
            }
        } else {
            WXN_ALOG(@"没有 AsyncOnUnReadChange:，角标同步走离开时兜底");
        }
    }
    NSString *three = @"AsyncOnAddMsgForSession:MsgWrap:NewMsgArriveNotify:";
    {
        Method m3 = class_getInstanceMethod(cls, NSSelectorFromString(three));
        if (m3) {
            char *rt = method_copyReturnType(m3);
            WXN_ALOG(@"[类型侦察] %@ 返回类型=%s", three, (rt ? rt : "?"));
            free(rt);
        }
    }
    any |= WXNSwizzle(cls, three, (IMP)WXNForSessionNotify, &gOrigForSessionNotify);
    if (gOrigForSessionNotify && ![gHookNames containsObject:three]) [gHookNames addObject:three];

    // 2.34：角标真链探针（NotificationActionsMgr）
    {
        Class nam = NSClassFromString(@"NotificationActionsMgr");
        if (!nam) {
            WXN_ALOG(@"[角标探针] 没有 NotificationActionsMgr");
        } else {
            Method m1 = class_getInstanceMethod(nam, NSSelectorFromString(@"onAppIconTotalUnreadCountChange:"));
            if (m1) {
                IMP o1 = method_getImplementation(m1);
                if (o1 != (IMP)WXNIconCountChangeHook) {
                    gOrigIconCountChange = o1;
                    method_setImplementation(m1, (IMP)WXNIconCountChangeHook);
                    WXN_ALOG(@"[角标探针] 已挂 -onAppIconTotalUnreadCountChange:");
                }
            } else {
                WXN_ALOG(@"[角标探针] 没有 -onAppIconTotalUnreadCountChange:");
            }
            Method m2 = class_getClassMethod(nam, NSSelectorFromString(@"setApplicationIconBadgeNumber:"));
            if (m2) {
                IMP o2 = method_getImplementation(m2);
                if (o2 != (IMP)WXNBadgeSetHook) {
                    gOrigBadgeSet = o2;
                    method_setImplementation(m2, (IMP)WXNBadgeSetHook);
                    WXN_ALOG(@"[角标探针] 已挂 +setApplicationIconBadgeNumber:");
                }
            } else {
                WXN_ALOG(@"[角标探针] 没有 +setApplicationIconBadgeNumber:");
            }
        }
    }
    // 2.36：清零路径探针
    {
        Class ad = NSClassFromString(@"MicroMessengerAppDelegate");
        Method m3 = ad ? class_getInstanceMethod(ad, NSSelectorFromString(@"closeMainFrameWithoutReset")) : NULL;
        if (m3) {
            IMP o3 = method_getImplementation(m3);
            if (o3 != (IMP)WXNCloseMainFrameHook) {
                gOrigCloseMainFrame = o3;
                method_setImplementation(m3, (IMP)WXNCloseMainFrameHook);
                WXN_ALOG(@"[角标探针] 已挂 -closeMainFrameWithoutReset");
            }
        } else {
            WXN_ALOG(@"[角标探针] 没有 -closeMainFrameWithoutReset（ad=%@）",
                     ad ? @"有" : @"无");
        }
    }

    // 2.53：会话级记账——挂 ClearUnRead:FromID:ToID:
    if (!gSessionUnread) gSessionUnread = [NSMutableDictionary dictionary];
    {
        Method mc = class_getInstanceMethod(cls, NSSelectorFromString(@"ClearUnRead:FromID:ToID:"));
        if (mc) {
            IMP oc = method_getImplementation(mc);
            if (oc != (IMP)WXNClearUnReadHook) {
                gOrigClearUnRead = oc;
                method_setImplementation(mc, (IMP)WXNClearUnReadHook);
                WXN_ALOG(@"[计数] 已挂 ClearUnRead:FromID:ToID:");
            }
        } else {
            WXN_ALOG(@"[计数] 没有 ClearUnRead:FromID:ToID:");
        }
    }

    return any;
}

// 2.12：跟着 SpringBoard 的状态文件走。手指不再参与判断，
// 但“人回到微信”这件事还得知道——用来清角标、写一条“回来了”的日志。
static BOOL gWasInWeChat = NO;

// 2.15：走到别的 App 时自动投一条探针，专验证那件还没验证的事——
// 微信被 Immortalizer 认定为前台时，willPresent 里返回 Banner 到底画不画得出来。
// 2.31：角标跟真实未读——读 CMessageMgr 的 GetUnReadCount，写到图标角标。
// 2.40：诚实窗口已被实证证伪（两轮离开窗口内微信零动作，回调型感知），
// 撤掉等待，离开即刻代笔；采样失败必须打出异常详情（不能再吞）。
// 2.41：8.0.80 实锤——无参 GetUnReadCount 不存在（unrecognized selector），
// 方法清单里是带参的 GetUnReadCount:。按候选顺序试，命中即缓存不再重复试。
// 2.42：GetUnReadCount:(0) 口径存疑（有未读时也返 0）——离开时全变体测量
// 打日志，锁定正确口径前保守写：只有变体 >0 才写角标，全 0 不碰（不再把
// 微信自己写好的未读角标清掉）。
static NSInteger gUnreadSelIdx = -1;   // -1=未定 0=GetUnReadCount: 1=无参 2=GetUnReadCount:CreateTimeLargerThan:
static NSInteger WXNTryUnreadVariants(id obj) {
    @try {
        if (gUnreadSelIdx == 0 || gUnreadSelIdx == -1) {
            NSInteger v = (NSInteger)((unsigned int (*)(id, SEL, NSInteger))objc_msgSend)(obj, @selector(GetUnReadCount:), (NSInteger)0);
            if (gUnreadSelIdx == -1) { gUnreadSelIdx = 0; WXN_ALOG(@"[未读采样] 命中 GetUnReadCount: -> %ld", (long)v); }
            return v;
        }
    } @catch (NSException *e) {
        if (gUnreadSelIdx == -1) WXN_ALOG(@"[未读采样] GetUnReadCount: 不通：%@", e.reason);
    }
    @try {
        if (gUnreadSelIdx == 1 || gUnreadSelIdx == -1) {
            NSInteger v = (NSInteger)((unsigned int (*)(id, SEL))objc_msgSend)(obj, @selector(GetUnReadCount));
            if (gUnreadSelIdx == -1) { gUnreadSelIdx = 1; WXN_ALOG(@"[未读采样] 命中 GetUnReadCount -> %ld", (long)v); }
            return v;
        }
    } @catch (NSException *e) {
        if (gUnreadSelIdx == -1) WXN_ALOG(@"[未读采样] GetUnReadCount 不通：%@", e.reason);
    }
    @try {
        if (gUnreadSelIdx == 2 || gUnreadSelIdx == -1) {
            NSInteger v = (NSInteger)((unsigned int (*)(id, SEL, NSInteger, NSInteger))objc_msgSend)(obj, @selector(GetUnReadCount:CreateTimeLargerThan:), (NSInteger)0, (NSInteger)0);
            if (gUnreadSelIdx == -1) { gUnreadSelIdx = 2; WXN_ALOG(@"[未读采样] 命中 GetUnReadCount:CreateTimeLargerThan: -> %ld", (long)v); }
            return v;
        }
    } @catch (NSException *e) {
        if (gUnreadSelIdx == -1) WXN_ALOG(@"[未读采样] GetUnReadCount:CreateTimeLargerThan: 不通：%@", e.reason);
    }
    return -1;
}
static NSInteger WXNTryUnread(id obj) {
    if (!obj) return -1;
    return WXNTryUnreadVariants(obj);
}

static id gMsgMgrReal = nil;

static NSInteger WXNUnreadTotal(void) {
    id w = gMsgMgr;
    if (!w) return -1;
    NSInteger v = WXNTryUnread(w);
    if (v >= 0) { gMsgMgrReal = w; return v; }
    if (gMsgMgrReal) { v = WXNTryUnread(gMsgMgrReal); if (v >= 0) return v; }
    // 包装器转发不通：翻它的 ivar 找内层真身
    unsigned int n = 0;
    Ivar *ivs = class_copyIvarList(object_getClass(w), &n);
    for (unsigned int i = 0; i < n; i++) {
        id inner = object_getIvar(w, ivs[i]);
        if ([inner isKindOfClass:[NSObject class]] && inner != w) {
            NSInteger r = WXNTryUnread(inner);
            if (r >= 0) { gMsgMgrReal = inner; free(ivs); return r; }
        }
    }
    free(ivs);
    return -1;
}

static NSInteger gLastBadgeWritten = -999;

static void WXNBadgeWriteUnread(NSInteger unread, NSString *why) {
    if (unread < 0 || unread == gLastBadgeWritten) return;
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return;
    @try {
        [app setApplicationIconBadgeNumber:unread];
        gLastBadgeWritten = unread;
        WXN_ALOG(@"角标同步=%ld（%@）", (long)unread, why ?: @"");
    } @catch (__unused NSException *e) {}
}

static void WXNBadgeSyncToUnread(NSString *why) {
    // 2.31：双采样——事件触发时内部计数可能还没落，立即读一次 + 0.5 秒复核
    WXNBadgeWriteUnread(WXNUnreadTotal(), why);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       WXNBadgeWriteUnread(WXNUnreadTotal(), [why stringByAppendingString:@"+0.5s"]);
                   });
}

static void WXNUnReadChangeHook(id self, SEL _cmd, id a1) {
    // 2.52：拆掉 BadSync——GetUnReadCount: 口径错误（有未读也返 0），每次回微信
    // 都把微信写好的角标清掉，是「没读被清/读完不清」混乱的真正元凶。
    // 回调只留转发，不再写角标。
    // 2.53：后台链路的未读变化会走 NAM 回调锚定计数；这里把会话债清掉
    //（后台同步也会清会话未读，防止重复还债）。
    if (gOrigUnReadChange) ((void (*)(id, SEL, id))gOrigUnReadChange)(self, _cmd, a1);
    if ([gSessionUnread count]) {
        WXN_ALOG(@"[计数] UnReadChange：清空会话债（%@）", gSessionUnread);
        [gSessionUnread removeAllObjects];
    }
}

// 2.53：用户在微信里读掉一个会话 → 还债
static void WXNClearUnReadHook(id self, SEL _cmd, id from, id to) {
    if (gOrigClearUnRead) ((void (*)(id, SEL, id, id))gOrigClearUnRead)(self, _cmd, from, to);
    NSString *sess = [from isKindOfClass:[NSString class]] ? from : nil;
    NSInteger debt = sess ? [gSessionUnread[sess] integerValue] : 0;
    if (debt > 0) {
        gNAMCount -= debt;
        gSessionUnread[sess] = @0;
        WXN_ALOG(@"[计数] ClearUnRead 还债 %ld（会话 %@）→ 总未读 %ld", (long)debt, sess, (long)gNAMCount);
    } else if (sess) {
        // 读的会话没记过账（后台来的消息或微信自己的未读）：计数变脏
        if (gNAMCount > 0) {
            gNAMCount = -1;
            WXN_ALOG(@"[计数] ClearUnRead 会话 %@ 无账可还，计数标脏（退出不写）", sess);
        }
    }
}

// 2.34：角标真链探针
// 2.35：参数不是 ObjC 对象（反汇编 ldr w10,[x0,#0x20] 是整数），绝不能碰。
// 只打"触发了"，盲转发原始寄存器。
// 2.45：反汇编实锤——onAppIconTotalUnreadCountChange: 的参数 x2 就是总未读数
// （方法内 mov x19,x2 … cmp applicationState,#2 … setApplicationIconBadgeNumber:(x19)）。
// 钩子直接捕获它，退出时写这个值 = 微信自己的口径。
static void WXNIconCountChangeHook(id self, SEL _cmd, void *a1) {
    if (self && !gNAMInstance) gNAMInstance = self;
    gNAMCount = (NSInteger)(uintptr_t)a1;
    WXN_ALOG(@"[角标探针] onAppIconTotalUnreadCountChange: 未读数=%ld self=%@",
             (long)gNAMCount, self ? NSStringFromClass(object_getClass(self)) : @"?");
    // 2.46：8.0.79 存根显示 self->0x20 = 计数数组指针（按类型索引取值）。
    // 倾倒前 16 个 int，对照参数找"总和"在哪个格子。
    if (self) {
        void *arr = *(void **)((char *)(__bridge void *)self + 0x20);
        if (arr) {
            NSInteger s = 0;
            NSMutableString *dump = [NSMutableString string];
            for (int i = 0; i < 16; i++) {
                unsigned int v = *(unsigned int *)((char *)arr + i * 4);
                s += (NSInteger)(int)v;
                [dump appendFormat:@"%d,", (int)v];
            }
            WXN_ALOG(@"[角标探针] 计数数组=%@ sum=%ld", dump, (long)s);
        } else {
            WXN_ALOG(@"[角标探针] 计数数组指针为空");
        }
    }
    if (gOrigIconCountChange) ((void (*)(id, SEL, void *))gOrigIconCountChange)(self, _cmd, a1);
}

// 2.51：倾倒 NAM 单例 ivar 表——计数累加器的宿主，找总未读字段
static void WXNDumpNAMIvars(void) {
    if (!gNAMInstance) { WXN_ALOG(@"[ivar倾倒NAM] 单例未抓到"); return; }
    unsigned int n = 0;
    Ivar *ivs = class_copyIvarList(object_getClass(gNAMInstance), &n);
    NSMutableString *dump = [NSMutableString string];
    for (unsigned int i = 0; i < n; i++) {
        const char *nm = ivar_getName(ivs[i]);
        ptrdiff_t off = ivar_getOffset(ivs[i]);
        const char *ty = ivar_getTypeEncoding(ivs[i]);
        void *base = (char *)(__bridge void *)gNAMInstance + off;
        NSString *shown = @"?";
        if (ty && (ty[0]=='q'||ty[0]=='l'||ty[0]=='i')) {
            shown = [NSString stringWithFormat:@"%lld", (long long)(ty[0]=='i' ? *(int*)base : *(long long*)base)];
        } else if (ty && (ty[0]=='Q'||ty[0]=='L'||ty[0]=='I')) {
            shown = [NSString stringWithFormat:@"%llu", (unsigned long long)(ty[0]=='I' ? *(unsigned int*)base : *(unsigned long long*)base)];
        } else if (ty && ty[0]=='@') {
            void *p = *(void**)base;
            shown = p ? NSStringFromClass(object_getClass((__bridge id)p)) : @"nil";
        } else if (ty && ty[0]=='B') {
            shown = (*(BOOL*)base) ? @"YES" : @"NO";
        }
        [dump appendFormat:@"%s@%ld=%@|", nm ? nm : "?", (long)off, shown];
    }
    if (ivs) free(ivs);
    for (NSInteger i = 0; i < (NSInteger)((dump.length + 1199) / 1200); i++) {
        NSRange r = NSMakeRange(i*1200, MIN(1200, dump.length - i*1200));
        WXN_ALOG(@"[ivar倾倒NAM%@] %@", i>0 ? @"续" : @"", [dump substringWithRange:r]);
    }
}

static void WXNBadgeSetHook(id self, SEL _cmd, NSInteger n) {
    // 2.39：诚实窗口期内微信自己写角标 = 原生清理链跑起来了，记下来
    gWeChatWroteBadge = YES;
    WXN_ALOG(@"[角标探针] +setApplicationIconBadgeNumber:%ld（%@）", (long)n,
             self ? NSStringFromClass((Class)self) : @"?");
    if (gOrigBadgeSet) ((void (*)(id, SEL, NSInteger))gOrigBadgeSet)(self, _cmd, n);
}

// 2.36：清零路径探针——只记触发与当时认知，不干预
static void WXNCloseMainFrameHook(id self, SEL _cmd) {
    WXN_ALOG(@"[角标探针] closeMainFrameWithoutReset 触发 self=%@ 认知后台=%d",
             self ? NSStringFromClass(object_getClass(self)) : @"?",
             (int)WXNReadLNBG());
    if (gOrigCloseMainFrame) ((void (*)(id, SEL))gOrigCloseMainFrame)(self, _cmd);
}

// 2.30：未读数侦察——找微信内部"总未读"的真实来源，
// 给角标跟未读同步做证据。只在 debug 开时跑一次。
static void WXNDiagUnread(void) {
    @autoreleasepool {
        Class mgr = NSClassFromString(@"CMessageMgr");
        if (!mgr) { WXN_ALOG(@"[未读侦察] 没有 CMessageMgr"); return; }
        id center = WXNServiceCenter();
        id inst = nil;
        if (center && [center respondsToSelector:@selector(getService:)]) {
            @try { inst = ((id (*)(id, SEL, Class))objc_msgSend)(center, @selector(getService:), mgr); }
            @catch (__unused NSException *e) { inst = nil; }
        }
        WXN_ALOG(@"[未读侦察] 实例=%@", inst ? NSStringFromClass(object_getClass(inst)) : @"nil");
        unsigned int n = 0;
        Method *ms = class_copyMethodList(mgr, &n);
        NSMutableArray *hits = [NSMutableArray array];
        for (unsigned int i = 0; i < n; i++) {
            NSString *name = NSStringFromSelector(method_getName(ms[i]));
            NSString *low = name.lowercaseString;
            if ([low containsString:@"unread"] || [low containsString:@"nread"]) [hits addObject:name];
        }
        free(ms);
        WXN_ALOG(@"[未读侦察] CMessageMgr 方法命中 %lu 个：%@", (unsigned long)hits.count,
                 WXNTrim([hits componentsJoinedByString:@", "], 600) ?: @"(无)");
        if (!inst) { WXN_ALOG(@"[未读侦察] 没有实例，ivar 与试调跳过"); return; }
        unsigned int iv = 0;
        Ivar *ivs = class_copyIvarList(mgr, &iv);
        NSMutableArray *ihits = [NSMutableArray array];
        for (unsigned int i = 0; i < iv; i++) {
            const char *nm = ivar_getName(ivs[i]);
            if (!nm) continue;
            NSString *name = @(nm);
            NSString *low = name.lowercaseString;
            if ([low containsString:@"unread"] || [low containsString:@"nread"]) {
                id v = object_getIvar(inst, ivs[i]);
                [ihits addObject:[NSString stringWithFormat:@"%@=%@", name, v ?: @"nil"]];
            }
        }
        free(ivs);
        WXN_ALOG(@"[未读侦察] ivar 命中 %lu 个：%@", (unsigned long)ihits.count,
                 WXNTrim([ihits componentsJoinedByString:@", "], 600) ?: @"(无)");
        // 试调无参、名字像取数的
        for (NSString *name in hits) {
            if ([name containsString:@":"]) continue;
            SEL sel = NSSelectorFromString(name);
            if (![inst respondsToSelector:sel]) continue;
            NSMethodSignature *sig = [inst methodSignatureForSelector:sel];
            if (sig.numberOfArguments != 2) continue;
            const char *rt = [sig methodReturnType];
            if (rt[0] == 'Q' || rt[0] == 'q' || rt[0] == 'I' || rt[0] == 'i' || rt[0] == 'l') {
                long long v = 0;
                if (rt[0] == 'Q' || rt[0] == 'I') v = (long long)((unsigned long (*)(id, SEL))objc_msgSend)(inst, sel);
                else v = ((long long (*)(id, SEL))objc_msgSend)(inst, sel);
                WXN_ALOG(@"[未读侦察] 试调 %@ -> %lld", name, v);
            }
        }
    }
}

static void WXNWatchFront(void) {
    @try {
        NSString *why = nil;
        BOOL in = WXNInWeChatSafe(&why);
        if (in != gWasInWeChat) {
            gWasInWeChat = in;
            WXN_ALOG(@"前台变化：%@（%@）", in ? @"回到微信" : @"离开微信", why ?: @"");
            if (!in) {
                // 2.37：交还原主——触发微信原生退出清理链（清角标等），
                // 不再自己写角标（WXNBadgeSyncToUnread 撤出离开路径）
                dispatch_async(dispatch_get_main_queue(), ^{
                    WXNNativeExitCleanup();
                });
            }
            if (in) {
                // 2.29：进微信不再清主屏角标——角标跟真实未读走，
                // 由微信自己的未读同步逻辑管理（读了才会归零）
            }
        }
    } @catch (__unused NSException *e) {}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       WXNWatchFront();
                   });
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



// 再补一层零风险的探针：只听系统广播，不改任何行为。
// 注意：只有“离开”类广播才算证据（known=1），回来类广播满天飞（启动时就一堆），
// 不能拿它证明什么，否则 known 一上来就是 1，人永远被当成在微信里。
static NSMutableArray *gNoticeTokens = nil;

// ---------------------------------------------------------------------------
// SpringBoard 侧守卫（2.14）
//
// 同一个 dylib 也会被注进 com.apple.springboard。那里没有沙盒，
// 问「谁在最前面」是真能拿到答案的；而 Immortalizer 骗的是 App 自己，
// 骗不到 SpringBoard。所以让它每半秒把答案写进一个文件，微信只负责读。
//
// 2.13 的教训：__CFStringAppendFormatCore → objc_opt_respondsToSelector
// 读 0x10000003，SIGSEGV，SpringBoard 直接进安全模式。从 dlsym 摸出来的
// 东西不一定是函数，返回值也不一定是我们以为的类型。现在的规矩：
//   1) 返回值先验地址（>= 4GB、8 字节对齐），可疑就当没拿到；
//   2) 再用 CFGetTypeID 确认真是 CFString，才拷进栈上缓冲；
//   3) 哪个接口给过野指针就永久拉黑，不再调；
//   4) 全程 snprintf 拼字符串，绝不把未知对象塞进 %@。
// ---------------------------------------------------------------------------
static volatile int gFrontBusy = 0;
static volatile int gFrontHangs = 0;
static double gFrontLastWrite = 0;
static char *gFrontLastLine = NULL;
static BOOL gApiDead[3];          // 0=SBSCopy 1=SBStr 2=SBApp

static BOOL WXNPtrSane(const void *p) {
    uintptr_t v = (uintptr_t)p;
    return v >= 0x100000000ULL && (v & 0x7ULL) == 0;
}

// Bundle id 只可能是这些字符，别的一律当没拿到（不是拉黑，只是不用这个值）
static BOOL WXNLookLikeBundleID(const char *s) {
    size_t n = strlen(s);
    if (n < 3 || n > 127) return NO;
    if (!strchr(s, '.') || s[0] == '.' || s[n - 1] == '.') return NO;
    for (size_t i = 0; i < n; i++) {
        char c = s[i];
        BOOL ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                  (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_';
        if (!ok) return NO;
    }
    return YES;
}

// 0=没值，1=拿到，-1=野指针（这个接口以后别再用）
static int WXNCFStrCopy(const void *s, char *buf, size_t cap) {
    if (!s) return 0;
    if (!WXNPtrSane(s)) return -1;
    if (CFGetTypeID((CFTypeRef)s) != CFStringGetTypeID()) return -1;
    Boolean ok = CFStringGetCString((CFStringRef)s, buf, (CFIndex)cap, kCFStringEncodingUTF8);
    CFRelease((CFTypeRef)s);          // Copy 语义，+1
    if (!ok || !buf[0]) return 0;
    if (!WXNLookLikeBundleID(buf)) { buf[0] = 0; return 0; }
    return 1;
}

// SBSGetFrontmostApplication 这条路返回的是 SBApplication 对象
static BOOL WXNFrontAppBundle(char *buf, size_t cap) {
    void *fn = dlsym(RTLD_DEFAULT, "SBSGetFrontmostApplication");
    if (!fn) return NO;
    __unsafe_unretained id app = ((id (*)(void))fn)();
    if (!WXNPtrSane((__bridge const void *)app)) return NO;
    for (NSString *k in @[ @"displayIdentifier", @"bundleIdentifier" ]) {
        @try {
            __unsafe_unretained id v = [app valueForKey:k];
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) {
                const char *c = [(NSString *)v UTF8String];
                if (c && *c && WXNLookLikeBundleID(c)) { snprintf(buf, cap, "%s", c); return YES; }
            }
        } @catch (__unused NSException *e) {}
    }
    return NO;
}

// 微信的 Documents 目录。SpringBoard 有跨容器访问权，能拿到别人的沙盒路径；
// 拿不到（或者微信还没启动过）就只写 Preferences 那份。
static NSString *gWxDocs = nil;
static double gWxDocsTry = 0;

static NSString *WXNWeChatDocs(void) {
    if (gWxDocs) return gWxDocs;

    double now = [[NSDate date] timeIntervalSince1970];
    if (now - gWxDocsTry < 30.0) return nil;      // 失败别问太勤
    gWxDocsTry = now;

    Class cls = NSClassFromString(@"LSApplicationProxy");
    SEL f = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!cls || ![cls respondsToSelector:f]) return nil;

    id proxy = ((id (*)(id, SEL, id))objc_msgSend)(cls, f, @WXN_BUNDLE_ID);
    if (!proxy) return nil;

    NSURL *url = nil;
    for (NSString *k in @[ @"dataContainerURL", @"containerURL" ]) {
        SEL s = NSSelectorFromString(k);
        if (![proxy respondsToSelector:s]) continue;
        @try {
            id v = ((id (*)(id, SEL))objc_msgSend)(proxy, s);
            if ([v isKindOfClass:[NSURL class]]) { url = v; break; }
        } @catch (__unused NSException *e) {}
    }
    NSString *path = [url path];
    if (!path.length) return nil;

    NSString *docs = [path stringByAppendingPathComponent:@"Documents"];
    BOOL isDir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:docs isDirectory:&isDir] || !isDir) return nil;

    gWxDocs = docs;
    return docs;
}

static void WXNFrontTick(void) {
    char bundle[160] = "";
    const char *api = "?";
    int r;

    // 锁屏时最前台恒为 nil，微信那边只看 locked 这个字段，
    // 所以这一次私有 API 调用可以直接省掉
    BOOL locked = WXNDeviceLocked();
    if (locked) {
        api = "locked";
    } else {
        // 三条路依次试，哪条给出野指针就永久拉黑
        if (!gApiDead[0]) {
            void *fn = dlsym(RTLD_DEFAULT, "SBSCopyFrontmostApplicationDisplayIdentifier");
            if (fn) {
                r = WXNCFStrCopy(((const void *(*)(void))fn)(), bundle, sizeof bundle);
                if (r == 1) api = "SBSCopy";
                else if (r < 0) gApiDead[0] = YES;
            }
        }
        if (!bundle[0] && !gApiDead[1]) {
            void *fn = dlsym(RTLD_DEFAULT, "SBFrontmostApplicationDisplayIdentifier");
            if (fn) {
                r = WXNCFStrCopy(((const void *(*)(void))fn)(), bundle, sizeof bundle);
                if (r == 1) api = "SBStr";
                else if (r < 0) gApiDead[1] = YES;
            }
        }
        if (!bundle[0] && !gApiDead[2]) {
            if (WXNFrontAppBundle(bundle, sizeof bundle)) api = "SBApp";
        }
    }

    if (!bundle[0]) snprintf(bundle, sizeof bundle, "(nil)");
    for (char *p = bundle; *p; p++) {                 // 别让内容把分隔符搞乱
        if (*p == '|' || *p == '\n' || *p == '\r') *p = '_';
    }

    double ts = [[NSDate date] timeIntervalSince1970];
    char line[256];
    snprintf(line, sizeof line, "%s|%.3f|%d|0|%s", bundle, ts, (int)locked, api);

    // 值没变也至少 2 秒刷一次时间戳：微信那边超过 5 秒没更新就当守卫失联
    if (gFrontLastLine && strcmp(line, gFrontLastLine) == 0 && ts - gFrontLastWrite < 2.0) return;

    NSString *text = @(line);
    [text writeToFile:@WXN_FRONT_PATH atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    NSString *docs = WXNWeChatDocs();
    if (docs) {
        [text writeToFile:[docs stringByAppendingPathComponent:@"wxnotify.front"]
               atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }

    gFrontLastWrite = ts;
    free(gFrontLastLine);
    gFrontLastLine = strdup(line);
}

#define WXN_GUARD_MARK "/var/mobile/Library/Preferences/cn.qwq.wxnotify.guard"

// 上一次也是刚起来就死了：这一轮宁可没有数据，也不能再让 SpringBoard 进安全模式。
// 重装 deb 会删掉这个标记（postinst），就又能试一次。
static BOOL WXNGuardAllowed(void) {
    NSString *m = [NSString stringWithContentsOfFile:@WXN_GUARD_MARK
                                            encoding:NSUTF8StringEncoding error:NULL];
    m = [m stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([m isEqualToString:@"booting"]) {
        [@"dead" writeToFile:@WXN_GUARD_MARK atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return NO;
    }
    if ([m isEqualToString:@"dead"]) return NO;
    [@"booting" writeToFile:@WXN_GUARD_MARK atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    return YES;
}

static dispatch_source_t gFrontTimer = NULL;
static int  gFrontLockTok = -1;
static BOOL gFrontLocked = NO;

static void WXNFrontSetInterval(BOOL locked, BOOL fireSoon) {
    gFrontLocked = locked;
    if (!gFrontTimer) return;
    uint64_t iv = (locked ? 60ull : 1ull) * NSEC_PER_SEC;
    uint64_t first = fireSoon ? (100ull * NSEC_PER_MSEC) : iv;
    dispatch_source_set_timer(gFrontTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)first),
                              iv, 200ull * NSEC_PER_MSEC);
}

static void WXNFrontTick(void);

static void WXNFrontRun(void) {
    if (gFrontBusy) {
        if (++gFrontHangs > 4 && gFrontTimer) {
            dispatch_source_cancel(gFrontTimer);
            gFrontTimer = NULL;
        }
        return;
    }
    gFrontBusy = 1;
    @try { WXNFrontTick(); } @catch (__unused NSException *e) {}
    gFrontBusy = 0;

    // 锁屏通知万一漏了，跑完一拍自己纠回来
    BOOL locked = WXNDeviceLocked();
    if (locked != gFrontLocked) WXNFrontSetInterval(locked, NO);
}

static void WXNFrontWatchLock(dispatch_queue_t q) {
    int st = notify_register_dispatch("com.apple.springboard.lockstate", &gFrontLockTok, q, ^(int t) {
        uint64_t v = 0;
        BOOL locked = (notify_get_state(t, &v) == NOTIFY_STATUS_OK) && v != 0;
        if (locked) {
            // 先把 locked=1 落盘，微信那边就能立刻按"人不在"处理，
            // 然后降到 60 秒慢心跳
            if (!gFrontBusy) {
                gFrontBusy = 1;
                @try { WXNFrontTick(); } @catch (__unused NSException *e) {}
                gFrontBusy = 0;
            }
            WXNFrontSetInterval(YES, NO);
        } else {
            // 解锁：立刻写一次真实前台，别留空窗，之后按 1 秒走
            WXNFrontSetInterval(NO, YES);
        }
    });
    if (st != NOTIFY_STATUS_OK) gFrontLockTok = -1;
}

static void WXNFrontStart(void) {
    if (!WXNGuardAllowed()) return;

    dispatch_queue_t q = dispatch_queue_create("cn.qwq.wxnotify.front", NULL);
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    if (!t) return;
    gFrontTimer = t;

    // 锁屏 60 秒、解锁 1 秒：锁屏时不过是为了让状态文件别过期，
    // 解锁后才是真正要判断"人还在不在微信里"的时候。
    // 只改 interval，不用 suspend/resume——dispatch source 的挂起是引用计数，
    // 一次没配平就再也起不来，而且卡住时没有任何日志。
    gFrontLocked = WXNDeviceLocked();
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5ull * NSEC_PER_SEC)),
                              (gFrontLocked ? 60ull : 1ull) * NSEC_PER_SEC, 200ull * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(t, ^{ WXNFrontRun(); });
    dispatch_resume(t);

    // 解锁那一下必须当成事件来处理：只降频率的话，解锁开头会有
    // 最多一个周期的空窗，那时候用户往往正回到微信，会误弹。
    WXNFrontWatchLock(q);

    // 撑过 30 秒说明这一轮没炸，下次重启照常跑
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30ull * NSEC_PER_SEC)), q, ^{
        [@"ok" writeToFile:@WXN_GUARD_MARK atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    });
}

// 心跳：每 30 秒一行，看清「前台状态文件说的是谁」。
__attribute__((constructor))
static void WXNInit(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];

    // 2.12：同一个 dylib 也注进 SpringBoard，只干一件事——看着谁在最前面。
    // 这条分支里不写日志、不碰 UI、不碰任何微信的类，只开一个后台定时器。
    if ([bid isEqualToString:@"com.apple.springboard"]) {
        WXNFrontStart();
        return;
    }

    // 硬保险：不是微信就什么都不做
    if (![bid isEqualToString:@WXN_BUNDLE_ID]) return;

    gWxnStartAt = CFAbsoluteTimeGetCurrent();
    WXNLoadConfig();      // 先读配置：日志开关在这一步之后才生效
    WXN_ALOG(@"======== WxNotify %s 已加载 pid=%d ========", WXN_VERSION, (int)getpid());

    static int changedToken = -1;
    notify_register_dispatch(WXN_CHANGED_NOT, &changedToken, dispatch_get_main_queue(), ^(int t) {
        WXNLoadConfig();
    });

    WXNInstallLocalNotificationProbe();
    WXNInstallCognitionHooks();
    WXNWatchFront();
    WXNInstallWithRetry(0);
    WXNSetupWithRetry(0);

    // 8 秒补挂一次：有的版本类注册得晚，或者被别的插件盖回去了。
    // 自检通知只在这里、且只在 debug 打开时弹，日常版本一条都不弹。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       WXNInstallCognitionHooks();
                       WXNSetupPresentationHooks();
                   });

    // 20 秒再补一次，顺便把可能还没起来的 MMLocalNotificationMgr 抓到手
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       WXNTryGrabLN(@"启动 20 秒");
                       if (WXNDebug()) WXNDiagUnread();
                       WXNSetupPresentationHooks();
                   });
}
