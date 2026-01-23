.PHONY: build run clean release sign notarize dmg all open-app help

# Development
build:
	swift build

run: build
	.build/debug/ClaudeCodeUsage

clean:
	rm -rf .build release

# Release
release:
	./scripts/build.sh

sign:
	./scripts/build.sh --sign

notarize:
	./scripts/build.sh --notarize

dmg:
	./scripts/build.sh --sign --dmg

# Full distribution build (sign + notarize + dmg)
all:
	./scripts/build.sh --all

# Open the built app
open-app:
	open release/ClaudeCodeUsage.app

# Help
help:
	@echo "Available targets:"
	@echo "  make build     - Build debug version"
	@echo "  make run       - Build and run debug version"
	@echo "  make clean     - Remove build artifacts"
	@echo "  make release   - Build release .app bundle (unsigned)"
	@echo "  make sign      - Build and sign .app bundle"
	@echo "  make notarize  - Build, sign, and notarize .app bundle"
	@echo "  make dmg       - Build signed .app and create DMG"
	@echo "  make all       - Full distribution build (sign + notarize + dmg)"
	@echo ""
	@echo "For notarization, set these environment variables:"
	@echo "  export APPLE_ID='your@email.com'"
	@echo "  export APPLE_TEAM_ID='YOURTEAMID'"
	@echo "  export APPLE_APP_PASSWORD='xxxx-xxxx-xxxx-xxxx'"
