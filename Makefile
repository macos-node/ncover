# n.cover (macOS). SwiftPM builds the binary; this assembles the .app around it.
#
# No .xcodeproj on purpose: a generated pbxproj is neither readable nor
# diffable, and the rest of the author's suite is Makefile-driven anyway.

APP      = n.cover.app
ICNS     = Resources/ncover.icns
ICONSET  = .build/ncover.iconset
CONFIG   = release
BUILDDIR = .build/$(CONFIG)
PREFIX   = $(HOME)/Applications

# Read back from the bundle's own plist, so the disk image can never claim a
# version the app inside it does not.
VERSION  = $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG      = n.cover-$(VERSION)-macos-arm64.dmg
DMGROOT  = .build/dmg

.PHONY: all app dmg icon version run test clean install uninstall help

all: app

## Regenerate ncover.icns from icon.svg (run after an icon change)
##
## The master is the Figma export shared with the GTK sibling: 1024 canvas with
## the art in an 824 square, which is Apple's icon grid. macOS therefore wants
## it UNCROPPED — the Linux build crops that margin away to fill 89% of the
## tile, and doing the same here would make the icon oversized next to every
## other app in the Dock.
icon: icon.svg
	@rm -rf "$(ICONSET)"
	@mkdir -p "$(ICONSET)"
	@for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x \
	             128:128x128 256:128x128@2x 256:256x256 512:256x256@2x \
	             512:512x512 1024:512x512@2x; do \
	  px=$${spec%%:*}; name=$${spec##*:}; \
	  rsvg-convert -w $$px -h $$px icon.svg -o "$(ICONSET)/icon_$$name.png" || exit 1; \
	done
	@iconutil -c icns "$(ICONSET)" -o "$(ICNS)"
	@rm -rf "$(ICONSET)"
	@echo "regenerated $(ICNS) from icon.svg"

## Build the .app bundle
app: $(BUILDDIR)/ncover
	@rm -rf "$(APP)"
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	@cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	@cp "$(BUILDDIR)/ncover" "$(APP)/Contents/MacOS/ncover"
	@# The .icns is committed, so a build needs no rsvg-convert. `make icon`
	@# regenerates it when the art changes.
	@if [ -f "$(ICNS)" ]; then cp "$(ICNS)" "$(APP)/Contents/Resources/ncover.icns"; \
	 else echo "warning: no $(ICNS) — run 'make icon'"; fi
	@# Ad-hoc signature. Unsigned, WKWebView's helper processes are refused on
	@# recent macOS and every SVG silently fails to render.
	@codesign --force --sign - "$(APP)" >/dev/null 2>&1 || \
	  echo "warning: could not ad-hoc sign; SVG rendering may fail"
	@echo "built $(APP)"

## Build a disk image for Apple silicon: the app plus a drop target
##
## `ditto`, not `cp -R`: it is the one copy that is documented to carry a
## bundle's signature and extended attributes across intact, and an app whose
## ad-hoc signature did not survive the copy renders every SVG blank — silently.
##
## The image is NOT notarized and the app inside it is ad-hoc signed, so
## Gatekeeper will refuse it on another machine until the quarantine flag is
## cleared. That is a property of having no Developer ID, not of the image, and
## signing the .dmg itself would not change it.
dmg: app
	@rm -rf "$(DMGROOT)" "$(DMG)"
	@mkdir -p "$(DMGROOT)"
	@ditto "$(APP)" "$(DMGROOT)/$(APP)"
	@# The customary drop target. A symlink rather than a copy, obviously.
	@ln -s /Applications "$(DMGROOT)/Applications"
	@hdiutil create -quiet -volname "n.cover $(VERSION)" -srcfolder "$(DMGROOT)" \
	  -ov -format UDZO -fs HFS+ "$(DMG)"
	@rm -rf "$(DMGROOT)"
	@# Verify what we are about to hand someone, rather than trusting the
	@# exit code: mount it read-only and check the signature on the copy that
	@# is actually inside the image.
	@mnt=$$(mktemp -d /tmp/ncover-dmg.XXXXXX); \
	 hdiutil attach -quiet -nobrowse -readonly -mountpoint "$$mnt" "$(DMG)" && \
	 codesign --verify "$$mnt/$(APP)" && \
	 /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
	   "$$mnt/$(APP)/Contents/Info.plist" >/dev/null && \
	 hdiutil detach -quiet "$$mnt" && rmdir "$$mnt" && \
	 echo "built $(DMG) — app inside verifies" || \
	 { hdiutil detach -quiet "$$mnt" 2>/dev/null; rmdir "$$mnt" 2>/dev/null; \
	   echo "FAILED: the app inside $(DMG) did not verify"; exit 1; }

# PHONY prerequisite: swift build does its own up-to-date check, so running it
# every time costs nothing — whereas a file rule would let `make app` ship a
# stale binary, which is exactly the trap the GTK Makefile documents.
.PHONY: $(BUILDDIR)/ncover
$(BUILDDIR)/ncover:
	swift build -c $(CONFIG)

## Bump the version. Two places, both in Info.plist, and it prints them.
##
## CFBundleVersion is a build number in Apple's model; keeping it equal to the
## marketing version is a deliberate simplification for a tool released from
## tags — the tag is the only identity that matters here.
version:
	@test -n "$(V)" || { echo "usage: make version V=x.y.z"; exit 1; }
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(V)" Resources/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(V)" Resources/Info.plist
	@echo "set $(V) in Resources/Info.plist:"
	@echo "  CFBundleShortVersionString"
	@echo "  CFBundleVersion"
	@echo "now: update CHANGELOG.md, commit, then 'git tag v$(V) && git push --tags'"

## Build and launch
run: app
	open "$(APP)"

## Run the ported rule tests
test:
	swift test

## Install to ~/Applications
install: app
	@mkdir -p "$(PREFIX)"
	@rm -rf "$(PREFIX)/$(APP)"
	@cp -R "$(APP)" "$(PREFIX)/$(APP)"
	@echo "installed $(PREFIX)/$(APP)"

uninstall:
	@rm -rf "$(PREFIX)/$(APP)"

clean:
	swift package clean
	@rm -rf "$(APP)" "$(DMGROOT)" n.cover-*.dmg

help:
	@echo "Available make targets:"
	@echo "  app        - Build n.cover.app (default)"
	@echo "  dmg        - Build a disk image for Apple silicon"
	@echo "  icon       - Regenerate ncover.icns from icon.svg (needs rsvg-convert)"
	@echo "  version    - Bump the version: make version V=x.y.z"
	@echo "  run        - Build and launch"
	@echo "  test       - Run the ported rule tests"
	@echo "  install    - Copy to ~/Applications"
	@echo "  uninstall  - Remove from ~/Applications"
	@echo "  clean      - Remove build products"
