#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <mach/mach_time.h>
#import <sys/socket.h>
#import <sys/utsname.h>
#import <sys/sysctl.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <libproc.h>
#import <unistd.h>

static NSString * const BridgeVersion = @"0.2.0";

#pragma mark - Helpers

static id SafeValue(id object, NSString *key) {
    if (!object || !key) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id JSONValue(id value) {
    if (!value || value == NSNull.null) return NSNull.null;
    if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSArray.class] || [value isKindOfClass:NSDictionary.class]) return value;
    if ([value isKindOfClass:NSURL.class]) return [(NSURL *)value path] ?: [(NSURL *)value absoluteString] ?: @"";
    if ([value isKindOfClass:NSDate.class]) return @([(NSDate *)value timeIntervalSince1970]);
    return [value description] ?: @"";
}

static NSString *QueryPath(NSString *rawPath) {
    NSRange q = [rawPath rangeOfString:@"?"];
    return q.location == NSNotFound ? rawPath : [rawPath substringToIndex:q.location];
}

#pragma mark - Private HID runtime bindings

typedef struct __IOHIDEvent *BridgeHIDEventRef;
typedef struct __IOHIDEventSystemClient *BridgeHIDClientRef;
typedef int32_t BridgeIOReturn;
typedef uint32_t BridgeIOOptionBits;

typedef CF_ENUM(uint32_t, BridgeHIDEventType) {
    BridgeHIDEventTypeDigitizer = 11,
};

typedef NS_OPTIONS(uint32_t, BridgeDigitizerMask) {
    BridgeDigitizerRange    = 0x00000001,
    BridgeDigitizerTouch    = 0x00000002,
    BridgeDigitizerPosition = 0x00000004,
    BridgeDigitizerTip      = 0x00000008,
    BridgeDigitizerIdentity = 0x00000010,
};

static BridgeHIDEventRef (*BridgeCreateDigitizerEvent)(CFAllocatorRef, uint64_t, BridgeHIDEventType, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double, Boolean, Boolean, BridgeIOOptionBits);
static BridgeHIDEventRef (*BridgeCreateFingerEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double, Boolean, Boolean, BridgeIOOptionBits);
static BridgeHIDClientRef (*BridgeCreateClient)(CFAllocatorRef);
static BridgeIOReturn (*BridgeDispatchEvent)(BridgeHIDClientRef, BridgeHIDEventRef);
static void (*BridgeAppendEvent)(BridgeHIDEventRef, BridgeHIDEventRef, BridgeIOOptionBits);
static void (*BridgeSetSenderID)(BridgeHIDEventRef, uint64_t);

@interface HIDController : NSObject
@property(nonatomic, assign) BridgeHIDClientRef client;
@property(nonatomic, assign) BOOL symbolsLoaded;
- (BOOL)connect;
- (BOOL)tapAtX:(CGFloat)x y:(CGFloat)y error:(NSString **)error;
@end

@implementation HIDController

- (BOOL)loadSymbols {
    if (self.symbolsLoaded) return YES;
    void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!handle) handle = dlopen("/usr/lib/libIOKit.dylib", RTLD_LAZY);
    if (!handle) return NO;

    BridgeCreateDigitizerEvent = (typeof(BridgeCreateDigitizerEvent))dlsym(handle, "IOHIDEventCreateDigitizerEvent");
    BridgeCreateFingerEvent = (typeof(BridgeCreateFingerEvent))dlsym(handle, "IOHIDEventCreateDigitizerFingerEvent");
    BridgeCreateClient = (typeof(BridgeCreateClient))dlsym(handle, "IOHIDEventSystemClientCreate");
    BridgeDispatchEvent = (typeof(BridgeDispatchEvent))dlsym(handle, "IOHIDEventSystemClientDispatchEvent");
    BridgeAppendEvent = (typeof(BridgeAppendEvent))dlsym(handle, "IOHIDEventAppendEvent");
    BridgeSetSenderID = (typeof(BridgeSetSenderID))dlsym(handle, "IOHIDEventSetSenderID");

    self.symbolsLoaded = BridgeCreateDigitizerEvent && BridgeCreateFingerEvent && BridgeCreateClient && BridgeDispatchEvent && BridgeAppendEvent && BridgeSetSenderID;
    return self.symbolsLoaded;
}

- (BOOL)connect {
    if (self.client) return YES;
    if (![self loadSymbols]) return NO;
    self.client = BridgeCreateClient(kCFAllocatorDefault);
    return self.client != NULL;
}

- (BridgeHIDEventRef)eventDown:(BOOL)down x:(CGFloat)x y:(CGFloat)y {
    uint64_t now = mach_absolute_time();
    uint32_t fingerMask = down
        ? (BridgeDigitizerRange | BridgeDigitizerTouch | BridgeDigitizerPosition | BridgeDigitizerTip | BridgeDigitizerIdentity)
        : (BridgeDigitizerRange | BridgeDigitizerIdentity);

    BridgeHIDEventRef finger = BridgeCreateFingerEvent(kCFAllocatorDefault, now, 0, 1, fingerMask, 0,
                                                       x, y, 0.0, down ? 1.0 : 0.0, 0.0,
                                                       true, down, 0);
    if (!finger) return NULL;

    uint32_t parentMask = BridgeDigitizerRange | BridgeDigitizerTouch | BridgeDigitizerIdentity;
    BridgeHIDEventRef parent = BridgeCreateDigitizerEvent(kCFAllocatorDefault, now, BridgeHIDEventTypeDigitizer,
                                                           0, 0, 1, parentMask, 0,
                                                           0, 0, 0, 0, 0, true, true, 0);
    if (!parent) {
        CFRelease(finger);
        return NULL;
    }
    BridgeAppendEvent(parent, finger, 0);
    CFRelease(finger);
    return parent;
}

- (BOOL)dispatch:(BridgeHIDEventRef)event {
    if (!event || !self.client) return NO;
    BridgeSetSenderID(event, 0x8000000817371935ULL);
    BridgeIOReturn result = BridgeDispatchEvent(self.client, event);
    CFRelease(event);
    return result == 0;
}

- (BOOL)tapAtX:(CGFloat)x y:(CGFloat)y error:(NSString **)error {
    if (![self connect]) {
        if (error) *error = @"HID client unavailable; entitlement/private API unavailable";
        return NO;
    }
    CGSize screen = UIScreen.mainScreen.bounds.size;
    if (screen.width <= 0 || screen.height <= 0) {
        if (error) *error = @"Invalid screen dimensions";
        return NO;
    }
    CGFloat nx = MIN(MAX(x / screen.width, 0.0), 1.0);
    CGFloat ny = MIN(MAX(y / screen.height, 0.0), 1.0);
    if (![self dispatch:[self eventDown:YES x:nx y:ny]]) {
        if (error) *error = @"Touch-down dispatch failed";
        return NO;
    }
    usleep(50000);
    if (![self dispatch:[self eventDown:NO x:nx y:ny]]) {
        if (error) *error = @"Touch-up dispatch failed";
        return NO;
    }
    return YES;
}
@end

#pragma mark - App control and diagnostics

static id DefaultWorkspace(void) {
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    SEL sel = NSSelectorFromString(@"defaultWorkspace");
    if (!cls || ![cls respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, sel);
}

static BOOL OpenBundleIdentifier(NSString *bundleIdentifier) {
    id workspace = DefaultWorkspace();
    SEL sel = NSSelectorFromString(@"openApplicationWithBundleID:");
    if (!workspace || ![workspace respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, sel, bundleIdentifier);
}

static id ApplicationProxyForBundleID(NSString *bundleIdentifier) {
    id workspace = DefaultWorkspace();
    if (!workspace) return nil;

    SEL direct = NSSelectorFromString(@"applicationForIdentifier:");
    if ([workspace respondsToSelector:direct]) {
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(workspace, direct, bundleIdentifier);
        if (proxy) return proxy;
    }

    for (NSString *selectorName in @[@"allApplications", @"allInstalledApplications"]) {
        SEL sel = NSSelectorFromString(selectorName);
        if (![workspace respondsToSelector:sel]) continue;
        id result = ((id (*)(id, SEL))objc_msgSend)(workspace, sel);
        if (![result conformsToProtocol:@protocol(NSFastEnumeration)]) continue;
        for (id proxy in result) {
            NSString *identifier = SafeValue(proxy, @"applicationIdentifier");
            if ([identifier isEqualToString:bundleIdentifier]) return proxy;
        }
    }
    return nil;
}

static NSDictionary *AppInfo(NSString *bundleIdentifier) {
    id proxy = ApplicationProxyForBundleID(bundleIdentifier);
    if (!proxy) return nil;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"bundleId"] = bundleIdentifier;
    NSDictionary *keys = @{
        @"name": @"localizedName",
        @"shortVersion": @"shortVersionString",
        @"bundleVersion": @"bundleVersion",
        @"bundlePath": @"bundleURL",
        @"dataContainerPath": @"dataContainerURL",
        @"applicationType": @"applicationType",
        @"vendorName": @"vendorName",
        @"teamID": @"teamID"
    };
    [keys enumerateKeysAndObjectsUsingBlock:^(NSString *outputKey, NSString *proxyKey, BOOL *stop) {
        id value = SafeValue(proxy, proxyKey);
        if (value) out[outputKey] = JSONValue(value);
    }];
    return out;
}

static BOOL TerminateBundleIdentifier(NSString *bundleIdentifier, NSString **error) {
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY);
    Class cls = NSClassFromString(@"FBSSystemService");
    SEL shared = NSSelectorFromString(@"sharedService");
    if (!cls || ![cls respondsToSelector:shared]) {
        if (error) *error = @"FBSSystemService unavailable";
        return NO;
    }
    id service = ((id (*)(id, SEL))objc_msgSend)(cls, shared);
    SEL terminate = NSSelectorFromString(@"terminateApplication:forReason:andReport:withDescription:");
    if (![service respondsToSelector:terminate]) {
        if (error) *error = @"terminateApplication private API unavailable";
        return NO;
    }
    ((void (*)(id, SEL, id, long long, BOOL, id))objc_msgSend)(service, terminate, bundleIdentifier, 1LL, NO, @"Requested by iOS Claude Bridge");
    return YES;
}

static NSDictionary *SystemInfo(void) {
    UIDevice *device = UIDevice.currentDevice;
    NSProcessInfo *pi = NSProcessInfo.processInfo;
    struct utsname uts = {0};
    uname(&uts);

    NSDictionary *fs = [NSFileManager.defaultManager attributesOfFileSystemForPath:NSHomeDirectory() error:nil] ?: @{};
    NSNumber *totalDisk = fs[NSFileSystemSize] ?: @0;
    NSNumber *freeDisk = fs[NSFileSystemFreeSize] ?: @0;

    uint64_t memsize = 0;
    size_t len = sizeof(memsize);
    if (sysctlbyname("hw.memsize", &memsize, &len, NULL, 0) != 0) memsize = pi.physicalMemory;

    return @{
        @"deviceName": device.name ?: @"",
        @"model": device.model ?: @"",
        @"systemName": device.systemName ?: @"",
        @"systemVersion": device.systemVersion ?: @"",
        @"machine": [NSString stringWithUTF8String:uts.machine] ?: @"",
        @"kernel": [NSString stringWithFormat:@"%s %s", uts.release, uts.version],
        @"physicalMemoryBytes": @(memsize),
        @"processorCount": @(pi.processorCount),
        @"activeProcessorCount": @(pi.activeProcessorCount),
        @"lowPowerMode": @(pi.lowPowerModeEnabled),
        @"diskTotalBytes": totalDisk,
        @"diskFreeBytes": freeDisk,
        @"bridgePID": @(getpid()),
        @"bridgeVersion": BridgeVersion
    };
}

static NSArray *ProcessList(NSString *filter, NSUInteger limit) {
    int count = proc_listallpids(NULL, 0);
    if (count <= 0) return @[];
    pid_t *pids = calloc((size_t)count, sizeof(pid_t));
    if (!pids) return @[];
    int actual = proc_listallpids(pids, count * (int)sizeof(pid_t));
    NSMutableArray *items = [NSMutableArray array];
    NSString *needle = filter.lowercaseString;
    for (int i = 0; i < actual && items.count < limit; i++) {
        pid_t pid = pids[i];
        if (pid <= 0) continue;
        char pathbuf[PROC_PIDPATHINFO_MAXSIZE] = {0};
        int n = proc_pidpath(pid, pathbuf, sizeof(pathbuf));
        NSString *path = n > 0 ? [NSString stringWithUTF8String:pathbuf] : @"";
        char namebuf[256] = {0};
        proc_name(pid, namebuf, sizeof(namebuf));
        NSString *name = namebuf[0] ? [NSString stringWithUTF8String:namebuf] : path.lastPathComponent;
        if (needle.length && ![name.lowercaseString containsString:needle] && ![path.lowercaseString containsString:needle]) continue;
        [items addObject:@{@"pid": @(pid), @"name": name ?: @"", @"path": path ?: @""}];
    }
    free(pids);
    return items;
}

static NSArray<NSString *> *CrashDirectories(void) {
    return @[
        @"/var/mobile/Library/Logs/CrashReporter",
        @"/private/var/mobile/Library/Logs/CrashReporter",
        @"/var/mobile/Library/Logs/CrashReporter/DiagnosticLogs",
        @"/private/var/mobile/Library/Logs/CrashReporter/DiagnosticLogs"
    ];
}

static NSArray *CrashLogs(NSString *filter, NSUInteger limit, BOOL includeContent, NSUInteger maxBytes) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableDictionary<NSString *, NSDictionary *> *unique = [NSMutableDictionary dictionary];
    NSString *needle = filter.lowercaseString;

    for (NSString *dir in CrashDirectories()) {
        NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *file in files) {
            NSString *ext = file.pathExtension.lowercaseString;
            if (![@[@"ips", @"crash", @"synced", @"log"] containsObject:ext]) continue;
            if (needle.length && ![file.lowercaseString containsString:needle]) continue;
            NSString *full = [dir stringByAppendingPathComponent:file];
            NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
            if (!attrs) continue;
            NSString *canonical = [full stringByStandardizingPath];
            unique[canonical] = @{
                @"name": file,
                @"path": full,
                @"size": attrs[NSFileSize] ?: @0,
                @"modified": @([attrs[NSFileModificationDate] timeIntervalSince1970])
            };
        }
    }

    NSArray *sorted = [unique.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"modified"] compare:a[@"modified"]];
    }];
    if (sorted.count > limit) sorted = [sorted subarrayWithRange:NSMakeRange(0, limit)];

    if (!includeContent) return sorted;
    NSMutableArray *withContent = [NSMutableArray array];
    for (NSDictionary *entry in sorted) {
        NSMutableDictionary *copy = [entry mutableCopy];
        NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:entry[@"path"]];
        if (handle) {
            NSData *data = [handle readDataOfLength:maxBytes];
            [handle closeFile];
            NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (text) copy[@"content"] = text;
            copy[@"truncatedAtBytes"] = @(maxBytes);
        }
        [withContent addObject:copy];
    }
    return withContent;
}

#pragma mark - Localhost HTTP server

@interface BridgeServer : NSObject
@property(nonatomic, assign) int listenFD;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) HIDController *hid;
@property(nonatomic, copy) void (^statusHandler)(NSString *status);
- (BOOL)start:(NSError **)error;
@end

@implementation BridgeServer

- (instancetype)init {
    if ((self = [super init])) {
        _listenFD = -1;
        _queue = dispatch_queue_create("app.iosclaudebridge.http", DISPATCH_QUEUE_SERIAL);
        _hid = [HIDController new];
    }
    return self;
}

- (NSData *)jsonResponse:(NSDictionary *)object status:(NSInteger)status {
    NSData *body = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil] ?: [NSData data];
    NSString *reason = status == 200 ? @"OK" : status == 404 ? @"Not Found" : status == 400 ? @"Bad Request" : @"Internal Server Error";
    NSString *header = [NSString stringWithFormat:@"HTTP/1.1 %ld %@\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", (long)status, reason, (unsigned long)body.length];
    NSMutableData *response = [NSMutableData dataWithData:[header dataUsingEncoding:NSUTF8StringEncoding]];
    [response appendData:body];
    return response;
}

- (void)sendObject:(NSDictionary *)object status:(NSInteger)status fd:(int)fd {
    NSData *data = [self jsonResponse:object status:status];
    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    while (remaining > 0) {
        ssize_t written = write(fd, bytes, remaining);
        if (written <= 0) break;
        bytes += written;
        remaining -= (NSUInteger)written;
    }
}

- (void)handleClient:(int)fd {
    NSMutableData *requestData = [NSMutableData data];
    char buffer[4096];
    ssize_t count;
    while ((count = read(fd, buffer, sizeof(buffer))) > 0) {
        [requestData appendBytes:buffer length:(NSUInteger)count];
        NSString *partial = [[NSString alloc] initWithData:requestData encoding:NSUTF8StringEncoding];
        NSRange headerEnd = [partial rangeOfString:@"\r\n\r\n"];
        if (headerEnd.location != NSNotFound) {
            NSRange lengthRange = [partial rangeOfString:@"Content-Length:" options:NSCaseInsensitiveSearch];
            NSInteger expected = 0;
            if (lengthRange.location != NSNotFound) {
                NSUInteger start = NSMaxRange(lengthRange);
                NSRange lineEnd = [partial rangeOfString:@"\r\n" options:0 range:NSMakeRange(start, partial.length - start)];
                if (lineEnd.location != NSNotFound) {
                    NSString *value = [[partial substringWithRange:NSMakeRange(start, lineEnd.location - start)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                    expected = value.integerValue;
                }
            }
            NSUInteger bodyStart = NSMaxRange(headerEnd);
            NSUInteger currentBodyBytes = requestData.length > bodyStart ? requestData.length - bodyStart : 0;
            if (currentBodyBytes >= (NSUInteger)MAX(expected, 0)) break;
        }
        if (requestData.length > 2 * 1024 * 1024) break;
    }

    NSString *request = [[NSString alloc] initWithData:requestData encoding:NSUTF8StringEncoding];
    if (!request) {
        [self sendObject:@{@"ok": @NO, @"error": @"invalid utf8 request"} status:400 fd:fd];
        return;
    }

    NSRange firstLineEnd = [request rangeOfString:@"\r\n"];
    NSString *firstLine = firstLineEnd.location == NSNotFound ? request : [request substringToIndex:firstLineEnd.location];
    NSArray<NSString *> *parts = [firstLine componentsSeparatedByString:@" "];
    NSString *method = parts.count > 0 ? parts[0] : @"";
    NSString *rawPath = parts.count > 1 ? parts[1] : @"";
    NSString *path = QueryPath(rawPath);

    NSDictionary *json = @{};
    NSRange bodySeparator = [request rangeOfString:@"\r\n\r\n"];
    if (bodySeparator.location != NSNotFound) {
        NSString *body = [request substringFromIndex:NSMaxRange(bodySeparator)];
        if (body.length) {
            NSData *bodyData = [body dataUsingEncoding:NSUTF8StringEncoding];
            id parsed = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil];
            if ([parsed isKindOfClass:NSDictionary.class]) json = parsed;
        }
    }

    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/ping"]) {
        [self sendObject:@{@"ok": @YES, @"service": @"ios-claude-bridge", @"version": BridgeVersion} status:200 fd:fd];
        return;
    }

    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/system-info"]) {
        [self sendObject:@{@"ok": @YES, @"system": SystemInfo()} status:200 fd:fd];
        return;
    }

    if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/app-info"]) {
        NSString *bundleID = json[@"bundleId"];
        if (![bundleID isKindOfClass:NSString.class] || bundleID.length == 0) {
            [self sendObject:@{@"ok": @NO, @"error": @"bundleId is required"} status:400 fd:fd];
            return;
        }
        NSDictionary *info = AppInfo(bundleID);
        [self sendObject:info ? @{@"ok": @YES, @"app": info} : @{@"ok": @NO, @"error": @"application not found or LS access unavailable"} status:info ? 200 : 404 fd:fd];
        return;
    }

    if ([method isEqualToString:@"POST"] && ([path isEqualToString:@"/open"] || [path isEqualToString:@"/launch"])) {
        NSString *bundleID = json[@"bundleId"];
        if (![bundleID isKindOfClass:NSString.class] || bundleID.length == 0) {
            [self sendObject:@{@"ok": @NO, @"error": @"bundleId is required"} status:400 fd:fd];
            return;
        }
        __block BOOL opened = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{ opened = OpenBundleIdentifier(bundleID); });
        if (self.statusHandler) self.statusHandler(opened ? [NSString stringWithFormat:@"Launched %@", bundleID] : [NSString stringWithFormat:@"Launch failed: %@", bundleID]);
        [self sendObject:@{@"ok": @(opened), @"bundleId": bundleID} status:opened ? 200 : 500 fd:fd];
        return;
    }

    if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/terminate"]) {
        NSString *bundleID = json[@"bundleId"];
        if (![bundleID isKindOfClass:NSString.class] || bundleID.length == 0) {
            [self sendObject:@{@"ok": @NO, @"error": @"bundleId is required"} status:400 fd:fd];
            return;
        }
        NSString *terminateError = nil;
        BOOL ok = TerminateBundleIdentifier(bundleID, &terminateError);
        [self sendObject:ok ? @{@"ok": @YES, @"accepted": @YES, @"bundleId": bundleID} : @{@"ok": @NO, @"error": terminateError ?: @"terminate failed"} status:ok ? 200 : 500 fd:fd];
        return;
    }

    if (([method isEqualToString:@"GET"] || [method isEqualToString:@"POST"]) && [path isEqualToString:@"/processes"]) {
        NSString *filter = [json[@"filter"] isKindOfClass:NSString.class] ? json[@"filter"] : @"";
        NSUInteger limit = [json[@"limit"] isKindOfClass:NSNumber.class] ? MIN(MAX([json[@"limit"] unsignedIntegerValue], 1), 1000) : 300;
        NSArray *processes = ProcessList(filter, limit);
        [self sendObject:@{@"ok": @YES, @"count": @(processes.count), @"processes": processes} status:200 fd:fd];
        return;
    }

    if (([method isEqualToString:@"GET"] || [method isEqualToString:@"POST"]) && [path isEqualToString:@"/crashlogs"]) {
        NSString *filter = [json[@"filter"] isKindOfClass:NSString.class] ? json[@"filter"] : @"";
        NSUInteger limit = [json[@"limit"] isKindOfClass:NSNumber.class] ? MIN(MAX([json[@"limit"] unsignedIntegerValue], 1), 50) : 10;
        BOOL includeContent = [json[@"includeContent"] boolValue];
        NSUInteger maxBytes = [json[@"maxBytes"] isKindOfClass:NSNumber.class] ? MIN(MAX([json[@"maxBytes"] unsignedIntegerValue], 1024), 262144) : 65536;
        NSArray *logs = CrashLogs(filter, limit, includeContent, maxBytes);
        [self sendObject:@{@"ok": @YES, @"count": @(logs.count), @"logs": logs} status:200 fd:fd];
        return;
    }

    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/capabilities"]) {
        [self sendObject:@{
            @"ok": @YES,
            @"version": BridgeVersion,
            @"endpoints": @[@"/ping", @"/system-info", @"/app-info", @"/processes", @"/crashlogs", @"/launch", @"/terminate", @"/tap"],
            @"notes": @{
                @"unifiedLogs": @"Not exposed yet; crash/diagnostic reports are available through /crashlogs",
                @"privateAPIs": @"Availability depends on iOS version and TrollStore entitlements"
            }
        } status:200 fd:fd];
        return;
    }

    if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/tap"]) {
        NSNumber *x = json[@"x"];
        NSNumber *y = json[@"y"];
        if (![x isKindOfClass:NSNumber.class] || ![y isKindOfClass:NSNumber.class]) {
            [self sendObject:@{@"ok": @NO, @"error": @"numeric x and y are required"} status:400 fd:fd];
            return;
        }
        __block BOOL ok = NO;
        __block NSString *tapError = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{ ok = [self.hid tapAtX:x.doubleValue y:y.doubleValue error:&tapError]; });
        [self sendObject:ok ? @{@"ok": @YES} : @{@"ok": @NO, @"error": tapError ?: @"tap failed"} status:ok ? 200 : 500 fd:fd];
        return;
    }

    [self sendObject:@{@"ok": @NO, @"error": @"unknown endpoint", @"hint": @"GET /capabilities"} status:404 fd:fd];
}

- (BOOL)start:(NSError **)error {
    self.listenFD = socket(AF_INET, SOCK_STREAM, 0);
    if (self.listenFD < 0) {
        if (error) *error = [NSError errorWithDomain:@"BridgeServer" code:1 userInfo:@{NSLocalizedDescriptionKey: @"socket() failed"}];
        return NO;
    }
    int yes = 1;
    setsockopt(self.listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(8765);
    address.sin_addr.s_addr = inet_addr("127.0.0.1");
    if (bind(self.listenFD, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(self.listenFD, 8) != 0) {
        close(self.listenFD);
        self.listenFD = -1;
        if (error) *error = [NSError errorWithDomain:@"BridgeServer" code:2 userInfo:@{NSLocalizedDescriptionKey: @"bind/listen on 127.0.0.1:8765 failed"}];
        return NO;
    }
    dispatch_async(self.queue, ^{
        while (self.listenFD >= 0) {
            int client = accept(self.listenFD, NULL, NULL);
            if (client < 0) continue;
            [self handleClient:client];
            close(client);
        }
    });
    return YES;
}
@end

#pragma mark - UI

@interface BridgeViewController : UIViewController
@property(nonatomic, strong) UILabel *statusLabel;
@end

@implementation BridgeViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"iOS Claude Bridge";
    title.font = [UIFont boldSystemFontOfSize:28];

    UILabel *endpoint = [UILabel new];
    endpoint.translatesAutoresizingMaskIntoConstraints = NO;
    endpoint.text = [NSString stringWithFormat:@"v%@ · 127.0.0.1:8765", BridgeVersion];
    endpoint.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];

    self.statusLabel = [UILabel new];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.text = @"Starting…";
    self.statusLabel.numberOfLines = 0;

    UILabel *note = [UILabel new];
    note.translatesAutoresizingMaskIntoConstraints = NO;
    note.text = @"Diagnostic bridge: system-info · app-info · processes · crashlogs · launch/terminate\nTouch injection remains available as a secondary capability.";
    note.numberOfLines = 0;
    note.textColor = UIColor.secondaryLabelColor;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, endpoint, self.statusLabel, note]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 18;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-24],
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:36],
    ]];
}
@end

@interface BridgeAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) BridgeServer *server;
@end

@implementation BridgeAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    BridgeViewController *vc = [BridgeViewController new];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];

    self.server = [BridgeServer new];
    __weak BridgeViewController *weakVC = vc;
    self.server.statusHandler = ^(NSString *status) {
        dispatch_async(dispatch_get_main_queue(), ^{ weakVC.statusLabel.text = status; });
    };
    NSError *error = nil;
    vc.statusLabel.text = [self.server start:&error] ? @"Ready" : [NSString stringWithFormat:@"Server failed: %@", error.localizedDescription];
    return YES;
}
@end

int main(int argc, char * argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(BridgeAppDelegate.class));
    }
}
