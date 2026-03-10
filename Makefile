SHELL := /bin/zsh

.PHONY: bootstrap dev run-daemon build test doctor package release desktop-dev services-start services-stop

bootstrap:
	./scripts/bootstrap-macos.sh

dev:
	go run ./daemon/cmd/nestd &
	npm --workspace desktop run dev

run-daemon:
	go run ./daemon/cmd/nestd

desktop-dev:
	npm --workspace desktop run dev

build:
	go build -o ./bin/nestd ./daemon/cmd/nestd
	go build -o ./bin/nestctl ./daemon/cmd/nestctl
	go build -o ./bin/nesthelper ./helper/cmd/nesthelper
	npm --workspace desktop run build

test:
	go test ./...

doctor:
	go run ./daemon/cmd/nestctl doctor

services-start:
	go run ./daemon/cmd/nestctl services start

services-stop:
	go run ./daemon/cmd/nestctl services stop

package:
	go build -o ./bin/nestd ./daemon/cmd/nestd
	go build -o ./bin/nestctl ./daemon/cmd/nestctl
	go build -o ./bin/nesthelper ./helper/cmd/nesthelper
	npm --workspace desktop run package
	rm -rf ./Nest.app
	cp -R ./desktop/release/mac-arm64/Nest.app ./Nest.app
	rm -rf ./desktop/dist/mac-arm64/Nest.app

release:
	go build -o ./bin/nestd ./daemon/cmd/nestd
	go build -o ./bin/nestctl ./daemon/cmd/nestctl
	go build -o ./bin/nesthelper ./helper/cmd/nesthelper
	npm --workspace desktop run release
