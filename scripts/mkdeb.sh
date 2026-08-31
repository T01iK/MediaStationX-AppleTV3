#!/bin/sh
# Builds a Cydia-installable .deb for the Media Station X appliance.
set -e
VERSION="${1:-1.0-1}"
ID=com.apple.frontrow.appliance.mediastationx
STAGE=build/deb
DEBFILE="build/de.benzac.msx-atv3_${VERSION}_iphoneos-arm.deb"

make

rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE/Applications"
cp -R build/MediaStationX.frappliance "$STAGE/Applications/"

cat > "$STAGE/DEBIAN/control" <<CONTROL
Package: de.benzac.msx-atv3
Name: Media Station X
Version: ${VERSION}
Architecture: iphoneos-arm
Description: Media Station X as a standalone appliance for the Apple TV 3
Homepage: https://msx.benzac.de/
Maintainer: Anatoliy Shulika
Author: Benjamin Zachey (Media Station X)
Section: Multimedia
Depends: firmware (>= 7.0)
CONTROL

cat > "$STAGE/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
ID=com.apple.frontrow.appliance.mediastationx
APP=/Applications/MediaStationX.frappliance

chown -R mobile:mobile "$APP"

# Menu tile artwork, in the places the AppleTV UI looks for it.
cp "$APP/AppIcon.png"       "/Applications/AppleTV.app/$ID@720p.png"
cp "$APP/AppIcon@1080.png"  "/Applications/AppleTV.app/$ID@1080.png"
mkdir -p /private/var/mobile/Library/Caches/AppleTV/MainMenu
cp "$APP/AppIcon.png"       "/private/var/mobile/Library/Caches/AppleTV/MainMenu/$ID@720.png"

# Register the appliance with the AppleTV UI.
mkdir -p /Applications/AppleTV.app/Appliances
ln -sfn "$APP" /Applications/AppleTV.app/Appliances/MediaStationX.frappliance

# Start URL, editable afterwards to point at a self-hosted instance.
PREFS=/var/mobile/Library/Preferences/MediaStationX
mkdir -p "$PREFS"
[ -f "$PREFS/url.txt" ] || echo "http://msx.benzac.de/" > "$PREFS/url.txt"
chown -R mobile:mobile "$PREFS"

# The AppleTV UI ignores SIGTERM while an appliance is on screen, so killall
# alone can silently leave the old bundle running.  Escalate and verify.
restart_appletv() {
    old=$(ps ax | grep '[A]ppleTV.app/AppleTV' | awk '{print $1}')
    killall AppleTV 2>/dev/null
    n=0
    while [ $n -lt 5 ]; do
        sleep 2
        new=$(ps ax | grep '[A]ppleTV.app/AppleTV' | awk '{print $1}')
        [ -n "$new" ] && [ "$new" != "$old" ] && { echo "AppleTV restarted ($old -> $new)"; return 0; }
        [ -n "$old" ] && kill -9 "$old" 2>/dev/null
        n=$((n + 1))
    done
    echo "warning: could not confirm AppleTV restart" >&2
}
restart_appletv
exit 0
POSTINST

cat > "$STAGE/DEBIAN/prerm" <<'PRERM'
#!/bin/sh
ID=com.apple.frontrow.appliance.mediastationx
rm -f "/Applications/AppleTV.app/Appliances/MediaStationX.frappliance"
rm -f "/Applications/AppleTV.app/$ID@720p.png" "/Applications/AppleTV.app/$ID@1080.png"
rm -f "/private/var/mobile/Library/Caches/AppleTV/MainMenu/$ID@720.png"
# The AppleTV UI ignores SIGTERM while an appliance is on screen, so killall
# alone can silently leave the old bundle running.  Escalate and verify.
restart_appletv() {
    old=$(ps ax | grep '[A]ppleTV.app/AppleTV' | awk '{print $1}')
    killall AppleTV 2>/dev/null
    n=0
    while [ $n -lt 5 ]; do
        sleep 2
        new=$(ps ax | grep '[A]ppleTV.app/AppleTV' | awk '{print $1}')
        [ -n "$new" ] && [ "$new" != "$old" ] && { echo "AppleTV restarted ($old -> $new)"; return 0; }
        [ -n "$old" ] && kill -9 "$old" 2>/dev/null
        n=$((n + 1))
    done
    echo "warning: could not confirm AppleTV restart" >&2
}
restart_appletv
exit 0
PRERM

chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm"

# dpkg-deb is not available on macOS, so assemble the .deb ourselves.
WORK=$(mktemp -d)
printf '2.0\n' > "$WORK/debian-binary"
# gzip -n keeps the timestamp out of the header, so the same tree always
# produces the same .deb.
TARFLAGS="--no-mac-metadata --no-xattrs --numeric-owner --owner=0 --group=0"
tar $TARFLAGS -cf - -C "$STAGE/DEBIAN" .            | gzip -n9 > "$WORK/control.tar.gz"
tar $TARFLAGS -cf - -C "$STAGE" ./Applications      | gzip -n9 > "$WORK/data.tar.gz"
rm -f "$DEBFILE"
python3 scripts/mkar.py "$DEBFILE" \
    "$WORK/debian-binary" "$WORK/control.tar.gz" "$WORK/data.tar.gz"
rm -rf "$WORK"

echo "built $DEBFILE"
ls -la "$DEBFILE"
