//
//  Media Station X appliance for Apple TV 3 (AppleTV.app / "Lowtide", iOS 8.4.4)
//
//  BackRow's appliance and controller classes live inside the AppleTV
//  executable and export no symbols, so they cannot be linked against.  As
//  Kodi does, the appliance and controller classes are built at runtime with
//  objc_allocateClassPair() and their implementations are grafted over from
//  template classes compiled normally here.
//
//  The UI itself is Media Station X running in a UIWebView.
//

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "MSXLog.h"
#import "MSXHTTPS.h"
#import "MSXURLProtocol.h"

#pragma mark - Configuration

static NSString *const kMSXCategoryIdentifier = @"msx.main";
static NSString *const kMSXDefaultURL = @"http://msx.benzac.de/";

// The start URL is read from a plain text file so it can be pointed at a
// self-hosted Media Station X or a start parameter without rebuilding.
static NSString *MSXStartURL(void) {
    NSString *path = [kMSXPrefsDir stringByAppendingPathComponent:@"url.txt"];
    NSString *value = [NSString stringWithContentsOfFile:path
                                                encoding:NSUTF8StringEncoding
                                                   error:NULL];
    value = [value stringByTrimmingCharactersInSet:
             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([value length] > 0) return value;
    return kMSXDefaultURL;
}

#pragma mark - BackRow control-protocol shims

// BackRow walks the view tree of a pushed BRController assuming every subview
// is a BRControl, and sends it -active, -parent and friends.  A UIWebView is
// not a BRControl, so answer those selectors on plain UIViews.  BRControl
// subclasses keep their own implementations; only views that have none fall
// through to these.  (Kodi/XBMC does exactly this for its GL view.)
@interface UIView (MSXBackRowCompatibility)
@end

@implementation UIView (MSXBackRowCompatibility)
- (id)parent { return nil; }
- (id)root { return nil; }
- (BOOL)active { return NO; }
- (void)removeFromParent {}
- (void)controlWasActivated {}
- (void)controlWasDeactivated {}
- (void)layoutSubcontrols {}
- (BOOL)acceptsFocus { return NO; }
- (void)windowMaxBoundsChanged {}
@end

@interface UIWindow (MSXBackRowCompatibility)
@end

@implementation UIWindow (MSXBackRowCompatibility)
- (id)parent { return nil; }
- (BOOL)active { return NO; }
- (void)removeFromParent {}
- (void)controlWasActivated {}
- (void)controlWasDeactivated {}
@end

#pragma mark - Runtime class construction

static void MSXGraftMethods(Class dest, Class source) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(source, &count);
    for (unsigned int i = 0; i < count; i++) {
        Method m = methods[i];
        class_addMethod(dest, method_getName(m), method_getImplementation(m),
                        method_getTypeEncoding(m));
    }
    free(methods);
}

static Class MSXMakeSubclass(const char *superName, const char *newName, Class templateClass) {
    Class existing = objc_getClass(newName);
    if (existing) return existing;

    Class superClass = objc_getClass(superName);
    if (!superClass) {
        MSXLog(@"FATAL: superclass %s not found", superName);
        return Nil;
    }
    Class cls = objc_allocateClassPair(superClass, newName, 0);
    if (!cls) {
        MSXLog(@"FATAL: could not allocate class %s", newName);
        return Nil;
    }
    MSXGraftMethods(cls, templateClass);
    objc_registerClassPair(cls);
    MSXDebug(@"registered %s : %s", newName, superName);
    return cls;
}

// Methods grafted onto the runtime-built controller need to reach BRController's
// implementations.  The superclass is captured once at registration rather than
// derived from the instance, so these stay correct regardless of the receiver.
static Class gControllerSuper = Nil;

static void MSXSuperVoid(id self, SEL sel) {
    struct objc_super s = { self, gControllerSuper };
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&s, sel);
}

static BOOL MSXSuperEvent(id self, SEL sel, id event) {
    struct objc_super s = { self, gControllerSuper };
    return ((BOOL (*)(struct objc_super *, SEL, id))objc_msgSendSuper)(&s, sel, event);
}

#pragma mark - Remote control mapping

// BREvent remote action codes (from the XBMC ATV2 port).  The second value in
// each pair is the code the aluminium remote reports for the same button.
enum {
    kBREventRemoteActionMenu        = 1,
    kBREventRemoteActionMenuHold    = 2,
    kBREventRemoteActionUp          = 3,
    kBREventRemoteActionDown        = 4,
    kBREventRemoteActionPlay        = 5,
    kBREventRemoteActionLeft        = 6,
    kBREventRemoteActionRight       = 7,
    kBREventRemoteActionPlayHold    = 22,
    kBREventRemoteActionCenterHold  = 23,
};

// Browser key codes Media Station X listens for.
enum {
    kJSKeyBackspace = 8,
    kJSKeyEnter     = 13,
    kJSKeyLeft      = 37,
    kJSKeyUp        = 38,
    kJSKeyRight     = 39,
    kJSKeyDown      = 40,
};

// Returns the JS key code for a remote action, or 0 if it is not mapped.
static int MSXKeyCodeForRemoteAction(int action) {
    switch (action) {
        case kBREventRemoteActionUp:    case 65676: return kJSKeyUp;
        case kBREventRemoteActionDown:  case 65677: return kJSKeyDown;
        case kBREventRemoteActionLeft:  case 65675: return kJSKeyLeft;
        case kBREventRemoteActionRight: case 65674: return kJSKeyRight;
        case kBREventRemoteActionPlay:  case 65673: return kJSKeyEnter;
        case kBREventRemoteActionMenu:              return kJSKeyBackspace;
        default: return 0;
    }
}

#pragma mark - Controller template

@interface MSXControllerTemplate : UIView
@end

@implementation MSXControllerTemplate

// Runtime-built classes cannot gain ivars after registration, so the window and
// web view are held as associated objects.
static const void *kWebViewKey  = &kWebViewKey;
static const void *kOrientedKey = &kOrientedKey;

- (UIWebView *)msx_webView { return objc_getAssociatedObject(self, kWebViewKey); }

// The appliance's own screen (ATVApplianceController) puts a category bar above
// whatever it installs, so a plain subview leaves that bar on screen with focus
// on it -- a menu with one entry.  Kodi avoids this by living in its own
// UIWindow added to BackRow's window content, which covers the bar entirely.
// Do the same.
- (void)msx_build {
    if ([self msx_webView]) return;

    CGRect frame = self.bounds;
    if (CGRectIsEmpty(frame)) frame = [[UIScreen mainScreen] bounds];

    UIWebView *web = [[[UIWebView alloc] initWithFrame:frame] autorelease];
    web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    web.backgroundColor = [UIColor blackColor];
    web.opaque = YES;
    web.scalesPageToFit = NO;
    web.dataDetectorTypes = UIDataDetectorTypeNone;
    web.allowsInlineMediaPlayback = YES;
    web.mediaPlaybackRequiresUserAction = NO;
    web.scrollView.scrollEnabled = NO;
    web.scrollView.bounces = NO;
    web.delegate = (id)self;

    self.backgroundColor = [UIColor blackColor];
    [self addSubview:web];
    objc_setAssociatedObject(self, kWebViewKey, web, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSString *url = MSXStartURL();
    MSXDebug(@"loading %@ into %@", url, NSStringFromCGRect(frame));
    [web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:url]]];
}

// BackRow descends from Front Row, whose layer tree uses a bottom-left origin,
// which renders a plain UIView upside down.  Count the flipped layers above us
// and cancel an odd number out.
- (void)msx_correctOrientationOf:(UIView *)view {
    if (!view || objc_getAssociatedObject(view, kOrientedKey)) return;

    int flips = 0;
    NSMutableString *chain = [NSMutableString string];
    for (CALayer *l = view.layer; l != nil; l = l.superlayer) {
        BOOL f = l.geometryFlipped;
        if (f) flips++;
        CATransform3D st = l.sublayerTransform;
        if (st.m22 < 0) flips++;
        [chain appendFormat:@"%@%@ ", [l class], f ? @"(geometryFlipped)" : @""];
    }
    MSXDebug(@"layer chain: %@", chain);

    MSXDebug(@"orientation: %d flipped ancestors", flips);
    if (flips % 2) view.layer.geometryFlipped = YES;

    // Mark as done so a re-activation does not flip it back.
    objc_setAssociatedObject(view, kOrientedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)msx_teardown {
    UIWebView *web = [self msx_webView];
    [web stopLoading];
    [web loadHTMLString:@"" baseURL:nil];
    [web removeFromSuperview];
    objc_setAssociatedObject(self, kWebViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// --- UIWebViewDelegate -------------------------------------------------------
// Page-level navigations only; the NSURLProtocol tap above covers the rest.

// Media loaded by <video> is fetched by mediaserverd, a separate process, so it
// never passes through MSXURLProtocol and cannot be seen in the request log.
// Hooking the assignment in the page is the only way to learn those URLs -- and
// whether they are http (already fine) or https (which would need a proxy).
- (void)msx_installMediaHook:(UIWebView *)webView {
    if (!MSXURLLoggingEnabled()) return;
    [webView stringByEvaluatingJavaScriptFromString:
        @"(function(){"
        @"  if (window.__msxMediaHook) return; window.__msxMediaHook = 1;"
        @"  function report(kind, url){"
        @"    try {"
        @"      var f = document.createElement('iframe');"
        @"      f.style.display = 'none';"
        @"      f.src = 'msxlog://media?' + kind + '=' + encodeURIComponent(String(url));"
        @"      (document.body || document.documentElement).appendChild(f);"
        @"      setTimeout(function(){ if (f.parentNode) f.parentNode.removeChild(f); }, 0);"
        @"    } catch (e) {}"
        @"  }"
        @"  var proto = window.HTMLMediaElement && HTMLMediaElement.prototype;"
        @"  if (!proto) return;"
        @"  var d = Object.getOwnPropertyDescriptor(proto, 'src');"
        @"  if (d && d.set) Object.defineProperty(proto, 'src', {"
        @"    get: d.get, set: function(v){ report('src', v); d.set.call(this, v); } });"
        @"  var sa = Element.prototype.setAttribute;"
        @"  proto.setAttribute = function(n, v){"
        @"    if (String(n).toLowerCase() === 'src') report('attr', v);"
        @"    return sa.call(this, n, v); };"
        @"})();"];
}

- (BOOL)webView:(UIWebView *)webView
        shouldStartLoadWithRequest:(NSURLRequest *)request
        navigationType:(UIWebViewNavigationType)navigationType {
    NSURL *url = [request URL];

    // The page's channel back to us; see -msx_installMediaHook:.
    if ([[[url scheme] lowercaseString] isEqualToString:@"msxlog"]) {
        NSString *payload = [[url query] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        MSXDebug(@"media url: %@", payload);
        MSXLogURL(@"media", payload);
        return NO;
    }

    MSXLogURL(@"navigate", [url absoluteString]);
    return YES;
}

- (void)webViewDidFinishLoad:(UIWebView *)webView {
    MSXDebug(@"page loaded: %@", [[[webView request] URL] absoluteString]);
    // Re-installed on every load: a page reached from inside Media Station X
    // replaces the document, and the hook goes with it.
    [self msx_installMediaHook:webView];
}

- (void)webView:(UIWebView *)webView didFailLoadWithError:(NSError *)error {
    MSXLog(@"load failed: %@", [error localizedDescription]);
    MSXLogURL(@"failed", [error localizedDescription]);
}

// Dispatch a synthetic keydown/keyup pair.  Old WebKit ignores keyCode passed
// to initKeyboardEvent, so build a generic event and set the field directly.
- (void)msx_sendKeyCode:(int)code {
    UIWebView *web = [self msx_webView];
    if (!web || code == 0) return;

    NSString *js = [NSString stringWithFormat:
        @"(function(k){"
        @"  var t = document;"
        @"  ['keydown','keyup'].forEach(function(n){"
        @"    var e = t.createEvent('Events');"
        @"    e.initEvent(n, true, true);"
        @"    e.keyCode = k; e.which = k; e.charCode = 0;"
        @"    t.dispatchEvent(e);"
        @"  });"
        @"})(%d);", code];
    [web stringByEvaluatingJavaScriptFromString:js];
}

// --- BRController lifecycle -------------------------------------------------

- (void)wasPushed {
    MSXSuperVoid(self, _cmd);
    MSXDebug(@"wasPushed");
    [self msx_build];
}

- (void)wasExhumed {
    MSXSuperVoid(self, _cmd);
    MSXDebug(@"wasExhumed");
    [self msx_build];
}

- (void)layoutSubviews {
    MSXSuperVoid(self, _cmd);
    UIWebView *web = [self msx_webView];
    if (!web || CGRectIsEmpty(self.bounds)) return;
    web.frame = self.bounds;
    [self msx_correctOrientationOf:web];
}

- (void)wasPopped {
    MSXDebug(@"wasPopped");
    [self msx_teardown];
    MSXSuperVoid(self, _cmd);
}

// --- Remote input -----------------------------------------------------------

- (BOOL)brEventAction:(id)event {
    int action = ((int (*)(id, SEL))objc_msgSend)(event, @selector(remoteAction));
    int value  = ((int (*)(id, SEL))objc_msgSend)(event, @selector(value));

    // Hold Menu always leaves the appliance, so there is a guaranteed way out
    // even if Media Station X stops responding.
    if (action == kBREventRemoteActionMenuHold) {
        MSXDebug(@"menu hold -> leaving appliance");
        return MSXSuperEvent(self, _cmd, event);
    }

    int code = MSXKeyCodeForRemoteAction(action);
    if (code != 0) {
        // BackRow reports both press (value 1) and release; only act on press.
        if (value == 1) [self msx_sendKeyCode:code];
        return YES;
    }

    MSXDebug(@"unmapped remote action=%d value=%d", action, value);
    return MSXSuperEvent(self, _cmd, event);
}

@end

#pragma mark - Appliance template

@interface MSXApplianceTemplate : NSObject
@end

@implementation MSXApplianceTemplate

- (NSArray *)applianceCategories {
    static NSArray *categories = nil;
    if (!categories) {
        Class catClass = objc_getClass("BRApplianceCategory");
        if (!catClass) {
            MSXLog(@"FATAL: BRApplianceCategory missing");
            return [NSArray array];
        }
        id cat = ((id (*)(Class, SEL, id, id, float))objc_msgSend)(
            catClass, @selector(categoryWithName:identifier:preferredOrder:),
            @"Media Station X", kMSXCategoryIdentifier, 0.0f);
        categories = [[NSArray arrayWithObject:cat] retain];
    }
    return categories;
}

- (id)msx_newController {
    Class ctl = objc_getClass("MSXController");
    if (!ctl) {
        MSXLog(@"FATAL: MSXController missing");
        return nil;
    }
    return [[[ctl alloc] init] autorelease];
}

- (id)controllerForIdentifier:(id)identifier args:(id)args {
    MSXDebug(@"controllerForIdentifier:%@", identifier);
    return [self msx_newController];
}

- (id)topShelfController { return nil; }
- (BOOL)handlePlay:(id)play userInfo:(id)info { return NO; }
- (id)identifierForContentAlias:(id)alias { return kMSXCategoryIdentifier; }

@end

#pragma mark - Bundle entry point

@interface MSXBootstrap : NSObject
@end

#pragma mark - Skipping BeigeList's category menu

// Third-party appliances are presented by the BeigeList tweak, which pushes a
// BLAppLegacyCategoryController (a BRMenuController) listing the appliance's
// categories.  With a single category that is a menu with one entry and no
// purpose, so for our appliance we select that entry as soon as the menu is
// pushed and then drop the menu from the stack, which also makes Menu return
// straight to the home screen.  Other appliances are untouched.

static Class gCategorySuper = Nil;

static BOOL MSXIsOurCategoryController(id controller) {
    if (![controller respondsToSelector:@selector(legacyAppliance)]) return NO;
    id appliance = [controller performSelector:@selector(legacyAppliance)];
    Class ours = objc_getClass("MSXAppliance");
    if (ours && [appliance isKindOfClass:ours]) return YES;
    // BeigeList may hand back its merchant wrapper rather than the appliance.
    return [[NSString stringWithFormat:@"%@", appliance]
            rangeOfString:@"mediastationx" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

// Invoke -itemSelected: for the first row, whatever argument type it takes.
static void MSXSelectFirstItem(id controller) {
    SEL sel = @selector(itemSelected:);
    NSMethodSignature *sig = [controller methodSignatureForSelector:sel];
    if (!sig) { MSXLog(@"no -itemSelected: signature"); return; }

    const char *type = [sig getArgumentTypeAtIndex:2];
    MSXDebug(@"selecting first item (arg type '%s')", type);

    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:controller];
    [inv setSelector:sel];
    if (type[0] == '@') {
        id item = [controller respondsToSelector:@selector(itemForRow:)]
            ? ((id (*)(id, SEL, long))objc_msgSend)(controller, @selector(itemForRow:), 0L)
            : nil;
        [inv setArgument:&item atIndex:2];
    } else if (type[0] == 'q' || type[0] == 'Q') {
        long long row = 0; [inv setArgument:&row atIndex:2];
    } else {
        long row = 0; [inv setArgument:&row atIndex:2];
    }
    [inv invoke];
}

static void MSXCategoryWasPushed(id self, SEL _cmd) {
    struct objc_super s = { self, gCategorySuper };
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&s, _cmd);

    if (!MSXIsOurCategoryController(self)) return;
    MSXDebug(@"our category menu pushed; entering directly");

    // Defer, so the push transaction finishes before another one starts.
    dispatch_async(dispatch_get_main_queue(), ^{
        MSXSelectFirstItem(self);
        // Drop the now-redundant menu so Menu goes straight to the home screen.
        dispatch_async(dispatch_get_main_queue(), ^{
            id stack = [self performSelector:@selector(stack)];
            if ([stack respondsToSelector:@selector(removeController:)]) {
                MSXDebug(@"removing category menu from the stack");
                [stack performSelector:@selector(removeController:) withObject:self];
            }
        });
    });
}

static void MSXInstallCategorySkip(void) {
    Class cat = objc_getClass("BLAppLegacyCategoryController");
    if (!cat) { MSXDebug(@"BLAppLegacyCategoryController not present yet"); return; }
    if (gCategorySuper) return;

    gCategorySuper = class_getSuperclass(cat);
    // The class does not define -wasPushed itself, so this adds an override
    // that chains to BRMenuController's.
    if (class_addMethod(cat, @selector(wasPushed), (IMP)MSXCategoryWasPushed, "v@:"))
        MSXDebug(@"installed category-menu skip (super=%@)", gCategorySuper);
    else
        MSXLog(@"could not install category-menu skip");
}

@implementation MSXBootstrap

+ (void)load {
    MSXDebug(@"bundle loaded (pid %d)", getpid());
    MSXInstallExceptionLogger();

    Class controller = MSXMakeSubclass("BRController", "MSXController", [MSXControllerTemplate class]);
    gControllerSuper = class_getSuperclass(controller);
    MSXMakeSubclass("BRBaseAppliance", "MSXAppliance", [MSXApplianceTemplate class]);

    // BeigeList registers its classes around the same time appliances load, so
    // try now and again once the run loop is going.
    // The CA bundle ships inside the appliance bundle.
    NSBundle *bundle = [NSBundle bundleForClass:self];
    [MSXHTTPS setCABundlePath:[bundle pathForResource:@"cacert" ofType:@"pem"]];
    [MSXURLProtocol install];

    MSXInstallCategorySkip();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ MSXInstallCategorySkip(); });
}

@end
