# Media Station X for Apple TV 3

[Media Station X](https://msx.benzac.de/) as a standalone app on the Apple TV 3,
on the home screen next to Kodi rather than running inside it.

## Tested on

Everything here was built and verified against one machine:

| | |
| --- | --- |
| Model | Apple TV 3 rev A — `AppleTV3,2` (A1469), board `J33iAP` |
| SoC | `S5L8947X`, **armv7** (32-bit; there is no arm64 slice) |
| OS | Apple TV Software 7.9 / iOS **8.4.4**, build `12H1006` |
| Jailbreak | [Blackb0x](https://github.com/NSSpiral/Blackb0x) (untethered on 8.4.x) |
| Appliance loader | BeigeList 2.2.6-30 |

It should apply to `AppleTV3,1` (A1427) on the same firmware, since that is the
same software with a different board, but that is untested here. The Apple TV 2
(`AppleTV2,1`) is a different enough UI generation that it is not a safe
assumption.

## Requirements

- **A jailbroken Apple TV 3** with ssh access.
  [Blackb0x](https://github.com/NSSpiral/Blackb0x) is what this was developed
  against; it is untethered on 8.4.x for both Apple TV 3 models and installs
  Kodi as part of the process.
- **A tweak that lets the AppleTV UI load third-party appliances.** This is what
  puts a `.frappliance` on the home screen at all. The tested device uses
  BeigeList; the older `org.awkwardtv.whitelist` serves the same purpose and is
  what Kodi's own package depends on. **If Kodi already runs, you have this** —
  which is the case out of the box after a Blackb0x install.
- **A Mac with Xcode**, to build. Its clang still emits `armv7`, so nothing
  older is needed; the one thing it cannot supply is an SDK with `UIWebView` in
  it, which `make` fetches for you.

## Build

```bash
make
```

The first build runs `scripts/fetch-deps.sh`, which pulls in three things this
repository does not carry:

- **`sdk/iPhoneOS9.3.sdk`** (~56 MB) — modern iOS SDKs no longer ship the
  headers this target needs; `UIWebView` was removed outright. Set `SDK=` to
  point at an existing copy instead.
- **`vendor/libmbedtls-armv7.a`** — built from mbedTLS 2.28.8, see below.
- **`vendor/cacert.pem`** — a current CA bundle.

`make distclean` removes all three.

```bash
./scripts/mkdeb.sh          # build/de.benzac.msx-atv3_1.0-3_iphoneos-arm.deb
```

## Install

```bash
scp build/de.benzac.msx-atv3_*.deb atv:/tmp/msx.deb
ssh atv 'dpkg -i /tmp/msx.deb'
```

The Apple TV UI restarts and **Media Station X** appears on the home screen.
`dpkg -i` takes a minute or two on this hardware — that is normal.

Remove it with `dpkg -r de.benzac.msx-atv3`.

## Configuration

The start URL is read at every launch, so you can point it at a self-hosted
instance or a start parameter without rebuilding:

```bash
ssh atv 'echo "http://msx.benzac.de/#{...}" > /var/mobile/Library/Preferences/MediaStationX/url.txt'
```

## Remote control

| Remote | Media Station X |
| --- | --- |
| Up / Down / Left / Right | Arrow keys |
| Select, Play | Enter |
| Menu | Back |
| **Menu (hold)** | Leaves the app |

Holding Menu always exits, so a page that stops responding cannot trap you.

## Request logging

Media Station X is a single page application, and selecting an "app" inside it
often navigates the web view away entirely, so it is useful to see where it
actually goes. Enable it with a marker file and read `/tmp/msx-urls.log`:

```bash
ssh atv 'touch /var/mobile/Library/Preferences/MediaStationX/log-urls'
# restart the UI, use the app, then:
ssh atv 'grep navigate /tmp/msx-urls.log'
```

It is opt-in because the log is unbounded; delete the marker file to stop.

`UIWebView` on iOS 8 loads through `NSURLConnection`, so `MSXURLProtocol` sees
every request — XHR, CSS and images included — which a `UIWebViewDelegate` alone
would miss. Lines are tagged `request`, `navigate` for page navigations,
`tls-bridge` for requests carried by the bundled TLS stack, and `media` for
`<video>` sources.

Media deserves its own tag because those URLs are otherwise invisible: `<video>`
is fetched by `mediaserverd`, a separate process, so the only way to see them is
to hook the assignment in the page, which this switch also enables.

Note that the log records requests *attempted*, not requests that succeeded.

## Reaching modern HTTPS

The Apple TV 3 cannot reach a large and growing part of the web on its own, for
two independent reasons:

- **No AEAD ciphers.** Its Secure Transport offers 58 cipher suites, every one
  of them CBC or RC4. Hosts that require AES-GCM or ChaCha20-Poly1305 —
  `msx.benzac.de` among them — have nothing to negotiate with, and the
  handshake fails outright.
- **A 2015 trust store.** Anything chaining to a newer root (Let's Encrypt's
  ISRG roots, for instance) fails verification even when the ciphers do match.

Both are fixed by not using the system's TLS at all. The appliance links a
current **mbedTLS** and ships its own CA bundle, and `MSXURLProtocol` claims
`https://` requests and services them itself. `UIWebView` on iOS 8 loads through
`NSURLConnection`, so this covers page loads, XHR, CSS, scripts and images
without any proxy or port.

It is **opt-in**, because it replaces the system's TLS for every `https` request
in the process:

```bash
ssh atv 'touch /var/mobile/Library/Preferences/MediaStationX/tls-bridge'
```

With it on, `https://msx.benzac.de/` works as a start URL, and hosts that
previously could not be reached at all respond normally. Apple's own domains
(`apple.com`, `mzstatic.com`, `icloud.com`, …) are excluded by default: the
`NSURLProtocol` is process-wide, the system reaches those perfectly well, and
interposing on the AppleTV UI's own iTunes traffic is a needlessly wide
footprint. Add more hosts one per line in `tls-bridge-exclude`.

### Not every app inside Media Station X can render here

Reaching a host is one thing; rendering what it sends is another. The web engine
is WebKit 600 from 2015, and apps built with a modern toolchain frequently
depend on CSS it does not have:

```
css: transform=NO  webkitTransform=yes  flex=NO  grid=NO  vars=NO  calc=yes
```

Unprefixed flexbox arrived in Safari 9; this is iOS 8, so `display: flex` is
simply ignored. One service reached from inside Media Station X shows what that
costs: its flex row collapses to ordinary block stacking, leaving the navigation
column at its natural 276 px on the left and every sibling stacked beneath it
rather than beside it:

```
DIV.flex     0,0 1920x1080
  NAV        0,0  276x1080      <- should sit beside its siblings
elements=1084  contentExtent=1920x53262
```

A 53,000 px tall page, which on screen looks like a UI jammed into the left
edge. Nothing about the port causes this and nothing in it can fix it: CSS
custom properties are unsupported too, and current CSS frameworks resolve most
of their utilities through them. Media Station X itself is fine — it is ES5 with
old-fashioned CSS, which is exactly why it runs here at all.

### What it does not cover

**Video.** `<video>` playback is handled by `mediaserverd`, a separate process
that never sees this `NSURLProtocol`, so HTTPS media is unaffected by any of the
above.

Plain **HTTP video works already** — an HTTP HLS stream plays inline on the
device, and the media stack reports `hls=maybe h264=probably webm=no`. Note that
`hevc=maybe` is `canPlayType` being optimistic: the A5 has no HEVC decoder, so
H.264/AAC is the real target.

Covering HTTPS media would need a genuine local proxy: an HTTP server on
`127.0.0.1` fetching upstream through mbedTLS, with Range support for seeking,
streaming rather than buffering whole responses, and m3u8 rewriting so the
playlist's segment and key URIs point back at it. That is not built here. Media
URLs are logged (tagged `media`) so it is possible to tell first whether a given
service even needs it.

**Speed.** A TLS handshake is a few hundred milliseconds of software crypto on
an A5, which is ruinous for a page pulling hundreds of images, so connections
are kept alive and pooled per host (6 idle, 20 s timeout). A pooled connection
the server has already closed is indistinguishable from a failure until you
write to it, so a stale one is retried once on a fresh connection.

Measured on a page loading a grid of poster images, request to request:

| | per request |
| --- | --- |
| connection per request | ~470 ms |
| pooled | ~65 ms |

A first request to a host still pays for the handshake.

## How it works

The Apple TV 3 home screen is `AppleTV.app` ("Lowtide"), which loads
third-party apps as Front Row appliance bundles (`.frappliance`) from
`/Applications`, registered by a symlink in
`/Applications/AppleTV.app/Appliances/`. This is the same mechanism Kodi uses.

An appliance is an `MH_BUNDLE` whose `NSPrincipalClass` implements BackRow's
`BRAppliance` protocol. The catch is that BackRow's classes live inside the
`AppleTV` executable and export no symbols at all, so they cannot be linked
against:

```
$ nm -gU AppleTV | grep -c 'OBJC_CLASS_\$_'
0
```

So, as Kodi does, both classes are created at runtime with
`objc_allocateClassPair()` and their implementations grafted over from template
classes compiled normally ([src/MSXAppliance.m](src/MSXAppliance.m)):

- `MSXAppliance : BRBaseAppliance` publishes one category and returns a
  controller when it is selected.
- `MSXController : BRController` is a `UIView` holding a full-screen
  `UIWebView`.

Two things needed handling to host a plain `UIView` inside BackRow:

- **BackRow walks the view tree assuming every subview is a `BRControl`** and
  sends it `-active`, `-parent` and friends, which killed the UI process with
  `-[UIWebView active]: unrecognized selector`. A category on `UIView` answers
  them; `BRControl` subclasses keep their own implementations, so only views
  that have none fall through to it.
- **BackRow descends from Front Row, whose layer tree uses a bottom-left
  origin.** One `BRControlLayer` ancestor has `geometryFlipped = YES`, which
  rendered the web view upside down. The controller counts flipped ancestors
  once attached and cancels an odd count, so this is derived at runtime rather
  than hard-coded.

### Skipping BeigeList's category menu

Third-party appliances are not presented by Lowtide directly — the BeigeList
tweak wraps each one as a "legacy merchant" and, when its tile is selected,
pushes a `BLAppLegacyCategoryController` (a `BRMenuController`) listing the
appliance's categories. For a single-category appliance that is a menu with one
entry and no purpose.

It is not configurable: dumping BeigeList's own model at runtime shows Kodi and
this appliance as equivalent `BLAppLegacyMerchant` entries, so there is no flag
that distinguishes them. Instead, `MSXInstallCategorySkip()` adds a `wasPushed`
override to that class which — **only when the appliance is ours** — selects the
single entry immediately and then removes the menu from the stack. Other
appliances are untouched, and dropping the menu also makes Menu return straight
to the home screen. The whole hop takes about 30 ms and is not visible.

Remote presses arrive as `BREvent`s and are injected into the page as synthetic
`keydown`/`keyup` pairs, which is what Media Station X listens for.

A `UIWindow` of our own, layered above the appliance screen the way Kodi does
it, is *not* a workable alternative here: `makeKeyAndVisible` takes key-window
status away from BackRow's `BRKeyCommandControl`, and remote input stops
reaching the controller entirely.

Two quirks of the home screen tile, both learned from Kodi's bundle: the menu
does not round tiles, so the corners are baked into the PNG with alpha; and the
caption comes from `English.lproj/InfoPlist.strings`, not from `CFBundleName`
or `FRApplianceName` in `Info.plist`.

The bundle is deliberately **unsigned** — Kodi's is too, and this jailbreak
loads unsigned bundles.

## Troubleshooting

The appliance writes failures to `/tmp/msx.log` on the device and installs an
uncaught exception handler, so if the UI process dies the exception name, reason
and backtrace land there. That is all it writes by default.

For a full lifecycle trace — class registration, controller push and pop, the
start URL, orientation detection, remote codes — switch on debug logging:

```bash
ssh atv 'touch /var/mobile/Library/Preferences/MediaStationX/debug'
```

If you replace the bundle by hand rather than through `dpkg`, note that
**`killall AppleTV` is unreliable**: the UI ignores SIGTERM while an appliance
is on screen and still exits 0, so the files get replaced while the old bundle
keeps running and it looks like nothing changed. The package's `postinst`
escalates to SIGKILL and confirms the pid actually changed.

## Credit

Media Station X is by Benjamin Zachey — <https://msx.benzac.de/>. This
repository only packages it as an Apple TV 3 appliance and contains none of its
code. The appliance plumbing follows the approach the XBMC/Kodi ATV2 port
established (<https://github.com/xbmc/atv2>).
