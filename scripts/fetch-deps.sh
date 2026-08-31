#!/bin/sh
# Fetches everything the build needs that is not in this repository:
#   sdk/iPhoneOS9.3.sdk        old iOS SDK (modern ones dropped UIWebView)
#   vendor/libmbedtls-armv7.a  a TLS stack this device's own one cannot match
#   vendor/cacert.pem          a current CA bundle (the 2015 trust store is stale)
set -e
cd "$(dirname "$0")/.."

SDK=sdk/iPhoneOS9.3.sdk
MBEDTLS_TAG=mbedtls-2.28.8

# ---------------------------------------------------------------- iOS 9.3 SDK
if [ -d "$SDK" ]; then
    echo "==> $SDK already present"
else
    echo "==> fetching iPhoneOS9.3.sdk"
    rm -rf sdk
    git clone --depth 1 --filter=blob:none --sparse https://github.com/theos/sdks.git sdk
    ( cd sdk && git sparse-checkout set iPhoneOS9.3.sdk )
fi

# The upstream SDK's stub libraries are incomplete in two ways that break this
# build, so patch both up.  Everything added here is genuinely exported by the
# device's own libSystem; only the .tbd descriptions are missing it.
if [ ! -f "$SDK/usr/lib/system/liblaunch.tbd" ]; then
    echo "==> adding missing liblaunch.tbd stub"
    # libSystem re-exports liblaunch, and without a stub the link fails with
    # "file not found: /usr/lib/system/liblaunch.dylib".
    cp sdk-patch/liblaunch.tbd "$SDK/usr/lib/system/liblaunch.tbd"
fi

# libsystem_c.tbd lists only the __platform_* aliases, not the plain C symbols,
# so anything using memcpy/memcmp/... from a static library fails to link.
python3 - "$SDK/usr/lib/system/libsystem_c.tbd" <<'PY'
import sys
path = sys.argv[1]
wanted = ["_memcpy", "_memmove", "_memset", "_memcmp", "_memchr", "_strcmp"]
text = open(path).read()
missing = [w for w in wanted if (w + ",") not in text and (w + " ]") not in text]
if missing:
    i = text.index("[", text.index("symbols:")) + 1
    open(path, "w").write(text[:i] + " " + ", ".join(missing) + "," + text[i:])
    print("==> added to libsystem_c.tbd:", " ".join(missing))
PY

# ------------------------------------------------------------------- mbedTLS
mkdir -p vendor
if [ -f vendor/libmbedtls-armv7.a ]; then
    echo "==> vendor/libmbedtls-armv7.a already built"
else
    if [ ! -d vendor/mbedtls ]; then
        echo "==> fetching mbedTLS $MBEDTLS_TAG"
        git clone --depth 1 -b "$MBEDTLS_TAG" -q https://github.com/Mbed-TLS/mbedtls.git vendor/mbedtls
    fi
    echo "==> building mbedTLS for armv7"
    SDK_ABS="$PWD/$SDK"
    CC=$(xcrun -f clang)
    rm -rf vendor/obj && mkdir -p vendor/obj
    for f in vendor/mbedtls/library/*.c; do
        "$CC" -arch armv7 -isysroot "$SDK_ABS" -miphoneos-version-min=8.0 -Os -w \
              -Ivendor/mbedtls/include -c "$f" -o "vendor/obj/$(basename "$f" .c).o"
    done
    ar -rcs vendor/libmbedtls-armv7.a vendor/obj/*.o
    rm -rf vendor/obj
fi

# ----------------------------------------------------------------- CA bundle
if [ ! -f vendor/cacert.pem ]; then
    echo "==> fetching CA bundle"
    curl -sSL -o vendor/cacert.pem https://curl.se/ca/cacert.pem
fi

echo "==> dependencies ready"
