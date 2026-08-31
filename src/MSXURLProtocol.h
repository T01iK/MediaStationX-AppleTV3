//
//  Routes the web view's https:// requests through the bundled TLS stack.
//
#import <Foundation/Foundation.h>

@interface MSXURLProtocol : NSURLProtocol
// Registers the protocol.  Off unless the user opted in; see +isEnabled.
+ (void)install;
+ (BOOL)isEnabled;
@end
