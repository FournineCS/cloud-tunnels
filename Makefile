APP_NAME = CloudTunnels
CLI_NAME = ctun
HELPER_NAME = CloudTunnelsProxyHelper
HELPER_BUNDLE_ID = com.fourninecloud.cloud-tunnels.proxy-helper
APP_BUNDLE_ID = com.fourninecloud.cloud-tunnels
BIN = .build/apple/Products/Release/$(APP_NAME)
CLI_BIN = .build/apple/Products/Release/$(CLI_NAME)
HELPER_BIN = .build/apple/Products/Release/$(HELPER_NAME)
APP_BUNDLE = build/$(APP_NAME).app
CONTENTS = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS)/MacOS
RESOURCES_DIR = $(CONTENTS)/Resources
LAUNCHDAEMONS_DIR = $(CONTENTS)/Library/LaunchDaemons
CLI_INSTALL_PATH = /usr/local/bin/$(CLI_NAME)

# Bundled Caddy reverse proxy. The helper spawns this binary as a
# child process to handle TLS termination and reverse-proxying for
# AWS-SSM-tunneled HTTPS routes. Caddy distributes per-arch macOS
# binaries (no universal release), so we download both and `lipo`
# them into a single fat binary at vendor/caddy. Git-ignored.
#
# Bundling is best-effort: if the download fails (network down,
# mirror unreachable), `app` still builds and CaddyManager falls
# back at runtime to /opt/homebrew/bin/caddy or /usr/local/bin/caddy.
CADDY_VERSION = 2.10.2
CADDY_VENDOR_DIR = vendor
CADDY_VENDOR_BIN = $(CADDY_VENDOR_DIR)/caddy
CADDY_URL_ARM64 = https://github.com/caddyserver/caddy/releases/download/v$(CADDY_VERSION)/caddy_$(CADDY_VERSION)_mac_arm64.tar.gz
CADDY_URL_AMD64 = https://github.com/caddyserver/caddy/releases/download/v$(CADDY_VERSION)/caddy_$(CADDY_VERSION)_mac_amd64.tar.gz

# Code-signing identity. Default is ad-hoc signing (`-`), which works for
# personal/dev use. Override with SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
# to produce a distributable signed bundle.
SIGN_IDENTITY ?= -
APP_ENTITLEMENTS = Resources/CloudTunnels.entitlements
HELPER_ENTITLEMENTS = Resources/CloudTunnelsProxyHelper.entitlements

# Notarization profile name stored in the login keychain via:
#   xcrun notarytool store-credentials "$(NOTARY_PROFILE)" \
#       --apple-id <id> --team-id <team> --password <app-specific-password>
# Override on the command line if you store creds under a different label.
NOTARY_PROFILE ?= fournine-notary

# Per-arch build paths keep XCBuild caches from colliding.
ARM64_BUILD_PATH = .build-arm64
X86_64_BUILD_PATH = .build-x86_64
ARM64_BIN = $(ARM64_BUILD_PATH)/arm64-apple-macosx/release/$(APP_NAME)
X86_64_BIN = $(X86_64_BUILD_PATH)/x86_64-apple-macosx/release/$(APP_NAME)
ARM64_HELPER_BIN = $(ARM64_BUILD_PATH)/arm64-apple-macosx/release/$(HELPER_NAME)
X86_64_HELPER_BIN = $(X86_64_BUILD_PATH)/x86_64-apple-macosx/release/$(HELPER_NAME)
ARM64_CLI_BIN = $(ARM64_BUILD_PATH)/arm64-apple-macosx/release/$(CLI_NAME)
X86_64_CLI_BIN = $(X86_64_BUILD_PATH)/x86_64-apple-macosx/release/$(CLI_NAME)
ARM64_APP_DIR = build/arm64
X86_64_APP_DIR = build/x86_64
ARM64_APP_BUNDLE = $(ARM64_APP_DIR)/$(APP_NAME).app
X86_64_APP_BUNDLE = $(X86_64_APP_DIR)/$(APP_NAME).app

.PHONY: all build test run app sign clean install zip cli install-cli uninstall-cli \
        uninstall-helper download-caddy notarize staple notarize-arm64 notarize-x86_64 \
        build-arm64 build-x86_64 app-arm64 app-x86_64 zip-arm64 zip-x86_64 zip-all \
        cli-arm64 cli-x86_64

all: app

build:
	swift build -c release --arch arm64 --arch x86_64

test:
	swift test

# Downloads Caddy v$(CADDY_VERSION) for both macOS architectures and
# fuses them into a single universal binary at vendor/caddy via lipo.
# Best-effort on both sides:
#   - If one arch fails but the other succeeds, ship the single-arch
#     binary (users on that arch get native; users on the other arch
#     get a warning at build time but the app still builds).
#   - If both fail, warn and skip entirely — the runtime falls back
#     to system Caddy at /opt/homebrew/bin/caddy or /usr/local/bin/caddy.
download-caddy:
	@if [ -x $(CADDY_VENDOR_BIN) ]; then \
	    echo "Caddy already vendored at $(CADDY_VENDOR_BIN)"; \
	    exit 0; \
	fi
	@mkdir -p $(CADDY_VENDOR_DIR)
	@echo "Downloading Caddy v$(CADDY_VERSION) (arm64 + amd64)..."
	@arm64_ok=0; amd64_ok=0; \
	if curl -fsSL -o $(CADDY_VENDOR_DIR)/caddy_arm64.tar.gz $(CADDY_URL_ARM64) 2>/dev/null; then \
	    tar -xzf $(CADDY_VENDOR_DIR)/caddy_arm64.tar.gz -C $(CADDY_VENDOR_DIR) caddy && \
	    mv $(CADDY_VENDOR_DIR)/caddy $(CADDY_VENDOR_DIR)/caddy_arm64 && \
	    rm $(CADDY_VENDOR_DIR)/caddy_arm64.tar.gz && \
	    arm64_ok=1; \
	else \
	    echo "  arm64 download failed"; \
	    rm -f $(CADDY_VENDOR_DIR)/caddy_arm64.tar.gz; \
	fi; \
	if curl -fsSL -o $(CADDY_VENDOR_DIR)/caddy_amd64.tar.gz $(CADDY_URL_AMD64) 2>/dev/null; then \
	    tar -xzf $(CADDY_VENDOR_DIR)/caddy_amd64.tar.gz -C $(CADDY_VENDOR_DIR) caddy && \
	    mv $(CADDY_VENDOR_DIR)/caddy $(CADDY_VENDOR_DIR)/caddy_amd64 && \
	    rm $(CADDY_VENDOR_DIR)/caddy_amd64.tar.gz && \
	    amd64_ok=1; \
	else \
	    echo "  amd64 download failed"; \
	    rm -f $(CADDY_VENDOR_DIR)/caddy_amd64.tar.gz; \
	fi; \
	if [ $$arm64_ok -eq 1 ] && [ $$amd64_ok -eq 1 ]; then \
	    lipo -create $(CADDY_VENDOR_DIR)/caddy_arm64 $(CADDY_VENDOR_DIR)/caddy_amd64 -output $(CADDY_VENDOR_BIN); \
	    rm $(CADDY_VENDOR_DIR)/caddy_arm64 $(CADDY_VENDOR_DIR)/caddy_amd64; \
	    chmod +x $(CADDY_VENDOR_BIN); \
	    echo "Caddy v$(CADDY_VERSION) universal binary at $(CADDY_VENDOR_BIN)"; \
	elif [ $$arm64_ok -eq 1 ]; then \
	    mv $(CADDY_VENDOR_DIR)/caddy_arm64 $(CADDY_VENDOR_BIN); \
	    chmod +x $(CADDY_VENDOR_BIN); \
	    echo "Caddy v$(CADDY_VERSION) arm64-only at $(CADDY_VENDOR_BIN) (amd64 users will fall back to system caddy)"; \
	elif [ $$amd64_ok -eq 1 ]; then \
	    mv $(CADDY_VENDOR_DIR)/caddy_amd64 $(CADDY_VENDOR_BIN); \
	    chmod +x $(CADDY_VENDOR_BIN); \
	    echo "Caddy v$(CADDY_VERSION) amd64-only at $(CADDY_VENDOR_BIN) (arm64 users will fall back to system caddy)"; \
	else \
	    echo "WARNING: both Caddy downloads failed. Skipping bundle. Helper will fall back to system caddy at runtime (/opt/homebrew/bin/caddy or /usr/local/bin/caddy)."; \
	fi

# Builds the .app bundle with the helper executable + LaunchDaemons plist
# in the SMAppService-required layout, then ad-hoc signs the bundle.
# Includes the bundled Caddy binary at Contents/MacOS/caddy if vendor/
# has it. If not, the helper falls back to system caddy at runtime.
app: build download-caddy
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(MACOS_DIR) $(RESOURCES_DIR) $(LAUNCHDAEMONS_DIR)
	@cp $(BIN) $(MACOS_DIR)/$(APP_NAME)
	@cp $(HELPER_BIN) $(MACOS_DIR)/$(HELPER_NAME)
	@if [ -x $(CADDY_VENDOR_BIN) ]; then \
	    cp $(CADDY_VENDOR_BIN) $(MACOS_DIR)/caddy && chmod +x $(MACOS_DIR)/caddy && \
	    echo "Bundled caddy at $(MACOS_DIR)/caddy"; \
	else \
	    echo "No vendored caddy; relying on system caddy at runtime."; \
	fi
	@cp Resources/Info.plist $(CONTENTS)/Info.plist
	@cp Resources/AppIcon.icns $(RESOURCES_DIR)/AppIcon.icns
	@cp Sources/CloudTunnels/Resources/MenuBarIconTemplate.png $(RESOURCES_DIR)/MenuBarIconTemplate.png
	@cp Sources/CloudTunnels/Resources/BrandHeaderLogo.png $(RESOURCES_DIR)/BrandHeaderLogo.png
	@cp Resources/LaunchDaemons/$(HELPER_BUNDLE_ID).plist $(LAUNCHDAEMONS_DIR)/
	@touch $(APP_BUNDLE)
	@$(MAKE) sign
	@echo "Built $(APP_BUNDLE)"

# Signs the helper and the bundled Caddy binary (inside-out signing),
# then the app bundle as a whole. Ad-hoc signing (SIGN_IDENTITY=-) is
# enough for SMAppService to work on the user's own machine. The
# bundled Caddy must be re-signed because the GitHub-distributed binary
# carries its own signature, which doesn't match this app's identity
# and would cause Gatekeeper to reject the spawn.
sign:
	@if [ -x $(MACOS_DIR)/caddy ]; then \
	    codesign --force --options runtime --sign "$(SIGN_IDENTITY)" $(MACOS_DIR)/caddy; \
	fi
	@codesign --force --options runtime \
		--entitlements $(HELPER_ENTITLEMENTS) \
		--sign "$(SIGN_IDENTITY)" \
		$(MACOS_DIR)/$(HELPER_NAME)
	@codesign --force --options runtime --deep \
		--entitlements $(APP_ENTITLEMENTS) \
		--sign "$(SIGN_IDENTITY)" \
		$(APP_BUNDLE)
	@echo "Signed $(APP_BUNDLE) with identity: $(SIGN_IDENTITY)"

run: app
	open $(APP_BUNDLE)

install: app
	@rm -rf /Applications/$(APP_NAME).app
	@cp -R $(APP_BUNDLE) /Applications/
	@xattr -dr com.apple.quarantine /Applications/$(APP_NAME).app || true
	@echo "Installed to /Applications/$(APP_NAME).app"

# Removes the privileged proxy helper from launchd via SMAppService and
# wipes its on-disk state. Use this after uninstalling the .app bundle to
# leave the system clean. The user is prompted in System Settings to
# confirm the unregister.
uninstall-helper:
	@if /Applications/$(APP_NAME).app/Contents/MacOS/$(APP_NAME) --uninstall-helper 2>/dev/null; then \
		echo "Sent uninstall signal to running app"; \
	else \
		echo "App not running — using launchctl + manual cleanup"; \
		sudo launchctl bootout system/$(HELPER_BUNDLE_ID) 2>/dev/null || true; \
	fi
	@sudo rm -rf "/Library/Application Support/CloudTunnels/proxy" || true
	@sudo /usr/bin/security delete-certificate -c "CloudTunnels Local CA" /Library/Keychains/System.keychain 2>/dev/null || true
	@sudo sed -i '' '/# CloudTunnels:/d' /etc/hosts || true
	@echo "Helper, CA, and /etc/hosts entries removed"

zip: app
	@rm -f build/$(APP_NAME).zip
	@cd build && ditto -c -k --sequesterRsrc --keepParent $(APP_NAME).app $(APP_NAME).zip
	@echo "Created build/$(APP_NAME).zip"

# Submit the universal .app to Apple's notary service, wait for a verdict,
# staple the ticket onto the bundle, then re-zip so the distributed archive
# includes the staple. Requires SIGN_IDENTITY to be a real "Developer ID
# Application" cert (ad-hoc and Apple Development certs are rejected).
# Run `xcrun notarytool store-credentials "$(NOTARY_PROFILE)"` once before
# the first invocation.
notarize: zip
	@echo "Submitting build/$(APP_NAME).zip to Apple notary service (this can take several minutes)..."
	@xcrun notarytool submit build/$(APP_NAME).zip --keychain-profile $(NOTARY_PROFILE) --wait
	@$(MAKE) staple
	@echo "Re-packaging stapled bundle..."
	@rm -f build/$(APP_NAME).zip
	@cd build && ditto -c -k --sequesterRsrc --keepParent $(APP_NAME).app $(APP_NAME).zip
	@echo ""
	@echo "Notarized + stapled $(APP_BUNDLE)"
	@ls -lh build/$(APP_NAME).zip

# Staple the notarization ticket onto the .app and verify Gatekeeper
# acceptance. Run after a successful `notarytool submit ... --wait`.
staple:
	@xcrun stapler staple $(APP_BUNDLE)
	@xcrun stapler validate $(APP_BUNDLE)
	@spctl -a -vvv -t install $(APP_BUNDLE) || true

# Per-arch notarize variants. Useful when shipping single-arch zips.
notarize-arm64: zip-arm64
	@xcrun notarytool submit build/$(APP_NAME)-arm64.zip --keychain-profile $(NOTARY_PROFILE) --wait
	@xcrun stapler staple $(ARM64_APP_BUNDLE)
	@xcrun stapler validate $(ARM64_APP_BUNDLE)
	@rm -f build/$(APP_NAME)-arm64.zip
	@cd $(ARM64_APP_DIR) && ditto -c -k --sequesterRsrc --keepParent $(APP_NAME).app ../$(APP_NAME)-arm64.zip
	@echo "Notarized + stapled $(ARM64_APP_BUNDLE)"

notarize-x86_64: zip-x86_64
	@xcrun notarytool submit build/$(APP_NAME)-x86_64.zip --keychain-profile $(NOTARY_PROFILE) --wait
	@xcrun stapler staple $(X86_64_APP_BUNDLE)
	@xcrun stapler validate $(X86_64_APP_BUNDLE)
	@rm -f build/$(APP_NAME)-x86_64.zip
	@cd $(X86_64_APP_DIR) && ditto -c -k --sequesterRsrc --keepParent $(APP_NAME).app ../$(APP_NAME)-x86_64.zip
	@echo "Notarized + stapled $(X86_64_APP_BUNDLE)"

cli:
	swift build -c release --arch arm64 --arch x86_64 --product $(CLI_NAME)
	@echo "Built $(CLI_BIN)"

install-cli: cli
	@install -m 0755 $(CLI_BIN) $(CLI_INSTALL_PATH)
	@echo "Installed $(CLI_INSTALL_PATH)"

uninstall-cli:
	@rm -f $(CLI_INSTALL_PATH)
	@echo "Removed $(CLI_INSTALL_PATH)"

# ----------------------------------------------------------------------------
# Per-architecture builds — Apple Silicon (arm64) and Intel (x86_64)
# ----------------------------------------------------------------------------

build-arm64:
	swift build -c release --arch arm64 --build-path $(ARM64_BUILD_PATH)

build-x86_64:
	swift build -c release --arch x86_64 --build-path $(X86_64_BUILD_PATH)

app-arm64: build-arm64
	@rm -rf $(ARM64_APP_BUNDLE)
	@mkdir -p $(ARM64_APP_BUNDLE)/Contents/MacOS $(ARM64_APP_BUNDLE)/Contents/Resources $(ARM64_APP_BUNDLE)/Contents/Library/LaunchDaemons
	@cp $(ARM64_BIN) $(ARM64_APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	@cp $(ARM64_HELPER_BIN) $(ARM64_APP_BUNDLE)/Contents/MacOS/$(HELPER_NAME)
	@cp Resources/Info.plist $(ARM64_APP_BUNDLE)/Contents/Info.plist
	@cp Resources/AppIcon.icns $(ARM64_APP_BUNDLE)/Contents/Resources/AppIcon.icns
	@cp Sources/CloudTunnels/Resources/MenuBarIconTemplate.png $(ARM64_APP_BUNDLE)/Contents/Resources/MenuBarIconTemplate.png
	@cp Sources/CloudTunnels/Resources/BrandHeaderLogo.png $(ARM64_APP_BUNDLE)/Contents/Resources/BrandHeaderLogo.png
	@cp Resources/LaunchDaemons/$(HELPER_BUNDLE_ID).plist $(ARM64_APP_BUNDLE)/Contents/Library/LaunchDaemons/
	@codesign --force --options runtime --entitlements $(HELPER_ENTITLEMENTS) --sign "$(SIGN_IDENTITY)" $(ARM64_APP_BUNDLE)/Contents/MacOS/$(HELPER_NAME)
	@codesign --force --options runtime --deep --entitlements $(APP_ENTITLEMENTS) --sign "$(SIGN_IDENTITY)" $(ARM64_APP_BUNDLE)
	@touch $(ARM64_APP_BUNDLE)
	@echo "Built $(ARM64_APP_BUNDLE) (Apple Silicon)"

app-x86_64: build-x86_64
	@rm -rf $(X86_64_APP_BUNDLE)
	@mkdir -p $(X86_64_APP_BUNDLE)/Contents/MacOS $(X86_64_APP_BUNDLE)/Contents/Resources $(X86_64_APP_BUNDLE)/Contents/Library/LaunchDaemons
	@cp $(X86_64_BIN) $(X86_64_APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	@cp $(X86_64_HELPER_BIN) $(X86_64_APP_BUNDLE)/Contents/MacOS/$(HELPER_NAME)
	@cp Resources/Info.plist $(X86_64_APP_BUNDLE)/Contents/Info.plist
	@cp Resources/AppIcon.icns $(X86_64_APP_BUNDLE)/Contents/Resources/AppIcon.icns
	@cp Sources/CloudTunnels/Resources/MenuBarIconTemplate.png $(X86_64_APP_BUNDLE)/Contents/Resources/MenuBarIconTemplate.png
	@cp Sources/CloudTunnels/Resources/BrandHeaderLogo.png $(X86_64_APP_BUNDLE)/Contents/Resources/BrandHeaderLogo.png
	@cp Resources/LaunchDaemons/$(HELPER_BUNDLE_ID).plist $(X86_64_APP_BUNDLE)/Contents/Library/LaunchDaemons/
	@codesign --force --options runtime --entitlements $(HELPER_ENTITLEMENTS) --sign "$(SIGN_IDENTITY)" $(X86_64_APP_BUNDLE)/Contents/MacOS/$(HELPER_NAME)
	@codesign --force --options runtime --deep --entitlements $(APP_ENTITLEMENTS) --sign "$(SIGN_IDENTITY)" $(X86_64_APP_BUNDLE)
	@touch $(X86_64_APP_BUNDLE)
	@echo "Built $(X86_64_APP_BUNDLE) (Intel)"

# Per-arch zip filenames carry the architecture (CloudTunnels-arm64.zip),
# but the .app inside is always named $(APP_NAME).app so the install
# instructions (`open /Applications/CloudTunnels.app`) work regardless
# of which zip the user downloaded.
zip-arm64: app-arm64
	@rm -f build/$(APP_NAME)-arm64.zip
	@cd $(ARM64_APP_DIR) && ditto -c -k --sequesterRsrc --keepParent $(APP_NAME).app ../$(APP_NAME)-arm64.zip
	@echo "Created build/$(APP_NAME)-arm64.zip"

zip-x86_64: app-x86_64
	@rm -f build/$(APP_NAME)-x86_64.zip
	@cd $(X86_64_APP_DIR) && ditto -c -k --sequesterRsrc --keepParent $(APP_NAME).app ../$(APP_NAME)-x86_64.zip
	@echo "Created build/$(APP_NAME)-x86_64.zip"

zip-all: zip-arm64 zip-x86_64
	@echo ""
	@echo "Distribution archives:"
	@ls -lh build/$(APP_NAME)-arm64.zip build/$(APP_NAME)-x86_64.zip

cli-arm64:
	swift build -c release --arch arm64 --product $(CLI_NAME) --build-path $(ARM64_BUILD_PATH)
	@echo "Built $(ARM64_CLI_BIN) (Apple Silicon)"

cli-x86_64:
	swift build -c release --arch x86_64 --product $(CLI_NAME) --build-path $(X86_64_BUILD_PATH)
	@echo "Built $(X86_64_CLI_BIN) (Intel)"

clean:
	swift package clean
	rm -rf .build .build-arm64 .build-x86_64 build
