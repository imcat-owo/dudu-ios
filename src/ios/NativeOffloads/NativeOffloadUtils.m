//
//  NativeOffloadUtils.m
//  MinisApp
//
//  Shared utilities for native offload CLI tools.
//

#import "NativeOffloadUtils.h"
#include "kernel/fs.h"
#include "fs/fd.h"
#include "fs/path.h"
#include <unistd.h>
#include <sys/select.h>

// ── Error code constants ──
NSString *const NOFF_ERR_AUTHORIZATION_DENIED       = @"authorization_denied";
NSString *const NOFF_ERR_AUTHORIZATION_NOT_DETERMINED = @"authorization_not_determined";
NSString *const NOFF_ERR_NOT_AVAILABLE              = @"not_available";
NSString *const NOFF_ERR_INVALID_ARGS               = @"invalid_args";
NSString *const NOFF_ERR_NO_DATA                    = @"no_data";
NSString *const NOFF_ERR_INTERNAL_ERROR             = @"internal_error";

// ── Argument helpers ──

NSString *_Nullable noff_find_arg(int argc, char **argv, const char *name) {
    for (int i = 1; i < argc - 1; i++) {
        if (strcmp(argv[i], name) == 0) {
            return [NSString stringWithUTF8String:argv[i + 1]];
        }
    }
    return nil;
}

BOOL noff_has_flag(int argc, char **argv, const char *name) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], name) == 0) return YES;
    }
    return NO;
}

NSString *_Nullable noff_get_subcommand(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (argv[i][0] != '-') {
            return [NSString stringWithUTF8String:argv[i]];
        }
        // Skip argument value for known option patterns (--key value)
        if (argv[i][0] == '-' && argv[i][1] == '-' && i + 1 < argc && argv[i + 1][0] != '-') {
            i++; // skip value
        }
    }
    return nil;
}

NSArray<NSString *> *noff_positional_args(int argc, char **argv) {
    NSMutableArray *args = [NSMutableArray array];
    BOOL foundSubcommand = NO;
    for (int i = 1; i < argc; i++) {
        if (argv[i][0] == '-') {
            // Skip option and its value
            if (argv[i][1] == '-' && i + 1 < argc && argv[i + 1][0] != '-') {
                i++;
            }
            continue;
        }
        if (!foundSubcommand) {
            foundSubcommand = YES;
            continue; // skip the subcommand itself
        }
        [args addObject:[NSString stringWithUTF8String:argv[i]]];
    }
    return args;
}

// ── Date parsing ──

NSDate *_Nullable noff_parse_date(NSString *str) {
    if (!str || str.length == 0) return nil;

    // Relative: -7d, -2h, -30m
    if ([str hasPrefix:@"-"] && str.length >= 2) {
        unichar unit = [str characterAtIndex:str.length - 1];
        NSString *numStr = [str substringWithRange:NSMakeRange(1, str.length - 2)];
        NSInteger num = [numStr integerValue];
        if (num > 0) {
            NSTimeInterval interval = 0;
            switch (unit) {
                case 'd': interval = num * 86400; break;
                case 'h': interval = num * 3600; break;
                case 'm': interval = num * 60; break;
                default: break;
            }
            if (interval > 0) {
                return [NSDate dateWithTimeIntervalSinceNow:-interval];
            }
        }
    }

    // ISO 8601 variants
    NSISO8601DateFormatter *iso = [[NSISO8601DateFormatter alloc] init];
    iso.formatOptions = NSISO8601DateFormatWithInternetDateTime
                      | NSISO8601DateFormatWithFractionalSeconds;
    NSDate *d = [iso dateFromString:str];
    if (d) return d;

    // Without fractional seconds
    iso.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    d = [iso dateFromString:str];
    if (d) return d;

    // Date-only or datetime without timezone
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.timeZone = [NSTimeZone localTimeZone];
    for (NSString *pattern in @[@"yyyy-MM-dd'T'HH:mm:ss",
                                 @"yyyy-MM-dd'T'HH:mm",
                                 @"yyyy-MM-dd"]) {
        fmt.dateFormat = pattern;
        d = [fmt dateFromString:str];
        if (d) return d;
    }

    return nil;
}

NSString *noff_format_date(NSDate *date) {
    if (!date) return @"";
    NSISO8601DateFormatter *fmt = [[NSISO8601DateFormatter alloc] init];
    fmt.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    fmt.timeZone = [NSTimeZone localTimeZone];
    return [fmt stringFromDate:date];
}

// ── JSON output ──

NSDictionary *noff_json_envelope(NSString *tool, NSString *action, id data) {
    return @{
        @"ok": @YES,
        @"tool": tool,
        @"action": action,
        @"data": data ?: [NSNull null],
        @"timestamp": noff_format_date([NSDate date]),
    };
}

// ── Error message humanizer [s2-27] ──
//
// Tool handlers frequently surface `error.localizedDescription` verbatim.
// For system-framework failures that text is an opaque Cocoa dump —
// "The operation couldn’t be completed. (kCLErrorDomain error 0.)" —
// which tells the calling model neither what KIND of problem occurred nor
// what to do next. Translate the recognizable raw-system signatures into
// a plain-language category plus a next step, keeping the original text
// appended for debugging.
//
// [s2-27fix] Signatures are DUMP FORMS ONLY. The first cut also matched
// bare words ("eventkit", "healthkit", "daemon", "jwt") wherever they
// appeared in the text, which misfired on the tools' own precise
// messages — the calendar --parent-id explanation mentions "EventKit",
// the HealthKit timeout text mentions "HealthKit" — and prepended a
// wrong category with wrong advice. Now translation triggers ONLY on:
//   • the parenthesized NSError dump trailer "(<Domain> error <code>.)",
//     with the category classified from that trailer's domain;
//   • NSURLError's fixed localized sentences (its typical form carries
//     no trailer);
//   • Cocoa's fixed "The operation couldn’t be completed" opener.
// Anything else — in particular every message a tool composed itself —
// passes through untouched. When a framework's real dump form is not
// known, prefer passing the original through over a guessed signature.

// Extract the domain from a "(<Domain> error <code>…)" dump trailer, or
// nil when the message carries no such trailer. Strict shape: "(" …
// " error " … a numeric code immediately after, ")" shortly after, and
// the domain token is a single spaceless word.
static NSString *noff_dump_domain(NSString *message) {
    NSUInteger len = message.length;
    NSUInteger pos = 0;
    while (pos < len) {
        NSRange open = [message rangeOfString:@"("
                                       options:0
                                         range:NSMakeRange(pos, len - pos)];
        if (open.location == NSNotFound) return nil;
        NSString *rest = [message substringFromIndex:open.location + 1];
        NSRange errTok = [rest rangeOfString:@" error "];
        if (errTok.location != NSNotFound && errTok.location > 0 &&
            errTok.location <= 80) {
            NSString *after =
                [rest substringFromIndex:errTok.location + errTok.length];
            unichar c0 = after.length > 0 ? [after characterAtIndex:0] : 0;
            BOOL numeric = (c0 >= '0' && c0 <= '9') ||
                (c0 == '-' && after.length > 1 &&
                 [after characterAtIndex:1] >= '0' &&
                 [after characterAtIndex:1] <= '9');
            NSRange close = [after rangeOfString:@")"];
            if (numeric && close.location != NSNotFound &&
                close.location <= 24) {
                NSString *domain = [rest substringToIndex:errTok.location];
                if ([domain rangeOfCharacterFromSet:
                        [NSCharacterSet whitespaceCharacterSet]].location ==
                    NSNotFound) {
                    return domain;
                }
            }
        }
        pos = open.location + 1;
    }
    return nil;
}

static NSString *noff_humanized_error_message(NSString *message) {
    if (message.length == 0) return message;
    NSString *lower = [message lowercaseString];
    NSString *domain = [noff_dump_domain(message) lowercaseString];

    NSString *category = nil;
    // Network FIRST: NSURLError dumps and its fixed localized sentences.
    // (In the first cut the WeatherKit branch ran first, so an offline
    // WeatherKit failure got filed under "check your Apple ID".)
    if ([domain containsString:@"nsurlerror"] ||
        [lower containsString:@"appears to be offline"] ||
        [lower containsString:@"not connected to the internet"] ||
        [lower containsString:@"network connection was lost"]) {
        category = @"网络不通：设备当前连不上网或连接中断。检查网络后重试。";
    } else if ([domain containsString:@"kclerror"]) {
        category = @"定位服务报错：系统没能给出位置。确认定位权限已开启、稍等片刻"
                    "重试；急用时可直接传经纬度参数绕过定位。";
    } else if ([domain containsString:@"weatherkit"]) {
        category = @"天气服务（WeatherKit）在系统侧校验或调用失败：多半是苹果服务端"
                    "或设备登录状态的问题，不是参数写错。等一两分钟重试；若一直"
                    "失败，检查系统时间是否准确、设备是否登录了 Apple ID。";
    } else if ([domain containsString:@"xpc"]) {
        category = @"系统后台服务（守护进程）暂时没响应：这是设备系统侧的问题，"
                    "不是参数写错。稍等片刻重试；持续失败可重启 App 或设备。";
    } else if (domain != nil ||
               [message hasPrefix:@"The operation couldn\u2019t be completed"]) {
        // Unrecognized domain, but unmistakably a raw Cocoa dump: the
        // trailer is there, or the message opens with Cocoa's fixed
        // localized opener (with the real U+2019 apostrophe — the first
        // cut compared against an ASCII apostrophe and never matched).
        category = @"系统返回了一条原始错误（不是参数写错）：先按原样重试一次；"
                    "若反复出现，把下面的原始报错原文反馈给用户排查。";
    }

    if (!category) return message;
    NSString *orig = message.length > 300
        ? [[message substringToIndex:300] stringByAppendingString:@"…"]
        : message;
    return [NSString stringWithFormat:@"%@（系统原始报错：%@）", category, orig];
}

NSDictionary *noff_json_error(NSString *tool, NSString *action,
                               NSString *code, NSString *message) {
    return @{
        @"ok": @NO,
        @"tool": tool,
        @"action": action,
        @"error": @{
            @"code": code,
            @"message": noff_humanized_error_message(message),
        },
        @"timestamp": noff_format_date([NSDate date]),
    };
}

void noff_emit_json(int fd, NSDictionary *dict, BOOL compact, BOOL quiet) {
    id output = dict;
    if (quiet) {
        // In quiet mode, emit only the "data" field for success, or "error" for failure
        if ([dict[@"ok"] boolValue]) {
            output = dict[@"data"];
        } else {
            output = dict[@"error"];
        }
    }

    if (!output || output == [NSNull null]) {
        dprintf(fd, "{}\n");
        return;
    }

    NSJSONWritingOptions opts = 0;
    if (!compact) {
        opts = NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys;
    }

    NSError *err = nil;
    NSData *json = nil;
    @try {
        json = [NSJSONSerialization dataWithJSONObject:output options:opts error:&err];
    } @catch (NSException *e) {
        NSLog(@"NativeOffloads: JSON serialization exception: %@", e.reason);
    }
    if (!json) {
        dprintf(fd, "{\"error\":\"json_serialization_failed\"}\n");
        return;
    }

    NSString *str = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    dprintf(fd, "%s\n", str.UTF8String);
}

// ── Help output ──

void noff_emit_help(int stderr_fd, NSString *helpText) {
    dprintf(stderr_fd, "%s\n", helpText.UTF8String);
}

// ── Main thread dispatch ──

id _Nullable noff_dispatch_main_sync(id _Nullable (^_Nonnull block)(void)) {
    if ([NSThread isMainThread]) {
        return block();
    }
    __block id result = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        result = block();
    });
    return result;
}

id _Nullable noff_dispatch_main_sync_timeout(NSTimeInterval timeoutSeconds,
                                              BOOL *_Nullable timedOut,
                                              id _Nullable (^_Nonnull block)(void)) {
    if (timedOut) *timedOut = NO;
    // Already on main: a bounded wait is impossible (we'd deadlock waiting on
    // ourselves) and also unnecessary — run inline, matching the unbounded variant.
    if ([NSThread isMainThread]) {
        return block();
    }

    // The result box is heap-allocated and captured by BOTH the async block and
    // this frame, so a late-running block after a timeout writes into a still-live
    // object rather than a dead stack slot.
    NSMutableArray *box = [NSMutableArray arrayWithCapacity:1];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        id r = block();
        @synchronized (box) { if (r) [box addObject:r]; }
        dispatch_semaphore_signal(sem);
    });

    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(timeoutSeconds * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(sem, deadline) != 0) {
        if (timedOut) *timedOut = YES;
        return nil;
    }
    @synchronized (box) { return box.firstObject; }
}

// ── Read stdin ──

// ── Guest stub creation ──

void noff_ensure_guest_stub(const char *guest_path) {
    // Ensure parent directories exist (e.g. /usr/local/bin)
    char parent[256];
    strncpy(parent, guest_path, sizeof(parent) - 1);
    parent[sizeof(parent) - 1] = '\0';

    // Walk through the path and mkdir each component
    for (char *p = parent + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            generic_mkdirat(AT_PWD, parent, 0755);
            *p = '/';
        }
    }

    // Create the stub file with execute permission.
    // O_CREAT without O_EXCL: if it already exists, just opens it.
    struct fd *fd = generic_open(guest_path, O_CREAT_ | O_WRONLY_, 0755);
    if (fd && !IS_ERR(fd)) {
        fd_close(fd);
    }
}

// ── Path resolution ──

NSString *_Nullable noff_resolve_host_path(NSString *guestPath) {
    if (guestPath.length == 0) return nil;

    // Idempotence guard [T-offload-double-path-translate]: exec_handler
    // (native_offload.c) translates every absolute-path argv entry
    // guest→host (bind mounts first, then fakefs data root) BEFORE the
    // in-process handler runs, so `--image <path>`-style arguments arrive
    // here already host-side. Re-mapping such a path nests it under the
    // data root a second time (…/data/private/var/…/data/…) and every
    // read/write on it fails with ENOENT. Any path already inside the app
    // sandbox or the shared app-group container is host-side — return it
    // unchanged. Genuine guest paths (constructed strings, stdin-derived
    // paths that never went through argv translation) still fall through
    // to the mapping below.
    NSString *home = NSHomeDirectory();
    NSString *privateHome = [@"/private" stringByAppendingString:home];
    if ([guestPath hasPrefix:home] || [guestPath hasPrefix:privateHome] ||
        [guestPath hasPrefix:@"/var/mobile/Containers/Shared/"] ||
        [guestPath hasPrefix:@"/private/var/mobile/Containers/Shared/"]) {
        return guestPath;
    }

    // Documents/alpine-rootfs/data/ is the fakefs data root
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dataRoot = [documents stringByAppendingPathComponent:@"alpine-rootfs/data"];

    // Strip leading "/" from guest path and append to host data root
    NSString *relative = guestPath;
    while ([relative hasPrefix:@"/"]) {
        relative = [relative substringFromIndex:1];
    }
    return [dataRoot stringByAppendingPathComponent:relative];
}

// ── Read stdin ──

NSString *_Nullable noff_read_stdin(int stdin_fd) {
    if (stdin_fd < 0) return nil;

    NSMutableData *data = [NSMutableData data];
    char buf[4096];
    ssize_t n;

    // Use select with a short timeout to check if data is available
    fd_set fds;
    struct timeval tv = { .tv_sec = 0, .tv_usec = 100000 }; // 100ms
    FD_ZERO(&fds);
    FD_SET(stdin_fd, &fds);

    while (select(stdin_fd + 1, &fds, NULL, NULL, &tv) > 0) {
        n = read(stdin_fd, buf, sizeof(buf));
        if (n <= 0) break;
        [data appendBytes:buf length:n];
        if (data.length > 1024 * 1024) break; // 1MB cap

        FD_ZERO(&fds);
        FD_SET(stdin_fd, &fds);
        tv.tv_sec = 0;
        tv.tv_usec = 50000; // 50ms for subsequent reads
    }

    if (data.length == 0) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

// ── ObjC exception safety ──

BOOL noff_try_objc(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return YES;
    } @catch (NSException *e) {
        NSLog(@"noff_try_objc: caught ObjC exception: %@ — %@", e.name, e.reason);
        return NO;
    }
}
