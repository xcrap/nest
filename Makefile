SHELL := /bin/zsh

APP_NAME := Nest
DEV_BUNDLE_ID := dev.nest.app
RELEASE_BUNDLE_ID := app.nest
BUILD_DIR := .build/release
DEBUG_BUILD_DIR := .build/arm64-apple-macosx/debug
DIST_DIR := dist
APP_BUNDLE := $(DIST_DIR)/$(APP_NAME).app
DEV_APP_BUNDLE := .build/$(APP_NAME)-dev.app
VERSION := $(shell cat version.txt 2>/dev/null || echo 0.0.0)
BUILD_ID := $(shell date -u +%Y%m%d%H%M%S)-$(shell git rev-parse --short=12 HEAD 2>/dev/null || echo nogit)
DEV_PROCESS_PATTERN := '(^|/)\\.build/arm64-apple-macosx/debug/Nest$$|(^|/)\\.build/Nest-dev\\.app/Contents/MacOS/Nest$$'

.PHONY: dev build test run package dmg clean bump

build:
	swift build -c release

test:
	swift build --target NestTests -c debug
	swift run NestTests

dev:
	swift build -c debug
	-pkill -f $(DEV_PROCESS_PATTERN)
	rm -rf $(DEV_APP_BUNDLE)
	mkdir -p $(DEV_APP_BUNDLE)/Contents/MacOS
	mkdir -p $(DEV_APP_BUNDLE)/Contents/Resources
	mkdir -p $(DEV_APP_BUNDLE)/Contents/Frameworks
	cp $(DEBUG_BUILD_DIR)/Nest $(DEV_APP_BUNDLE)/Contents/MacOS/Nest
	cp scripts/AppIcon.icns $(DEV_APP_BUNDLE)/Contents/Resources/AppIcon.icns
	cp -R $(DEBUG_BUILD_DIR)/Sparkle.framework $(DEV_APP_BUNDLE)/Contents/Frameworks/
	install_name_tool -add_rpath @executable_path/../Frameworks $(DEV_APP_BUNDLE)/Contents/MacOS/Nest 2>/dev/null || true
	sed 's/$${VERSION}/$(VERSION)/g; s/$${BUILD_ID}/$(BUILD_ID)/g; s/$${BUNDLE_ID}/$(DEV_BUNDLE_ID)/g' \
		scripts/Info.plist > $(DEV_APP_BUNDLE)/Contents/Info.plist
	codesign --force --deep --sign - --timestamp=none $(DEV_APP_BUNDLE)
	open $(DEV_APP_BUNDLE)

run: dev

package: build
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/Nest $(APP_BUNDLE)/Contents/MacOS/Nest
	cp scripts/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	mkdir -p $(APP_BUNDLE)/Contents/Frameworks
	cp -R .build/arm64-apple-macosx/release/Sparkle.framework $(APP_BUNDLE)/Contents/Frameworks/
	install_name_tool -add_rpath @executable_path/../Frameworks $(APP_BUNDLE)/Contents/MacOS/Nest 2>/dev/null || true
	sed 's/$${VERSION}/$(VERSION)/g; s/$${BUILD_ID}/$(BUILD_ID)/g; s/$${BUNDLE_ID}/$(RELEASE_BUNDLE_ID)/g' \
		scripts/Info.plist > $(APP_BUNDLE)/Contents/Info.plist
	codesign --force --deep --sign - --timestamp=none $(APP_BUNDLE)
	@echo "$(APP_BUNDLE) created (version $(VERSION), build $(BUILD_ID))"

dmg: package
	rm -f $(DIST_DIR)/$(APP_NAME)-$(VERSION).dmg
	mkdir -p .dmg-staging
	cp -R $(APP_BUNDLE) .dmg-staging/
	ln -sf /Applications .dmg-staging/Applications
	hdiutil create -volname "$(APP_NAME)" -srcfolder .dmg-staging -ov -format UDZO $(DIST_DIR)/$(APP_NAME)-$(VERSION).dmg
	rm -rf .dmg-staging
	@echo "$(DIST_DIR)/$(APP_NAME)-$(VERSION).dmg created"

clean:
	swift package clean
	rm -rf $(DIST_DIR) .dmg-staging

bump:
ifndef VERSION_NEW
	$(error Usage: make bump VERSION_NEW=x.y.z)
endif
	echo "$(VERSION_NEW)" > version.txt
	git add version.txt
	@echo "Version updated to $(VERSION_NEW). Commit and tag manually:"
	@echo "  git commit -m 'Bump version to $(VERSION_NEW)'"
	@echo "  git tag v$(VERSION_NEW)"
