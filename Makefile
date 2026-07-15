# pass — CLI-first build. Requires: xcodegen, xcodebuild (Xcode 26), tmux.
APP_NAME := Pass
PROJECT  := $(APP_NAME).xcodeproj
SCHEME   := Pass
CONFIG   := Debug
DERIVED  := .build
APP_PATH := $(DERIVED)/Build/Products/$(CONFIG)/$(APP_NAME).app
BIN      := $(APP_PATH)/Contents/MacOS/$(APP_NAME)
BUNDLE_ID := dev.lightsoft.pass

# Pipe through xcbeautify if available, else raw.
BEAUTIFY := $(shell command -v xcbeautify >/dev/null 2>&1 && echo "| xcbeautify" || echo "")

.PHONY: gen build run stop test logs clean regen open install

gen:
	xcodegen generate

$(PROJECT): project.yml
	xcodegen generate

build: $(PROJECT)
	set -o pipefail; xcodebuild \
		-project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) \
		build $(BEAUTIFY)

# Run the built binary directly so stdout/stderr stay in the terminal (agent-friendly).
run: stop build
	@echo "launching $(BIN)"
	$(BIN)

# Sync the fresh build into /Applications — the copy Spotlight/Dock launches. Without this,
# a stale /Applications bundle shadows the dev build (old UI, sessions "missing").
install: build
	rsync -a --delete "$(APP_PATH)/" "/Applications/$(APP_NAME).app/"

# Launch detached via the bundle (like Finder would). Installs to /Applications first so the
# running app and the one Spotlight launches are always the SAME build.
open: stop install
	open "/Applications/$(APP_NAME).app"

stop:
	@pkill -x $(APP_NAME) 2>/dev/null || true

test: $(PROJECT)
	set -o pipefail; xcodebuild \
		-project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) \
		test $(BEAUTIFY)

logs:
	log stream --predicate 'subsystem == "$(BUNDLE_ID)"' --level debug

regen: clean gen

clean:
	rm -rf $(PROJECT) $(DERIVED)
