SHELL := /bin/zsh

APP_NAME := Nest
DEV_BUNDLE_ID := dev.nest.app
RELEASE_BUNDLE_ID := app.nest
# Ask SwiftPM where products land: the layout differs between toolchains
# (.build/<triple>/release vs .build/out/Products/Release). Each is computed on first use only.
BUILD_DIR = $(eval BUILD_DIR := $$(shell swift build -c release --show-bin-path))$(BUILD_DIR)
DEBUG_BUILD_DIR = $(eval DEBUG_BUILD_DIR := $$(shell swift build -c debug --show-bin-path))$(DEBUG_BUILD_DIR)
DIST_DIR := dist
APP_BUNDLE := $(DIST_DIR)/$(APP_NAME).app
DEV_APP_BUNDLE := .build/$(APP_NAME)-dev.app
VERSION := $(shell cat version.txt 2>/dev/null || echo 0.0.0)
BUILD_ID := $(shell date -u +%Y%m%d%H%M%S)-$(shell git rev-parse --short=12 HEAD 2>/dev/null || echo nogit)
APP_RPATH := @executable_path/../Frameworks
# Adds APP_RPATH to binary $(1) unless it is already there. Any install_name_tool error fails the build.
ensure_app_rpath = if otool -l '$(1)' | awk '/cmd LC_RPATH/ { rpath = 1; next } rpath && $$1 == "path" { print $$2; rpath = 0 }' | grep -qxF '$(APP_RPATH)'; then echo 'rpath $(APP_RPATH) already in $(1)'; else echo 'Adding rpath $(APP_RPATH) to $(1)'; install_name_tool -add_rpath '$(APP_RPATH)' '$(1)'; fi
DEV_PROCESS_PATTERN := '$(CURDIR)/[.]build/(arm64-apple-macosx/debug/Nest|Nest-dev[.]app/Contents/MacOS/Nest)([[:space:]]|$$)'

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
	@$(call ensure_app_rpath,$(DEV_APP_BUNDLE)/Contents/MacOS/Nest)
	sed 's/$${VERSION}/$(VERSION)/g; s/$${BUILD_ID}/$(BUILD_ID)/g; s/$${BUNDLE_ID}/$(DEV_BUNDLE_ID)/g' \
		scripts/Info.plist > $(DEV_APP_BUNDLE)/Contents/Info.plist
	codesign --force --deep --sign - --timestamp=none $(DEV_APP_BUNDLE)
	open $(DEV_APP_BUNDLE) --args $(DEV_ARGS)

run: dev

package: build
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	mkdir -p $(APP_BUNDLE)/Contents/Library/LaunchDaemons
	cp $(BUILD_DIR)/Nest $(APP_BUNDLE)/Contents/MacOS/Nest
	cp $(BUILD_DIR)/NestPFHelper $(APP_BUNDLE)/Contents/MacOS/NestPFHelper
	cp $(BUILD_DIR)/nestctl $(DIST_DIR)/nestctl
	cp scripts/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	cp scripts/app.nest.pfhelper.plist $(APP_BUNDLE)/Contents/Library/LaunchDaemons/app.nest.pfhelper.plist
	mkdir -p $(APP_BUNDLE)/Contents/Frameworks
	cp -R $(BUILD_DIR)/Sparkle.framework $(APP_BUNDLE)/Contents/Frameworks/
	@$(call ensure_app_rpath,$(APP_BUNDLE)/Contents/MacOS/Nest)
	sed 's/$${VERSION}/$(VERSION)/g; s/$${BUILD_ID}/$(BUILD_ID)/g; s/$${BUNDLE_ID}/$(RELEASE_BUNDLE_ID)/g' \
		scripts/Info.plist > $(APP_BUNDLE)/Contents/Info.plist
	codesign --force --deep --sign - --timestamp=none $(APP_BUNDLE)
	codesign --force --sign - --timestamp=none $(DIST_DIR)/nestctl
	@echo "$(APP_BUNDLE) created (version $(VERSION), build $(BUILD_ID))"

dmg: package
	rm -f $(DIST_DIR)/$(APP_NAME)-$(VERSION).dmg
	mkdir -p .dmg-staging
	cp -R $(APP_BUNDLE) .dmg-staging/
	cp $(DIST_DIR)/nestctl .dmg-staging/
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
	@echo "Version updated to $(VERSION_NEW). Commit, tag, and push for release:"
	@echo "  git commit -m 'Bump version to $(VERSION_NEW)'"
	@echo "  git tag v$(VERSION_NEW)"
	@echo "  git push origin HEAD"
	@echo "  git push origin v$(VERSION_NEW)"
