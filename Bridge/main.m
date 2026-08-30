#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>

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

static uint64_t BridgeNow(void) {
    return mach_absolute_time();
}

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
    uint64_t now = BridgeNow();
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
        if (error) *error = @"HID client unavailable; entitlement or private API may be unavailable";
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

#pragma mark - App launch

static BOOL OpenBundleIdentifier(NSString *bundleIdentifier) {
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL defaultSelector = NSSelectorFromString(@"defaultWorkspace");
    SEL openSelector = NSSelectorFromString(@"openApplicationWithBundleID:");
    if (!workspaceClass || ![workspaceClass respondsToSelector:defaultSelector]) return NO;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id workspace = [workspaceClass performSelector:defaultSelector];
    if (!workspace || ![workspace respondsToSelector:openSelector]) return NO;
    NSNumber *result = [workspace performSelector:openSelector withObject:bundleIdentifier];
#pragma clang diagnostic pop
    return result ? result.boolValue : YES;
}

#pragma mark - Minimal localhost HTTP server

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
    NSString *reason = status == 200 ? @"OK" : status == 400 ? @"Bad Request" : @"Internal Server Error";
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
        if (requestData.length > 1024 * 1024) break;
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
    NSString *path = parts.count > 1 ? parts[1] : @"";

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
        [self sendObject:@{@"ok": @YES, @"service": @"ios-claude-bridge", @"version": @"0.1.0"} status:200 fd:fd];
        return;
    }

    if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/open"]) {
        NSString *bundleID = json[@"bundleId"];
        if (![bundleID isKindOfClass:NSString.class] || bundleID.length == 0) {
            [self sendObject:@{@"ok": @NO, @"error": @"bundleId is required"} status:400 fd:fd];
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL opened = OpenBundleIdentifier(bundleID);
            if (self.statusHandler) self.statusHandler(opened ? [NSString stringWithFormat:@"Opened %@", bundleID] : [NSString stringWithFormat:@"Open failed: %@", bundleID]);
        });
        [self sendObject:@{@"ok": @YES, @"accepted": @YES, @"bundleId": bundleID} status:200 fd:fd];
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
        dispatch_sync(dispatch_get_main_queue(), ^{
            ok = [self.hid tapAtX:x.doubleValue y:y.doubleValue error:&tapError];
            if (self.statusHandler) self.statusHandler(ok ? [NSString stringWithFormat:@"Tap %.0f, %.0f", x.doubleValue, y.doubleValue] : (tapError ?: @"Tap failed"));
        });
        [self sendObject:ok ? @{@"ok": @YES} : @{@"ok": @NO, @"error": tapError ?: @"tap failed"} status:ok ? 200 : 500 fd:fd];
        return;
    }

    [self sendObject:@{@"ok": @NO, @"error": @"unknown endpoint"} status:400 fd:fd];
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
    endpoint.text = @"Listening on 127.0.0.1:8765";
    endpoint.font = [UIFont monospacedSystemFontOfSize:16 weight:UIFontWeightRegular];

    self.statusLabel = [UILabel new];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.text = @"Starting…";
    self.statusLabel.numberOfLines = 0;

    UILabel *note = [UILabel new];
    note.translatesAutoresizingMaskIntoConstraints = NO;
    note.text = @"MVP: /ping  /open  /tap\nKeep this app open during initial validation.";
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
    if ([self.server start:&error]) {
        vc.statusLabel.text = @"Ready";
    } else {
        vc.statusLabel.text = [NSString stringWithFormat:@"Server failed: %@", error.localizedDescription];
    }
    return YES;
}
@end

int main(int argc, char * argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(BridgeAppDelegate.class));
    }
}
