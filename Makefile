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

.PHONY: gen build run stop test logs clean regen open

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

# Launch detached via the bundle (like Finder would) — for notification/GUI-env testing.
open: stop build
	open "$(APP_PATH)"

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
