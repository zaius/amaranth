build_dir := ".build"
app_path := build_dir / "Build/Products/Debug/Amaranth.app"
lsregister := "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

default: run

# Regenerate Amaranth.xcodeproj from project.yml (XcodeGen)
generate:
    xcodegen generate

# Build the app with xcodebuild (Debug)
build: generate
    xcodebuild \
      -project Amaranth.xcodeproj \
      -scheme Amaranth \
      -destination 'platform=macOS' \
      -allowProvisioningUpdates \
      -configuration Debug \
      -derivedDataPath "{{build_dir}}" \
      build

# Build, then restart Amaranth (prompts if already running)
run:
    #!/usr/bin/env bash
    set -e
    start_after_build=true
    if pgrep -x "Amaranth" > /dev/null; then
        read -r -p "Amaranth is currently running. Kill it after building? [Y/n] " response
        case "$response" in
            [nN]|[nN][oO]) start_after_build=false ;;
        esac
    fi
    just build
    if [ "$start_after_build" = true ]; then
        killall Amaranth 2>/dev/null || true
        while pgrep -x "Amaranth" > /dev/null; do sleep 0.1; done
        # Refresh LaunchServices' record of the bundle before `open` — otherwise a
        # stale registration from the just-killed instance can make `open` return -600.
        {{lsregister}} -f "{{app_path}}"
        open "{{app_path}}"
    fi

# Reset Control Center's cached state for the control extension. Use if the
# control gets wedged (ghost/duplicate, no icon, taps do nothing) after changing
# its structure — then re-add the control in Control Center. chronod and
# ControlCenter relaunch automatically.
reset-controls:
    rm -rf "$HOME/Library/Containers/so.kel.Amaranth.Control"
    killall ControlCenter chronod 2>/dev/null || true
    @echo "Control Center cache reset — re-add the Amaranth control."

# Remove build artifacts
clean:
    rm -rf "{{build_dir}}" release

# --- Distribution ---------------------------------------------------------

bundle_id := "so.kel.Amaranth"
release_dir := "release"
archive_path := release_dir / "Amaranth.xcarchive"
export_dir := release_dir / "export"
# owner/repo this ships from. DMGs are attached to the GitHub release; the
# Sparkle appcast is served from GitHub Pages (see SUFeedURL in Info.plist).
github_repo := "zaius/amaranth"
# Keychain profile created once via:
#   xcrun notarytool store-credentials amaranth-notary \
#     --apple-id david@kel.so --team-id P9U2E575US
notary_profile := "amaranth-notary"
# Sparkle's CLI tools, fetched as an SPM binary artifact into the derived data.
sparkle_bin := build_dir / "SourcePackages/artifacts/sparkle/Sparkle/bin"

# Outputs release/Amaranth-VERSION.dmg and release/appcast/appcast.xml. This is
# what CI runs; run it locally to produce/test a notarized DMG without
# publishing. Cut an actual release with `just release VERSION`.
#
# Build, sign, notarize, staple, package a DMG + signed appcast for VERSION
package version: generate
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf "{{release_dir}}"
    mkdir -p "{{release_dir}}"

    # Build number = git commit count (monotonic int, valid CFBundleVersion).
    # Git SHA is injected into the bundle for crash-report correlation.
    GIT_BUILD=$(git rev-list --count HEAD)
    GIT_SHA=$(git rev-parse --short HEAD)
    echo "==> Building Amaranth {{version}} → build $GIT_BUILD ($GIT_SHA)"

    # Automatic signing must now authorize the App Group entitlement (shared
    # container with the Control Center extension), which requires provisioning
    # updates. In CI an App Store Connect API key — ASC_KEY_ID / ASC_ISSUER_ID /
    # ASC_KEY_PATH — lets xcodebuild register the capability and mint the
    # Developer ID profiles non-interactively (the key needs Admin or App
    # Manager access). Locally the signed-in Xcode account covers it, so the key
    # is optional. The `${auth[@]+...}` guard keeps the empty array safe under
    # `set -u` on macOS's bash 3.2.
    auth=()
    if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] && [ -n "${ASC_KEY_PATH:-}" ]; then
      echo "==> Using App Store Connect API key $ASC_KEY_ID for provisioning"
      auth=(-authenticationKeyID "$ASC_KEY_ID" \
            -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
            -authenticationKeyPath "$ASC_KEY_PATH")
    fi

    echo "==> Archiving (Release)…"
    xcodebuild \
      -project Amaranth.xcodeproj \
      -scheme Amaranth \
      -configuration Release \
      -destination 'platform=macOS' \
      -archivePath "{{archive_path}}" \
      -derivedDataPath "{{build_dir}}" \
      -allowProvisioningUpdates "${auth[@]+"${auth[@]}"}" \
      MARKETING_VERSION="{{version}}" \
      CURRENT_PROJECT_VERSION="$GIT_BUILD" \
      GIT_COMMIT="$GIT_SHA" \
      archive

    echo "==> Exporting with Developer ID…"
    xcodebuild -exportArchive \
      -archivePath "{{archive_path}}" \
      -exportPath "{{export_dir}}" \
      -exportOptionsPlist ExportOptions.plist \
      -allowProvisioningUpdates "${auth[@]+"${auth[@]}"}"

    APP="{{export_dir}}/Amaranth.app"

    echo "==> Notarizing the app…"
    ditto -c -k --keepParent "$APP" "{{release_dir}}/Amaranth.zip"
    xcrun notarytool submit "{{release_dir}}/Amaranth.zip" \
      --keychain-profile "{{notary_profile}}" --wait
    xcrun stapler staple "$APP"

    echo "==> Building DMG (create-dmg)…"
    # create-dmg lays out the app + /Applications symlink, uses the app icon as
    # the volume icon, signs the DMG, and writes "Amaranth <version>.dmg". It
    # exits 2 on non-fatal code-signing warnings, so don't let `set -e` abort.
    create-dmg "$APP" "{{release_dir}}" || true
    RAW_DMG=$(ls -t "{{release_dir}}"/*.dmg | head -1)
    test -f "$RAW_DMG"
    # Normalize the filename to match the release asset / appcast URL.
    DMG="{{release_dir}}/Amaranth-{{version}}.dmg"
    [ "$RAW_DMG" = "$DMG" ] || mv "$RAW_DMG" "$DMG"
    echo "    built: $DMG"

    echo "==> Notarizing the DMG…"
    xcrun notarytool submit "$DMG" \
      --keychain-profile "{{notary_profile}}" --wait
    xcrun stapler staple "$DMG"

    echo "==> Verifying Gatekeeper acceptance…"
    spctl -a -vvv "$APP"

    # --- Sentry: upload dSYMs + mark the release. Skipped unless a token is set,
    # so local builds without Sentry creds still work. Reads SENTRY_ORG /
    # SENTRY_PROJECT / SENTRY_AUTH_TOKEN from the env (or ~/.sentryclirc).
    # Best-effort: a Sentry failure warns but never blocks shipping the (already
    # signed + notarized) release — dSYMs can always be re-uploaded later. ---
    if [ -n "${SENTRY_AUTH_TOKEN:-}" ]; then
      echo "==> Uploading dSYMs to Sentry…"
      # Release name must match the SDK's auto value: {bundleID}@{short}+{build}.
      RELEASE="{{bundle_id}}@{{version}}+$GIT_BUILD"
      if ( set -e
        sentry-cli debug-files upload "{{archive_path}}/dSYMs"
        sentry-cli releases new "$RELEASE"
        sentry-cli releases set-commits "$RELEASE" --local --ignore-missing || true
        sentry-cli releases finalize "$RELEASE"
      ); then
        echo "    Sentry release: $RELEASE"
      else
        echo "::warning::Sentry upload failed — check SENTRY_ORG/SENTRY_PROJECT/SENTRY_AUTH_TOKEN. Continuing."
      fi
    else
      echo "==> Skipping Sentry upload (SENTRY_AUTH_TOKEN not set)"
    fi

    echo "==> Generating signed appcast…"
    # generate_appcast reads the version from the bundle inside the (stapled)
    # DMG and signs it with the EdDSA key. Downloads point at the GitHub release
    # asset URL for this tag; the appcast.xml itself is hosted on GitHub Pages.
    APPCAST_DIR="{{release_dir}}/appcast"
    mkdir -p "$APPCAST_DIR"
    cp "$DMG" "$APPCAST_DIR/"
    DL_PREFIX="https://github.com/{{github_repo}}/releases/download/v{{version}}/"
    # Locally the signing key comes from the keychain; in CI it's piped in via
    # the SPARKLE_PRIVATE_KEY secret (--ed-key-file - reads stdin). Deltas are
    # disabled — only the full DMG is hosted (on the GitHub release).
    if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
      printf '%s' "$SPARKLE_PRIVATE_KEY" | "{{sparkle_bin}}/generate_appcast" \
        "$APPCAST_DIR" --maximum-deltas 0 \
        --download-url-prefix "$DL_PREFIX" --ed-key-file -
    else
      "{{sparkle_bin}}/generate_appcast" "$APPCAST_DIR" --maximum-deltas 0 \
        --download-url-prefix "$DL_PREFIX"
    fi
    test -f "$APPCAST_DIR/appcast.xml"
    # Pages only needs appcast.xml; the DMG is served from the GitHub release.
    find "$APPCAST_DIR" -type f ! -name appcast.xml -delete

    echo
    echo "==> Done."
    echo "    DMG     → $DMG  (attach to GitHub release v{{version}})"
    echo "    appcast → $APPCAST_DIR/appcast.xml  (publish to GitHub Pages)"

# The tag push triggers .github/workflows/release.yml, which builds, signs,
# notarizes, creates the GitHub release with the DMG, and publishes the appcast.
#
# Cut a release: bump the version, commit, tag vVERSION and push
release version:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "$(git status --porcelain)" ]; then
        echo "Working tree is dirty — commit or stash first." >&2
        exit 1
    fi
    # MARKETING_VERSION in project.yml is the source of truth for local builds.
    sed -i '' -E 's/^( *MARKETING_VERSION: ).*/\1"{{version}}"/' project.yml
    git add project.yml
    git commit -m "Release v{{version}}"
    git tag -a "v{{version}}" -m "v{{version}}"
    git push origin HEAD
    git push origin "v{{version}}"
    echo
    echo "Pushed v{{version}} — GitHub Actions will build, sign, notarize,"
    echo "create the release, and publish the appcast to Pages."
    echo "Watch it: https://github.com/{{github_repo}}/actions"
