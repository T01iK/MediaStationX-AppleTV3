#import "MSXURLProtocol.h"
#import "MSXHTTPS.h"
#import "MSXLog.h"

// Marks a request as already handled, so a request we re-issue ourselves is not
// claimed again.
static NSString *const kMSXHandledKey = @"MSXHandled";

@implementation MSXURLProtocol {
    BOOL _cancelled;
    NSThread *_clientThread;
}

#pragma mark - Enablement

// Opt-in, and per-host opt-out, because this replaces the system's TLS for
// every https request the web view makes.
//   .../MediaStationX/tls-bridge          enable
//   .../MediaStationX/tls-bridge-exclude  one host per line, sent via the system
+ (BOOL)isEnabled {
    static int enabled = -1;
    if (enabled < 0) {
        NSString *flag = [kMSXPrefsDir stringByAppendingPathComponent:@"tls-bridge"];
        enabled = [[NSFileManager defaultManager] fileExistsAtPath:flag] ? 1 : 0;
    }
    return enabled == 1;
}

// The protocol is process-wide, so it would otherwise also carry the AppleTV
// UI's own iTunes traffic.  The system reaches those hosts perfectly well, and
// interposing on them is a needlessly wide footprint, so leave them alone.
+ (NSArray *)defaultExcludedSuffixes {
    return [NSArray arrayWithObjects:@"apple.com", @"mzstatic.com", @"icloud.com",
                                     @"aaplimg.com", @"akadns.net", nil];
}

+ (BOOL)isExcludedHost:(NSString *)host {
    host = [host lowercaseString];
    if ([[self excludedHosts] containsObject:host]) return YES;
    for (NSString *suffix in [self defaultExcludedSuffixes]) {
        if ([host isEqualToString:suffix] ||
            [host hasSuffix:[@"." stringByAppendingString:suffix]]) return YES;
    }
    return NO;
}

+ (NSSet *)excludedHosts {
    static NSSet *hosts = nil;
    if (!hosts) {
        NSString *path = [kMSXPrefsDir stringByAppendingPathComponent:@"tls-bridge-exclude"];
        NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
        NSMutableSet *set = [NSMutableSet set];
        for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
            NSString *host = [line stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([host length] && ![host hasPrefix:@"#"]) [set addObject:[host lowercaseString]];
        }
        hosts = [set copy];
    }
    return hosts;
}

+ (void)install {
    if (![self isEnabled]) { MSXDebug(@"tls bridge: disabled"); return; }
    [NSURLProtocol registerClass:self];
    MSXDebug(@"tls bridge: enabled (%lu hosts excluded)", (unsigned long)[[self excludedHosts] count]);
}

#pragma mark - NSURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSURL *url = [request URL];
    MSXLogURL(@"request", [url absoluteString]);

    if (![[[url scheme] lowercaseString] isEqualToString:@"https"]) return NO;
    if ([NSURLProtocol propertyForKey:kMSXHandledKey inRequest:request]) return NO;
    if ([self isExcludedHost:[url host]]) return NO;
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }

+ (BOOL)requestIsCacheEquivalent:(NSURLRequest *)a toRequest:(NSURLRequest *)b {
    return [super requestIsCacheEquivalent:a toRequest:b];
}

- (void)startLoading {
    _cancelled = NO;
    // The URL loading system expects its callbacks on the thread that started
    // the load, so remember it and hop back for each one.
    _clientThread = [[NSThread currentThread] retain];

    NSURLRequest *request = [self request];
    MSXLogURL(@"tls-bridge", [[request URL] absoluteString]);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        MSXHTTPSResponse *response =
            [MSXHTTPS performRequest:request cancelled:^BOOL { return self->_cancelled; }];
        [self performSelector:@selector(deliver:) onThread:self->_clientThread
                   withObject:response waitUntilDone:NO];
    });
}

- (void)deliver:(MSXHTTPSResponse *)response {
    if (_cancelled) return;

    if (response.error) {
        MSXLog(@"tls bridge: %@ -> %@", [[self request] URL], [response.error localizedDescription]);
        MSXLogURL(@"failed", [NSString stringWithFormat:@"%@ (%@)",
                              [[self request] URL], [response.error localizedDescription]]);
        [[self client] URLProtocol:self didFailWithError:response.error];
        return;
    }

    NSHTTPURLResponse *http =
        [[[NSHTTPURLResponse alloc] initWithURL:[[self request] URL]
                                     statusCode:response.statusCode
                                    HTTPVersion:@"HTTP/1.1"
                                   headerFields:response.headers] autorelease];

    // Not cached: responses fetched this way bypass the system's own TLS, and
    // caching them would let a later system-issued request serve them.
    [[self client] URLProtocol:self didReceiveResponse:http
            cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if ([response.body length]) [[self client] URLProtocol:self didLoadData:response.body];
    [[self client] URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {
    _cancelled = YES;
}

- (void)dealloc {
    [_clientThread release];
    [super dealloc];
}

@end
