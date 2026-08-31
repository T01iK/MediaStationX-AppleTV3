//
//  A minimal HTTPS client built on a bundled mbedTLS.
//
//  This device's Secure Transport offers no AEAD cipher suites and carries a
//  2015 trust store, so a growing number of hosts are simply unreachable
//  through it.  mbedTLS plus a current CA bundle reaches them.
//
#import <Foundation/Foundation.h>

@interface MSXHTTPSResponse : NSObject
@property (nonatomic, assign) NSInteger statusCode;
@property (nonatomic, retain) NSDictionary *headers;   // canonicalised header names
@property (nonatomic, retain) NSData *body;
@property (nonatomic, retain) NSError *error;          // nil on success
@end

@interface MSXHTTPS : NSObject

// Path to the bundled CA bundle; set once at startup.
+ (void)setCABundlePath:(NSString *)path;
+ (NSString *)caBundlePath;

// Performs one request synchronously.  Intended to be called off the main
// thread.  Redirects are *not* followed: the response is returned as-is so the
// URL loading system can follow them through its own machinery.
+ (MSXHTTPSResponse *)performRequest:(NSURLRequest *)request
                           cancelled:(BOOL (^)(void))isCancelled;

@end
