//
//  Shared logging and configuration paths.
//
#import <Foundation/Foundation.h>

// The AppleTV UI process has no reachable syslog on this device, so log lines
// are also appended to /tmp/msx.log.
//
// MSXLog is for the rare and the important -- failures, and the one-off notes
// that explain a failure.  It is always on, because a UI process that dies
// leaves nothing else behind.
void MSXLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

// MSXDebug is for lifecycle tracing, and is silent unless switched on:
//   ssh atv 'touch /var/mobile/Library/Preferences/MediaStationX/debug'
void MSXDebug(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
BOOL MSXDebugEnabled(void);

// Appends to /tmp/msx-urls.log when URL logging is switched on.  `kind` is a
// short tag such as "request", "navigate" or "https".
void MSXLogURL(NSString *kind, NSString *url);
BOOL MSXURLLoggingEnabled(void);

// Logs the name, reason and backtrace of anything that would otherwise kill the
// UI process, then chains to whatever handler was already installed.
void MSXInstallExceptionLogger(void);

// /var/mobile/Library/Preferences/MediaStationX
extern NSString *const kMSXPrefsDir;
