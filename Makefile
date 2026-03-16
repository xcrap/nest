SHELL := /bin/zsh

APP_VERSION := $(shell node -p "require('./package.json').version")
BUILD_ID := $(shell date -u +%Y%m%d%H%M%S)-$(shell git rev-parse --short=12 HEAD 2>/dev/null || echo nogit)
GO_LDFLAGS := -X github.com/xcrap/nest/daemon/internal/buildinfo.Version=$(APP_VERSION) -X github.com/xcrap/nest/daemon/internal/buildinfo.BuildID=$(BUILD_ID)

.PHONY: bootstrap dev run-daemon build test doctor package release desktop-dev services-start services-stop

bootstrap:
	./scripts/bootstrap-macos.sh

dev:
	go run -ldflags "$(GO_LDFLAGS)" ./daemon/cmd/nestd &
	npm --workspace desktop run dev

run-daemon:
	go run -ldflags "$(GO_LDFLAGS)" ./daemon/cmd/nestd

desktop-dev:
	npm --workspace desktop run dev

build:
	go build -ldflags "$(GO_LDFLAGS)" -o ./bin/nestd ./daemon/cmd/nestd
	go build -ldflags "$(GO_LDFLAGS)" -o ./bin/nestcli ./daemon/cmd/nestcli
	go build -o ./bin/nesthelper ./helper/cmd/nesthelper
	npm --workspace desktop run build

test:
	go test ./...

doctor:
	go run ./daemon/cmd/nestcli doctor

services-start:
	go run ./daemon/cmd/nestcli services start

services-stop:
	go run ./daemon/cmd/nestcli services stop

package:
	go build -ldflags "$(GO_LDFLAGS)" -o ./bin/nestd ./daemon/cmd/nestd
	go build -ldflags "$(GO_LDFLAGS)" -o ./bin/nestcli ./daemon/cmd/nestcli
	go build -o ./bin/nesthelper ./helper/cmd/nesthelper
	npm --workspace desktop run package
	rm -rf ./Nest.app
	cp -R ./desktop/release/mac-arm64/Nest.app ./Nest.app
	rm -rf ./desktop/dist/mac-arm64/Nest.app

release:
	go build -ldflags "$(GO_LDFLAGS)" -o ./bin/nestd ./daemon/cmd/nestd
	go build -ldflags "$(GO_LDFLAGS)" -o ./bin/nestcli ./daemon/cmd/nestcli
	go build -o ./bin/nesthelper ./helper/cmd/nesthelper
	npm --workspace desktop run release

bump:
ifndef VERSION
	$(error Usage: make bump VERSION=x.y.z)
endif
	node -e ' \
		const fs = require("fs"); \
		for (const f of ["package.json", "desktop/package.json"]) { \
			const pkg = JSON.parse(fs.readFileSync(f, "utf8")); \
			pkg.version = "$(VERSION)"; \
			fs.writeFileSync(f, JSON.stringify(pkg, null, 2) + "\n"); \
		} \
		console.log("Bumped to $(VERSION)"); \
	'
