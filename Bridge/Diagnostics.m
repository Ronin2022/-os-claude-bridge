#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>

static NSArray<NSString *> *AllowedRoots(void) {
    return @[
        @"/var/mobile/Library/Logs",
        @"/private/var/mobile/Library/Logs",
        @"/var/mobile/Library/Preferences",
        @"/private/var/mobile/Library/Preferences"
    ];
}

static BOOL PathAllowed(NSString *path) {
    if (![path isKindOfClass:NSString.class] || path.length == 0) return NO;
    NSString *standard = path.stringByStandardizingPath;
    for (NSString *root in AllowedRoots()) {
        NSString *r = root.stringByStandardizingPath;
        if ([standard isEqualToString:r] || [standard hasPrefix:[r stringByAppendingString:@"/"]]) return YES;
    }
    return NO;
}

static NSDictionary *FileEntry(NSString *path) {
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if (!attrs) return nil;
    BOOL isDir = [attrs[NSFileType] isEqualToString:NSFileTypeDirectory];
    return @{
        @"path": path,
        @"name": path.lastPathComponent ?: @"",
        @"directory": @(isDir),
        @"size": attrs[NSFileSize] ?: @0,
        @"modified": @([attrs[NSFileModificationDate] timeIntervalSince1970])
    };
}

static NSArray *ProbeTree(NSString *root, NSUInteger maxDepth, NSUInteger limit, BOOL logsOnly) {
    if (!PathAllowed(root)) return @[];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *queue = [NSMutableArray arrayWithObject:@{@"path": root.stringByStandardizingPath, @"depth": @0}];
    NSSet *logExts = [NSSet setWithArray:@[@"ips", @"crash", @"log", @"synced", @"panic", @"diag", @"spin"]];

    while (queue.count && out.count < limit) {
        NSDictionary *next = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSString *path = next[@"path"];
        NSUInteger depth = [next[@"depth"] unsignedIntegerValue];
        NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:path error:nil];
        for (NSString *name in children) {
            if (out.count >= limit) break;
            NSString *child = [path stringByAppendingPathComponent:name];
            NSDictionary *entry = FileEntry(child);
            if (!entry) continue;
            BOOL isDir = [entry[@"directory"] boolValue];
            if (!logsOnly || isDir || [logExts containsObject:name.pathExtension.lowercaseString]) {
                [out addObject:entry];
            }
            if (isDir && depth < maxDepth) {
                [queue addObject:@{@"path": child, @"depth": @(depth + 1)}];
            }
        }
    }
    return out;
}

static NSDictionary *ReadTextFile(NSString *path, NSUInteger maxBytes) {
    if (!PathAllowed(path)) return @{@"ok": @NO, @"error": @"path outside diagnostic allowlist"};
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if (!attrs || [attrs[NSFileType] isEqualToString:NSFileTypeDirectory]) return @{@"ok": @NO, @"error": @"file not found or is a directory"};
    NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!h) return @{@"ok": @NO, @"error": @"file unreadable"};
    NSData *data = [h readDataOfLength:MAX((NSUInteger)1, MIN(maxBytes, (NSUInteger)262144))];
    [h closeFile];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    return @{
        @"ok": @YES,
        @"path": path,
        @"bytesReturned": @(data.length),
        @"fileSize": attrs[NSFileSize] ?: @0,
        @"truncated": @([attrs[NSFileSize] unsignedLongLongValue] > data.length),
        @"content": text ?: @"<non-text data>"
    };
}

static NSData *JSONHTTP(NSDictionary *obj, NSInteger status) {
    NSData *body = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil] ?: [NSData data];
    NSString *reason = status == 200 ? @"OK" : status == 403 ? @"Forbidden" : @"Bad Request";
    NSString *header = [NSString stringWithFormat:@"HTTP/1.1 %ld %@\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", (long)status, reason, (unsigned long)body.length];
    NSMutableData *resp = [NSMutableData dataWithData:[header dataUsingEncoding:NSUTF8StringEncoding]];
    [resp appendData:body];
    return resp;
}

static NSDictionary *ParseBody(NSString *request) {
    NSRange sep = [request rangeOfString:@"\r\n\r\n"];
    if (sep.location == NSNotFound) return @{};
    NSString *body = [request substringFromIndex:NSMaxRange(sep)];
    if (!body.length) return @{};
    id obj = [NSJSONSerialization JSONObjectWithData:[body dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    return [obj isKindOfClass:NSDictionary.class] ? obj : @{};
}

static void HandleDiagnosticClient(int fd) {
    NSMutableData *data = [NSMutableData data];
    char buf[8192];
    ssize_t n;
    while ((n = read(fd, buf, sizeof(buf))) > 0) {
        [data appendBytes:buf length:(NSUInteger)n];
        NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if ([s containsString:@"\r\n\r\n"] && data.length < 1024 * 1024) {
            NSRange cl = [s rangeOfString:@"Content-Length:" options:NSCaseInsensitiveSearch];
            if (cl.location == NSNotFound) break;
            NSUInteger start = NSMaxRange(cl);
            NSRange eol = [s rangeOfString:@"\r\n" options:0 range:NSMakeRange(start, s.length - start)];
            NSInteger expected = eol.location == NSNotFound ? 0 : [[s substringWithRange:NSMakeRange(start, eol.location-start)] integerValue];
            NSRange sep = [s rangeOfString:@"\r\n\r\n"];
            if (sep.location != NSNotFound && data.length - NSMaxRange(sep) >= (NSUInteger)MAX(expected,0)) break;
        }
        if (data.length >= 1024 * 1024) break;
    }

    NSString *request = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    NSString *first = [[request componentsSeparatedByString:@"\r\n"] firstObject] ?: @"";
    NSArray *parts = [first componentsSeparatedByString:@" "];
    NSString *method = parts.count > 0 ? parts[0] : @"";
    NSString *path = parts.count > 1 ? parts[1] : @"";
    NSDictionary *json = ParseBody(request);
    NSDictionary *response = nil;
    NSInteger status = 200;

    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/ping"]) {
        response = @{@"ok": @YES, @"service": @"ios-claude-diagnostics", @"version": @"0.3.0", @"port": @8766};
    } else if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/roots"]) {
        NSMutableArray *roots = [NSMutableArray array];
        for (NSString *root in AllowedRoots()) {
            BOOL isDir = NO;
            BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:root isDirectory:&isDir];
            [roots addObject:@{@"path":root, @"exists":@(exists), @"directory":@(isDir)}];
        }
        response = @{@"ok":@YES, @"roots":roots};
    } else if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/fs-probe"]) {
        NSString *root = [json[@"root"] isKindOfClass:NSString.class] ? json[@"root"] : @"/var/mobile/Library/Logs";
        if (!PathAllowed(root)) { status = 403; response = @{@"ok":@NO,@"error":@"root outside diagnostic allowlist"}; }
        else {
            NSUInteger depth = [json[@"maxDepth"] respondsToSelector:@selector(unsignedIntegerValue)] ? [json[@"maxDepth"] unsignedIntegerValue] : 4;
            NSUInteger limit = [json[@"limit"] respondsToSelector:@selector(unsignedIntegerValue)] ? [json[@"limit"] unsignedIntegerValue] : 500;
            BOOL logsOnly = [json[@"logsOnly"] respondsToSelector:@selector(boolValue)] ? [json[@"logsOnly"] boolValue] : YES;
            depth = MIN(depth, 8); limit = MAX((NSUInteger)1, MIN(limit, (NSUInteger)2000));
            NSArray *entries = ProbeTree(root, depth, limit, logsOnly);
            response = @{@"ok":@YES,@"root":root,@"count":@(entries.count),@"entries":entries};
        }
    } else if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/read-file"]) {
        NSString *file = json[@"path"];
        if (![file isKindOfClass:NSString.class]) { status = 400; response = @{@"ok":@NO,@"error":@"path is required"}; }
        else if (!PathAllowed(file)) { status = 403; response = @{@"ok":@NO,@"error":@"path outside diagnostic allowlist"}; }
        else {
            NSUInteger maxBytes = [json[@"maxBytes"] respondsToSelector:@selector(unsignedIntegerValue)] ? [json[@"maxBytes"] unsignedIntegerValue] : 65536;
            response = ReadTextFile(file, maxBytes);
        }
    } else {
        status = 400;
        response = @{@"ok":@NO,@"error":@"unknown endpoint"};
    }

    NSData *resp = JSONHTTP(response ?: @{@"ok":@NO}, status);
    write(fd, resp.bytes, resp.length);
}

static void StartDiagnosticServer(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int s = socket(AF_INET, SOCK_STREAM, 0);
        if (s < 0) return;
        int yes = 1;
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
        struct sockaddr_in addr = {0};
        addr.sin_len = sizeof(addr);
        addr.sin_family = AF_INET;
        addr.sin_port = htons(8766);
        addr.sin_addr.s_addr = inet_addr("127.0.0.1");
        if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(s, 8) != 0) { close(s); return; }
        while (1) {
            int c = accept(s, NULL, NULL);
            if (c < 0) continue;
            HandleDiagnosticClient(c);
            close(c);
        }
    });
}

__attribute__((constructor)) static void DiagnosticBridgeInit(void) {
    StartDiagnosticServer();
}
