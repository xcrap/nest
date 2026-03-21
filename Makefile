SHELL := /bin/zsh

APP_NAME := Nest
BUNDLE_ID := dev.nest.app
BUILD_DIR := .build/release
APP_BUNDLE := $(APP_NAME).app
VERSION := $(shell cat version.txt 2>/dev/null || echo 0.0.0)
BUILD_ID := $(shell date -u +%Y%m%d%H%M%S)-$(shell git rev-parse --short=12 HEAD 2>/dev/null || echo nogit)

.PHONY: build test run package release clean bump

build:
	swift build -c release

test:
	swift build --target NestTests -c debug
	swift run NestTests

run:
	swift run Nest

package: build
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/Nest $(APP_BUNDLE)/Contents/MacOS/Nest
	sed 's/$${VERSION}/$(VERSION)/g; s/$${BUILD_ID}/$(BUILD_ID)/g; s/$${BUNDLE_ID}/$(BUNDLE_ID)/g' \
		scripts/Info.plist > $(APP_BUNDLE)/Contents/Info.plist
	@echo "$(APP_BUNDLE) created (version $(VERSION), build $(BUILD_ID))"

release: package
	codesign --force --deep --options runtime \
		--sign "$(CSC_NAME)" \
		--entitlements scripts/entitlements.plist \
		$(APP_BUNDLE)
	ditto -c -k --keepParent $(APP_BUNDLE) $(APP_NAME)-$(VERSION).zip
	xcrun notarytool submit $(APP_NAME)-$(VERSION).zip \
		--apple-id "$(APPLE_ID)" \
		--team-id "$(APPLE_TEAM_ID)" \
		--password "$(APPLE_APP_SPECIFIC_PASSWORD)" \
		--wait
	xcrun stapler staple $(APP_BUNDLE)
	rm -f $(APP_NAME)-$(VERSION).zip
	hdiutil create -volname $(APP_NAME) -srcfolder $(APP_BUNDLE) -ov -format UDZO $(APP_NAME)-$(VERSION).dmg
	ditto -c -k --keepParent $(APP_BUNDLE) $(APP_NAME)-$(VERSION).zip
	@echo "Release artifacts: $(APP_NAME)-$(VERSION).dmg, $(APP_NAME)-$(VERSION).zip"

clean:
	swift package clean
	rm -rf $(APP_BUNDLE) *.dmg *.zip

bump:
ifndef VERSION_NEW
	$(error Usage: make bump VERSION_NEW=x.y.z)
endif
	echo "$(VERSION_NEW)" > version.txt
	git add version.txt
	@echo "Version updated to $(VERSION_NEW). Commit and tag manually:"
	@echo "  git commit -m 'Bump version to $(VERSION_NEW)'"
	@echo "  git tag v$(VERSION_NEW)"
