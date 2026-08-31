#import "MSXLog.h"

NSString *const kMSXPrefsDir = @"/var/mobile/Library/Preferences/MediaStationX";

static NSString *const kMSXLogPath    = @"/tmp/msx.log";
static NSString *const kMSXURLLogPath = @"/tmp/msx-urls.log";

static NSString *MSXTimestamp(void) {
    static NSDateFormatter *df = nil;
    if (!df) {
        df = [[NSDateFormatter alloc] init];
        [df setDateFormat:@"HH:mm:ss.SSS"];
    }
    return [df stringFromDate:[NSDate date]];
}

static void MSXWrite(NSString *line) {
    NSLog(@"[MSX] %@", line);
    NSString *stamped = [NSString stringWithFormat:@"%@ %@\n", MSXTimestamp(), line];
    FILE *f = fopen([kMSXLogPath UTF8String], "a");
    if (f) { fputs([stamped UTF8String], f); fclose(f); }
}

void MSXLog(NSString *format, ...) {
    va_list ap;
    va_start(ap, format);
    NSString *line = [[[NSString alloc] initWithFormat:format arguments:ap] autorelease];
    va_end(ap);
    MSXWrite(line);
}

BOOL MSXDebugEnabled(void) {
    static int enabled = -1;
    if (enabled < 0) {
        NSString *flag = [kMSXPrefsDir stringByAppendingPathComponent:@"debug"];
        enabled = [[NSFileManager defaultManager] fileExistsAtPath:flag] ? 1 : 0;
    }
    return enabled == 1;
}

void MSXDebug(NSString *format, ...) {
    if (!MSXDebugEnabled()) return;
    va_list ap;
    va_start(ap, format);
    NSString *line = [[[NSString alloc] initWithFormat:format arguments:ap] autorelease];
    va_end(ap);
    MSXWrite(line);
}

BOOL MSXURLLoggingEnabled(void) {
    static int enabled = -1;
    if (enabled < 0) {
        NSString *flag = [kMSXPrefsDir stringByAppendingPathComponent:@"log-urls"];
        enabled = [[NSFileManager defaultManager] fileExistsAtPath:flag] ? 1 : 0;
    }
    return enabled == 1;
}

// Requests arrive on several threads, so serialise the writes and keep the file
// open rather than reopening it for every resource.
void MSXLogURL(NSString *kind, NSString *url) {
    if (!MSXURLLoggingEnabled() || [url length] == 0) return;

    static dispatch_queue_t queue;
    static FILE *file;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("de.benzac.msx.urllog", NULL);
        file = fopen([kMSXURLLogPath UTF8String], "a");
    });

    NSString *line = [NSString stringWithFormat:@"%@ %-9s %@\n", MSXTimestamp(), [kind UTF8String], url];
    dispatch_async(queue, ^{
        if (!file) return;
        fputs([line UTF8String], file);
        fflush(file);
    });
}

static NSUncaughtExceptionHandler *gPreviousHandler = NULL;

static void MSXExceptionHandler(NSException *e) {
    MSXLog(@"UNCAUGHT EXCEPTION %@: %@", [e name], [e reason]);
    for (NSString *frame in [e callStackSymbols]) MSXLog(@"    %@", frame);
    if (gPreviousHandler) gPreviousHandler(e);
}

void MSXInstallExceptionLogger(void) {
    gPreviousHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(&MSXExceptionHandler);
}
