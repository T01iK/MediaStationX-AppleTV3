# Media Station X appliance for Apple TV 3 (armv7, Apple TV Software 7.9 / iOS 8.4.4)

# Populated by scripts/fetch-deps.sh; override to point at another copy.
SDK      ?= $(CURDIR)/sdk/iPhoneOS9.3.sdk
MBEDTLS  := $(CURDIR)/vendor/libmbedtls-armv7.a
CABUNDLE := $(CURDIR)/vendor/cacert.pem

NAME     := MediaStationX
BUNDLE   := build/$(NAME).frappliance
CC       := $(shell xcrun -f clang)

SOURCES  := src/MSXAppliance.m src/MSXLog.m src/MSXHTTPS.m src/MSXURLProtocol.m
RESOURCES := res/Info.plist res/AppIcon.png res/AppIcon@1080.png \
             res/English.lproj/InfoPlist.strings

CFLAGS   := -arch armv7 -isysroot $(SDK) -miphoneos-version-min=8.0 \
            -fno-objc-arc -Wall -Wno-deprecated-declarations \
            -Os -fvisibility=hidden -Isrc -Ivendor/mbedtls/include
LDFLAGS  := -arch armv7 -isysroot $(SDK) -miphoneos-version-min=8.0 -bundle \
            -framework UIKit -framework Foundation -framework CoreGraphics \
            -framework QuartzCore -lobjc -Wl,-undefined,dynamic_lookup

all: $(BUNDLE)/$(NAME)

$(SDK) $(MBEDTLS) $(CABUNDLE):
	./scripts/fetch-deps.sh

$(BUNDLE)/$(NAME): $(SDK) $(MBEDTLS) $(CABUNDLE) $(SOURCES) $(RESOURCES)
	@mkdir -p $(BUNDLE)/English.lproj
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SOURCES) $(MBEDTLS)
	cp res/Info.plist $(BUNDLE)/Info.plist
	cp res/AppIcon.png res/AppIcon@1080.png $(BUNDLE)/
	cp res/AppIcon.png $(BUNDLE)/TopRowIcon.png
	cp res/English.lproj/InfoPlist.strings $(BUNDLE)/English.lproj/
	cp $(CABUNDLE) $(BUNDLE)/cacert.pem
	@file $@

clean:
	rm -rf build

# Removes the fetched SDK, mbedTLS and CA bundle as well.
distclean: clean
	rm -rf sdk vendor

.PHONY: all clean distclean
