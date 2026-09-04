APP := Undertone
BUNDLE := build/$(APP).app
BIN := $(BUNDLE)/Contents/MacOS/$(APP)

.PHONY: build run dev install uninstall test clean doctor icon

## build: compile (release) and assemble build/Undertone.app
build:
	@./scripts/bundle.sh

## run: build, then launch the app in the background
run: build
	@pkill -x $(APP) 2>/dev/null || true
	@open $(BUNDLE)

## dev: build, then run in the foreground with logs in this terminal (Ctrl-C to stop)
dev: build
	@pkill -x $(APP) 2>/dev/null || true
	@$(BIN)

## install: copy to /Applications and launch it from there
install: build
	@pkill -x $(APP) 2>/dev/null || true
	@rm -rf /Applications/$(APP).app
	@cp -R $(BUNDLE) /Applications/$(APP).app
	@open /Applications/$(APP).app
	@echo "✓ installed /Applications/$(APP).app"

## uninstall: quit and remove /Applications/Undertone.app (settings stay in ~/Library/Preferences)
uninstall:
	@pkill -x $(APP) 2>/dev/null || true
	@rm -rf /Applications/$(APP).app
	@echo "✓ removed /Applications/$(APP).app"

## test: run the UndertoneCore unit tests (Swift Testing via a self-test executable)
test:
	@swift run UndertoneSelfTest

## clean: remove build artifacts
clean:
	@rm -rf .build build

## doctor: read-only check of yt-dlp, deno and the build (changes nothing)
doctor:
	@./scripts/doctor.sh

## icon: regenerate Resources/AppIcon.icns from scripts/make-icon.swift
icon:
	@swift scripts/make-icon.swift Resources/AppIcon.icns

help:
	@grep -E '^## ' Makefile | sed 's/^## /  make /'
