#import "MSXHTTPS.h"
#import "MSXLog.h"

#include "mbedtls/net_sockets.h"
#include "mbedtls/ssl.h"
#include "mbedtls/entropy.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/x509_crt.h"
#include "mbedtls/error.h"

static NSString *const MSXHTTPSErrorDomain = @"de.benzac.msx.https";

// A TLS handshake costs a few hundred milliseconds of software crypto on this
// hardware, which is ruinous for a page pulling hundreds of images.  Connections
// are therefore kept alive and pooled per host.
static const NSTimeInterval kIdleTimeout      = 20.0;
static const NSUInteger     kMaxIdlePerHost   = 6;
static const uint32_t       kReadTimeoutMs    = 30000;

@implementation MSXHTTPSResponse
- (void)dealloc {
    [_headers release];
    [_body release];
    [_error release];
    [super dealloc];
}
@end

#pragma mark - Errors

static NSError *MSXHTTPSError(int code, NSString *message) {
    return [NSError errorWithDomain:MSXHTTPSErrorDomain code:code
                           userInfo:[NSDictionary dictionaryWithObject:message
                                                                forKey:NSLocalizedDescriptionKey]];
}

static NSError *MSXTLSError(NSString *stage, int ret) {
    char buf[192];
    mbedtls_strerror(ret, buf, sizeof(buf));
    return MSXHTTPSError(ret, [NSString stringWithFormat:@"%@: %s", stage, buf]);
}

#pragma mark - Shared TLS state

// Parsing the ~200 KB CA bundle is slow here, so do it once and share it.
static mbedtls_x509_crt gCACert;
static mbedtls_entropy_context gEntropy;
static mbedtls_ctr_drbg_context gDrbg;
static NSString *gCABundlePath = nil;
static BOOL gTLSReady = NO;

#pragma mark - Connection

@interface MSXConnection : NSObject {
@public
    mbedtls_net_context _net;
    mbedtls_ssl_context _ssl;
    mbedtls_ssl_config  _conf;
}
@property (nonatomic, retain) NSString *poolKey;
@property (nonatomic, retain) NSMutableData *buffer;   // bytes read but not consumed
@property (nonatomic, assign) NSTimeInterval idleSince;
@property (nonatomic, assign) BOOL reused;
@end

@implementation MSXConnection

+ (MSXConnection *)connectToHost:(NSString *)host port:(NSString *)port error:(NSError **)error {
    MSXConnection *c = [[[MSXConnection alloc] init] autorelease];
    c.buffer = [NSMutableData data];

    mbedtls_net_init(&c->_net);
    mbedtls_ssl_init(&c->_ssl);
    mbedtls_ssl_config_init(&c->_conf);

    int ret;
    if ((ret = mbedtls_net_connect(&c->_net, [host UTF8String], [port UTF8String],
                                   MBEDTLS_NET_PROTO_TCP)) != 0) {
        if (error) *error = MSXTLSError(@"connect", ret);
        return nil;
    }
    if ((ret = mbedtls_ssl_config_defaults(&c->_conf, MBEDTLS_SSL_IS_CLIENT,
             MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT)) != 0) {
        if (error) *error = MSXTLSError(@"config", ret);
        return nil;
    }
    mbedtls_ssl_conf_authmode(&c->_conf, MBEDTLS_SSL_VERIFY_REQUIRED);
    mbedtls_ssl_conf_ca_chain(&c->_conf, &gCACert, NULL);
    mbedtls_ssl_conf_rng(&c->_conf, mbedtls_ctr_drbg_random, &gDrbg);
    mbedtls_ssl_conf_read_timeout(&c->_conf, kReadTimeoutMs);

    if ((ret = mbedtls_ssl_setup(&c->_ssl, &c->_conf)) != 0) {
        if (error) *error = MSXTLSError(@"setup", ret); return nil;
    }
    if ((ret = mbedtls_ssl_set_hostname(&c->_ssl, [host UTF8String])) != 0) {
        if (error) *error = MSXTLSError(@"sni", ret); return nil;
    }
    mbedtls_ssl_set_bio(&c->_ssl, &c->_net, mbedtls_net_send, mbedtls_net_recv, NULL);

    while ((ret = mbedtls_ssl_handshake(&c->_ssl)) != 0) {
        if (ret != MBEDTLS_ERR_SSL_WANT_READ && ret != MBEDTLS_ERR_SSL_WANT_WRITE) {
            if (error) *error = MSXTLSError(@"handshake", ret);
            return nil;
        }
    }
    if (mbedtls_ssl_get_verify_result(&c->_ssl) != 0) {
        if (error) *error = MSXHTTPSError(-2,
            [NSString stringWithFormat:@"certificate for %@ not trusted", host]);
        return nil;
    }
    return c;
}

- (BOOL)writeAll:(NSData *)data error:(NSError **)error {
    const unsigned char *p = [data bytes];
    size_t remaining = [data length];
    while (remaining > 0) {
        int ret = mbedtls_ssl_write(&_ssl, p, remaining);
        if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
        if (ret <= 0) { if (error) *error = MSXTLSError(@"write", ret); return NO; }
        p += ret; remaining -= ret;
    }
    return YES;
}

// Pulls more bytes into the buffer.  Returns NO at end of stream or on error.
- (BOOL)fill {
    unsigned char buf[8192];
    while (1) {
        int ret = mbedtls_ssl_read(&_ssl, buf, sizeof(buf));
        if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
        if (ret <= 0) return NO;
        [_buffer appendBytes:buf length:ret];
        return YES;
    }
}

- (NSData *)consume:(NSUInteger)length {
    NSData *out = [_buffer subdataWithRange:NSMakeRange(0, length)];
    [_buffer replaceBytesInRange:NSMakeRange(0, length) withBytes:NULL length:0];
    return out;
}

// Reads up to and including the next CRLF, returning the line without it.
- (NSData *)readLine {
    NSData *crlf = [NSData dataWithBytes:"\r\n" length:2];
    while (1) {
        NSRange r = [_buffer rangeOfData:crlf options:0 range:NSMakeRange(0, [_buffer length])];
        if (r.location != NSNotFound) {
            NSData *line = [_buffer subdataWithRange:NSMakeRange(0, r.location)];
            [_buffer replaceBytesInRange:NSMakeRange(0, NSMaxRange(r)) withBytes:NULL length:0];
            return line;
        }
        if (![self fill]) return nil;
    }
}

- (NSData *)readExactly:(NSUInteger)length {
    while ([_buffer length] < length) {
        if (![self fill]) return nil;
    }
    return [self consume:length];
}

- (NSData *)readUntilClose {
    while ([self fill]) { }
    return [self consume:[_buffer length]];
}

- (void)shutdown {
    mbedtls_ssl_close_notify(&_ssl);
    mbedtls_ssl_free(&_ssl);
    mbedtls_ssl_config_free(&_conf);
    mbedtls_net_free(&_net);
}

- (void)dealloc {
    [_poolKey release];
    [_buffer release];
    [super dealloc];
}
@end

#pragma mark - Connection pool

static NSMutableDictionary *gPool = nil;     // "host:port" -> NSMutableArray of idle
static NSLock *gPoolLock = nil;

static MSXConnection *MSXAcquire(NSString *host, NSString *port, NSError **error) {
    NSString *key = [NSString stringWithFormat:@"%@:%@", host, port];

    [gPoolLock lock];
    NSMutableArray *idle = [gPool objectForKey:key];
    MSXConnection *c = nil;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    while ([idle count]) {
        MSXConnection *candidate = [[[idle lastObject] retain] autorelease];
        [idle removeLastObject];
        if (now - candidate.idleSince < kIdleTimeout) { c = candidate; break; }
        [candidate shutdown];               // too old to trust; the server may have closed it
    }
    [gPoolLock unlock];

    if (c) { c.reused = YES; return c; }

    c = [MSXConnection connectToHost:host port:port error:error];
    c.poolKey = key;
    c.reused = NO;
    return c;
}

static void MSXRelease(MSXConnection *c, BOOL reusable) {
    if (!c) return;
    if (!reusable) { [c shutdown]; return; }

    [gPoolLock lock];
    NSMutableArray *idle = [gPool objectForKey:c.poolKey];
    if (!idle) {
        idle = [NSMutableArray array];
        [gPool setObject:idle forKey:c.poolKey];
    }
    if ([idle count] >= kMaxIdlePerHost) {
        [gPoolLock unlock];
        [c shutdown];
        return;
    }
    c.idleSince = [NSDate timeIntervalSinceReferenceDate];
    [idle addObject:c];
    [gPoolLock unlock];
}

#pragma mark - Header helpers

static NSString *MSXHeader(NSDictionary *headers, NSString *name) {
    for (NSString *k in headers)
        if ([k caseInsensitiveCompare:name] == NSOrderedSame) return [headers objectForKey:k];
    return nil;
}

@implementation MSXHTTPS

+ (void)setCABundlePath:(NSString *)path {
    [gCABundlePath autorelease];
    gCABundlePath = [path copy];
}

+ (NSString *)caBundlePath { return gCABundlePath; }

+ (BOOL)prepareTLS {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gPool = [[NSMutableDictionary alloc] init];
        gPoolLock = [[NSLock alloc] init];

        mbedtls_x509_crt_init(&gCACert);
        mbedtls_entropy_init(&gEntropy);
        mbedtls_ctr_drbg_init(&gDrbg);

        int ret = mbedtls_ctr_drbg_seed(&gDrbg, mbedtls_entropy_func, &gEntropy,
                                        (const unsigned char *)"msx-atv3", 8);
        if (ret != 0) { MSXLog(@"https: drbg seed failed -0x%04x", -ret); return; }

        ret = mbedtls_x509_crt_parse_file(&gCACert, [gCABundlePath UTF8String]);
        if (ret < 0) { MSXLog(@"https: CA bundle %@ failed -0x%04x", gCABundlePath, -ret); return; }

        MSXDebug(@"https: TLS ready (%@, %d certs skipped)", gCABundlePath, ret);
        gTLSReady = YES;
    });
    return gTLSReady;
}

#pragma mark - One attempt

// Returns nil and sets *retryable when a pooled connection turned out to be
// dead, which is normal and should be retried once on a fresh one.
+ (MSXHTTPSResponse *)attempt:(NSURLRequest *)request
                   connection:(MSXConnection *)connection
                    cancelled:(BOOL (^)(void))isCancelled
                    reusable:(BOOL *)reusable
                   retryable:(BOOL *)retryable
{
    *reusable = NO;
    *retryable = NO;

    NSURL *url = [request URL];
    NSString *host = [url host];
    NSString *path = [url path];
    if ([path length] == 0) path = @"/";
    if ([[url query] length]) path = [path stringByAppendingFormat:@"?%@", [url query]];

    NSString *method = [request HTTPMethod] ?: @"GET";

    NSMutableString *head = [NSMutableString string];
    [head appendFormat:@"%@ %@ HTTP/1.1\r\n", method, path];
    [head appendFormat:@"Host: %@\r\n", host];

    NSDictionary *fields = [request allHTTPHeaderFields];
    for (NSString *name in fields) {
        if ([name caseInsensitiveCompare:@"Host"] == NSOrderedSame) continue;
        if ([name caseInsensitiveCompare:@"Connection"] == NSOrderedSame) continue;
        // Identity encoding keeps the response reader simple.
        if ([name caseInsensitiveCompare:@"Accept-Encoding"] == NSOrderedSame) continue;
        [head appendFormat:@"%@: %@\r\n", name, [fields objectForKey:name]];
    }
    if (![fields objectForKey:@"User-Agent"])
        [head appendString:@"User-Agent: Mozilla/5.0 (AppleTV; CPU OS 8_4 like Mac OS X) AppleWebKit/600.1.4\r\n"];
    [head appendString:@"Accept-Encoding: identity\r\n"];

    NSData *body = [request HTTPBody];
    if ([body length]) [head appendFormat:@"Content-Length: %lu\r\n", (unsigned long)[body length]];
    [head appendString:@"Connection: keep-alive\r\n\r\n"];

    NSMutableData *out = [NSMutableData dataWithData:[head dataUsingEncoding:NSUTF8StringEncoding]];
    if ([body length]) [out appendData:body];

    MSXHTTPSResponse *result = [[[MSXHTTPSResponse alloc] init] autorelease];
    NSError *error = nil;

    if (![connection writeAll:out error:&error]) {
        if (connection.reused) { *retryable = YES; return nil; }
        result.error = error;
        return result;
    }

    // ---- status line ----------------------------------------------------
    NSData *statusLine = [connection readLine];
    if (!statusLine) {
        // A pooled connection the server had already closed looks exactly like
        // this; retry once rather than surfacing a spurious failure.
        if (connection.reused) { *retryable = YES; return nil; }
        result.error = MSXHTTPSError(-3, @"no response");
        return result;
    }
    NSString *status = [[[NSString alloc] initWithData:statusLine
                                              encoding:NSISOLatin1StringEncoding] autorelease];
    NSArray *parts = [status componentsSeparatedByString:@" "];
    result.statusCode = [parts count] > 1 ? [[parts objectAtIndex:1] integerValue] : 0;

    // ---- headers --------------------------------------------------------
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    while (1) {
        NSData *lineData = [connection readLine];
        if (!lineData) { result.error = MSXHTTPSError(-3, @"truncated headers"); return result; }
        if ([lineData length] == 0) break;

        NSString *line = [[[NSString alloc] initWithData:lineData
                                                encoding:NSISOLatin1StringEncoding] autorelease];
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *name = [[line substringToIndex:colon.location]
                          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *value = [[line substringFromIndex:NSMaxRange(colon)]
                           stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *existing = [headers objectForKey:name];
        // Repeated headers (Set-Cookie above all) are joined the way
        // NSHTTPURLResponse itself reports them.
        [headers setObject:(existing ? [existing stringByAppendingFormat:@", %@", value] : value)
                    forKey:name];
    }
    result.headers = headers;

    if (isCancelled && isCancelled()) { result.error = MSXHTTPSError(-999, @"cancelled"); return result; }

    // ---- body -----------------------------------------------------------
    NSString *transferEncoding = MSXHeader(headers, @"Transfer-Encoding");
    NSString *contentLength    = MSXHeader(headers, @"Content-Length");
    NSString *connectionHeader = MSXHeader(headers, @"Connection");

    BOOL bodyless = ([method caseInsensitiveCompare:@"HEAD"] == NSOrderedSame ||
                     result.statusCode == 204 || result.statusCode == 304 ||
                     (result.statusCode >= 100 && result.statusCode < 200));

    if (bodyless) {
        result.body = [NSData data];
    } else if (transferEncoding &&
               [transferEncoding rangeOfString:@"chunked" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        NSMutableData *assembled = [NSMutableData data];
        while (1) {
            NSData *sizeLine = [connection readLine];
            if (!sizeLine) { result.error = MSXHTTPSError(-4, @"truncated chunk header"); return result; }
            NSString *sizeText = [[[NSString alloc] initWithData:sizeLine
                                                       encoding:NSISOLatin1StringEncoding] autorelease];
            NSRange semi = [sizeText rangeOfString:@";"];
            if (semi.location != NSNotFound) sizeText = [sizeText substringToIndex:semi.location];
            unsigned long size = strtoul([sizeText UTF8String], NULL, 16);
            if (size == 0) break;

            NSData *chunk = [connection readExactly:size];
            if (!chunk) { result.error = MSXHTTPSError(-4, @"truncated chunk"); return result; }
            [assembled appendData:chunk];
            [connection readLine];                       // the chunk's trailing CRLF
        }
        while (1) {                                      // trailers, then blank line
            NSData *trailer = [connection readLine];
            if (!trailer || [trailer length] == 0) break;
        }
        result.body = assembled;
    } else if (contentLength) {
        NSUInteger length = (NSUInteger)[contentLength longLongValue];
        NSData *data = length ? [connection readExactly:length] : [NSData data];
        if (!data) { result.error = MSXHTTPSError(-4, @"truncated body"); return result; }
        result.body = data;
    } else {
        // No framing: the body ends when the connection does, so it cannot be
        // pooled afterwards.
        result.body = [connection readUntilClose];
        return result;
    }

    *reusable = !(connectionHeader &&
                  [connectionHeader rangeOfString:@"close" options:NSCaseInsensitiveSearch].location != NSNotFound);
    return result;
}

#pragma mark - Public

+ (MSXHTTPSResponse *)performRequest:(NSURLRequest *)request
                           cancelled:(BOOL (^)(void))isCancelled
{
    if (![self prepareTLS]) {
        MSXHTTPSResponse *r = [[[MSXHTTPSResponse alloc] init] autorelease];
        r.error = MSXHTTPSError(-1, @"TLS not initialised");
        return r;
    }

    NSURL *url = [request URL];
    NSString *host = [url host];
    NSString *port = [url port] ? [[url port] stringValue] : @"443";

    for (int attempt = 0; attempt < 2; attempt++) {
        NSError *error = nil;
        MSXConnection *connection = MSXAcquire(host, port, &error);
        if (!connection) {
            MSXHTTPSResponse *r = [[[MSXHTTPSResponse alloc] init] autorelease];
            r.error = error ?: MSXHTTPSError(-1, @"could not connect");
            return r;
        }

        BOOL reusable = NO, retryable = NO;
        MSXHTTPSResponse *response = [self attempt:request connection:connection
                                         cancelled:isCancelled
                                          reusable:&reusable retryable:&retryable];
        if (response) {
            MSXRelease(connection, reusable && !response.error);
            return response;
        }

        // The pooled connection was stale; drop it and go around once more.
        MSXRelease(connection, NO);
    }

    MSXHTTPSResponse *r = [[[MSXHTTPSResponse alloc] init] autorelease];
    r.error = MSXHTTPSError(-5, @"connection could not be re-established");
    return r;
}

@end
