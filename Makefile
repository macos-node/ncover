# n.cover (macOS). SwiftPM builds the binary; this assembles the .app around it.
#
# No .xcodeproj on purpose: a generated pbxproj is neither readable nor
# diffable, and the rest of the author's suite is Makefile-driven anyway.

APP      = n.cover.app
CONFIG   = release
BUILDDIR = .build/$(CONFIG)
PREFIX   = $(HOME)/Applications

.PHONY: all app run test clean install uninstall help

all: app

## Build the .app bundle
app: $(BUILDDIR)/ncover
	@rm -rf "$(APP)"
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	@cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	@cp "$(BUILDDIR)/ncover" "$(APP)/Contents/MacOS/ncover"
	@# Ad-hoc signature. Unsigned, WKWebView's helper processes are refused on
	@# recent macOS and every SVG silently fails to render.
	@codesign --force --sign - "$(APP)" >/dev/null 2>&1 || \
	  echo "warning: could not ad-hoc sign; SVG rendering may fail"
	@echo "built $(APP)"

# PHONY prerequisite: swift build does its own up-to-date check, so running it
# every time costs nothing — whereas a file rule would let `make app` ship a
# stale binary, which is exactly the trap the GTK Makefile documents.
.PHONY: $(BUILDDIR)/ncover
$(BUILDDIR)/ncover:
	swift build -c $(CONFIG)

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
	@rm -rf "$(APP)"

help:
	@echo "Available make targets:"
	@echo "  app        - Build n.cover.app (default)"
	@echo "  run        - Build and launch"
	@echo "  test       - Run the ported rule tests"
	@echo "  install    - Copy to ~/Applications"
	@echo "  uninstall  - Remove from ~/Applications"
	@echo "  clean      - Remove build products"
