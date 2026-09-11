#!/bin/bash

set -e

# Configuration
VERSION=${VERSION:-323}
PACKAGE_NAME="cockpit-base1"
BUILD_DIR="build"
OUTPUT_DIR="cockpit"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
    exit 1
}

# Function to download cockpit tarball
download() {
    local version=${1:-$VERSION}
    log "Downloading cockpit tarball for version $version"
    
    local tarball="cockpit-$version.tar.xz"
    local url="https://github.com/cockpit-project/cockpit/releases/download/$version/$tarball"
    
    if [[ -f "$tarball" ]]; then
        warn "Tarball $tarball already exists, skipping download"
    else
        wget -nv "$url" || error "Failed to download tarball from $url"
    fi
}

# Function to extract tarball
extract() {
    local version=${1:-$VERSION}
    log "Extracting tarball for version $version"
    
    local tarball="cockpit-$version.tar.xz"
    
    [[ -f "$tarball" ]] || error "Tarball $tarball not found"
    
    mkdir -p "$BUILD_DIR"
    tar -xf "$tarball" --strip-components=1 -C "$BUILD_DIR" || error "Failed to extract tarball"
}

# Function to patch build.js
configure-build() {
    log "Patching build.js"
    
    local build_file="$BUILD_DIR/build.js"
    [[ -f "$build_file" ]] || error "Build file $build_file not found"
    
    if sed --version >/dev/null 2>&1; then
        sed -i 's/outdir: "\.\/dist",/outdir: ".\/dist", format: "esm",/' "$build_file" || error "Failed to patch build.js"
    else
        #macOS
        sed -i '' 's/outdir: "\.\/dist",/outdir: ".\/dist", format: "esm",/' "$build_file" || error "Failed to patch build.js"
    fi
}

# Function to install npm dependencies
install-deps() {
    log "Installing npm dependencies"
    
    [[ -d "$BUILD_DIR" ]] || error "Build directory $BUILD_DIR not found"
    
    # npm install, not npm ci: the lock file in the cockpit tarball only has
    # the optional platform deps (esbuild/sass-embedded/fsevents) of one
    # platform, which npm >= 11 rejects under npm ci (EUSAGE).
    cd "$BUILD_DIR" && npm install --no-audit --no-fund || error "Failed to install npm dependencies"
    cd - > /dev/null
}

# Function to install build dependencies
install-build-deps() {
    log "Installing build dependencies"
    
    if [[ -f "package.json" ]]; then
        npm install || error "Failed to install build dependencies"
    else
        error "package.json not found in project root"
    fi
}

# Function to build cockpit
build() {
    log "Building cockpit"
    
    [[ -d "$BUILD_DIR" ]] || error "Build directory $BUILD_DIR not found"
    
    cd "$BUILD_DIR" 
    node build.js base1 || error "Failed to build cockpit"
    cd - > /dev/null
}

# Function to determine next npm version
# npm version = <cockpit-tag>.<patch>: plain tags keep a .0 minor (337.0.x),
# point releases carry their own minor (356.3.x). tag may be dotted or plain.
version-prefix() {
    local tag=${1:-$VERSION}
    if [[ "$tag" == *.* ]]; then echo "$tag"; else echo "$tag.0"; fi
}

version() {
    local major=${1:-$VERSION}
    local package=${2:-$PACKAGE_NAME}
    local prefix
    prefix=$(version-prefix "$major")
    local re
    re="${prefix//./\\.}"

    local versions
    versions=$(npm view "$package" versions --json 2>/dev/null | jq -r '.[]'         | grep "^${re}\.[0-9]\+$" || true)

    local next_version
    if [[ -z "$versions" ]]; then
        next_version="$prefix.1"
    else
        local max_patch
        max_patch=$(echo "$versions" | awk -F. '{print $NF}' | sort -n | tail -1)
        next_version="$prefix.$((max_patch + 1))"
    fi
    echo "$next_version"
}

# Function to build base package
package() {
    local next_version=${1}
    log "Building base package"
    
    [[ -d "$BUILD_DIR" ]] || error "Build directory $BUILD_DIR not found"
    [[ -n "$next_version" ]] || error "Next version not provided"
    
    mkdir -p "$OUTPUT_DIR/lib"
    cp -r "$BUILD_DIR/pkg/lib/"* "$OUTPUT_DIR/lib" || error "Failed to copy lib files"
    
    # Convert TypeScript and TSX files using Babel (strip types while preserving JSX)
    for file in "$OUTPUT_DIR/lib/"*.{ts,tsx}; do
        if [[ -f "$file" && ! "$file" =~ \.d\.ts$ ]]; then
            local basename=$(basename "$file")
            local dirname=$(dirname "$file")
            local extension="${basename##*.}"
            local name="${basename%.*}"
            
            local output_file
            if [[ "$extension" == "tsx" ]]; then
                output_file="$dirname/$name.jsx"
            else
                output_file="$dirname/$name.js"
            fi

            "node_modules/.bin/babel" "$file" --out-file "$output_file" \
                --filename "$file" \
                --config-file "$(pwd)/.babelrc.json" \
                || warn "Failed to convert $file using Babel"
            
            if [[ -f "$output_file" ]]; then
                rm -f "$file"
            else
                warn "Output file was not created for $file"
            fi
        fi
    done
    
    # Create package.json. 'repository' MUST point at the real GitHub repo:
    # trusted publishing (npm publish/stage publish via OIDC) validates it.
    # 'buildInfo' fingerprints the tooling+source used, so future CI runs can
    # skip rebuilding a version whose inputs haven't changed.
    local repo_url="${REPOSITORY_URL:-git+https://github.com/nick123pig/cockpit-base1.git}"
    local btag btool bsrc build_info
    btag=${next_version%.*}     # 337.0.10 -> 337.0, 356.3.2 -> 356.3
    btag=${btag%.0}             # 337.0 -> 337 (plain tags have no .0 tarball)
    btool=$(tooling-hash 2>/dev/null || true)
    bsrc=$(sha256sum "cockpit-$btag.tar.xz" 2>/dev/null | awk '{print $1}')
    build_info="${btool:-none}-${bsrc:-none}"
    local base_package="{\"name\": \"$PACKAGE_NAME\", \"version\": \"$next_version\", \"main\": \"index.mjs\", \"type\": \"module\", \"license\": \"MIT\", \"repository\": {\"type\": \"git\", \"url\": \"$repo_url\"}, \"buildInfo\": \"$build_info\"}"
    local build_package="$BUILD_DIR/package.json"
    
    if [[ -f "$build_package" ]]; then
        # Merge dependencies from build package.json
        echo "$base_package" | jq --slurpfile build_deps <(jq '{dependencies}' "$build_package") '. + $build_deps[0]' > "$OUTPUT_DIR/package.json"
    else
        # Fallback to basic package.json if build package.json doesn't exist
        echo "$base_package" | jq '.' > "$OUTPUT_DIR/package.json"
    fi
    
    # Create main index file
    cat "$BUILD_DIR/dist/base1/cockpit.js" >> "$OUTPUT_DIR/index.mjs" || error "Failed to create index.mjs"
    printf "\n\nexport default cockpit;" >> "$OUTPUT_DIR/index.mjs"
}

patch() {
    log "Patching"

    # Empty the patternfly-5-overrides.scss file if it exists
    local overrides_file="$OUTPUT_DIR/lib/patternfly/patternfly-5-overrides.scss"
    if [[ -f "$overrides_file" ]]; then
        log "Emptying patternfly-5-overrides.scss file"
        > "$overrides_file" || warn "Failed to empty patternfly-5-overrides.scss"
    fi

    # convert any references to require("cockpit") to require("cockpit-base1")
    log "Converting require(\"cockpit\") to require(\"cockpit-base1\") in $OUTPUT_DIR/lib"
    
    # Find all files in lib directory and replace require("cockpit") with require("cockpit-base1")
    if find "$OUTPUT_DIR/lib" -type f \( -name "*.js" -o -name "*.mjs" -o -name "*.jsx" \) -print0 | while IFS= read -r -d '' file; do
        local patched=false
        
        # Check and replace require("cockpit")
        if grep -q 'require("cockpit")' "$file" 2>/dev/null; then
            log "Patching require statements in: $file"
            if sed --version >/dev/null 2>&1; then
                # GNU sed
                sed -i 's/require("cockpit")/require("cockpit-base1")/g' "$file" || warn "Failed to patch require in $file with GNU sed"
            else
                # macOS sed
                sed -i '' 's/require("cockpit")/require("cockpit-base1")/g' "$file" || warn "Failed to patch require in $file with macOS sed"
            fi
            patched=true
        fi
        
        # Check and replace import cockpit from "cockpit" or 'cockpit'
        if grep -q "import.*from.*['\"]cockpit['\"]" "$file" 2>/dev/null; then
            log "Patching import statements in: $file"
            if sed --version >/dev/null 2>&1; then
                # GNU sed - handle both single and double quotes
                sed -i 's/from *"cockpit"/from "cockpit-base1"/g' "$file" || warn "Failed to patch imports in $file with GNU sed"
                sed -i "s/from *'cockpit'/from 'cockpit-base1'/g" "$file" || warn "Failed to patch imports in $file with GNU sed"
            else
                # macOS sed - handle both single and double quotes
                sed -i '' 's/from *"cockpit"/from "cockpit-base1"/g' "$file" || warn "Failed to patch imports in $file with macOS sed"
                sed -i '' "s/from *'cockpit'/from 'cockpit-base1'/g" "$file" || warn "Failed to patch imports in $file with macOS sed"
            fi
            patched=true
        fi
        
        if [[ "$patched" == true ]]; then
            log "Completed patching: $file"
        fi
    done; then
        log "Completed patching cockpit references"
    else
        warn "No files found to patch or patching failed"
    fi
}

# Function to copy additional files
copy() {
    log "Copying additional files"
    
    [[ -f "README.md" ]] && cp README.md "$OUTPUT_DIR/" || warn "README.md not found"
}

# Function to build and stage the package as a publishable tarball
stage() {
    local version=${1:-$VERSION}
    log "Building and staging package for version $version"

    full "$version" false

    local root
    root=$(pwd)
    mkdir -p staging
    if ! (cd "$OUTPUT_DIR" && npm pack --quiet --pack-destination "$root/staging" >/dev/null 2>&1); then
        error "Failed to create staging tarball for version $version"
    fi

    local tarball
    tarball=$(ls "$root/staging/cockpit-base1-*.tgz" 2>/dev/null | head -1)
    [[ -f "$tarball" ]] || error "Staging tarball was not created for version $version"
    log "Staged $tarball"
}

# Fingerprint of everything in this repo that shapes the published output:
# build.sh, babel config, dependency spec, and the files that ship in the
# package (README/LICENSE). Any change here invalidates every published build.
tooling-hash() {
    sha256sum build.sh .babelrc.json package.json README.md LICENSE 2>/dev/null \
        | sha256sum | awk '{print $1}'
}

# Highest published version for a cockpit major (e.g. 337 -> 337.0.10, "" if none).
published-latest() {
    local prefix re
    prefix=$(version-prefix "$1")
    re="${prefix//./\\.}"
    npm view "$PACKAGE_NAME" versions --json 2>/dev/null \
        | jq -r '.[]' | grep "^${re}\.[0-9]\+$" | sort -V | tail -1
}

# Remember what this pipeline staged/published per cockpit tag, so future runs
# skip identical-input builds even while the version is still pending approval
# (npm stage list requires interactive auth, so the registry can't tell us).
# Manifest is a JSON artifact carried between runs (state/stage-manifest.json).
record-stage() {
    local mf="${STAGE_MANIFEST:-state/stage-manifest.json}"
    mkdir -p "$(dirname "$mf")"
    local tmp
    tmp=$(mktemp)
    if [[ -f "$mf" ]]; then cp "$mf" "$tmp"; else echo '{}' > "$tmp"; fi
    if jq --arg t "$1" --arg v "$2" --arg tool "$3" --arg src "$4" \
        '.[$t] = {v: $v, t: $tool, s: $src}' "$tmp" > "${mf}.tmp" 2>/dev/null; then
        mv "${mf}.tmp" "$mf"
    else
        warn "Could not update stage manifest $mf"
    fi
    rm -f "$tmp" "${mf}.tmp"
}

# Build and push into npm's staging area (npm stage publish; needs npm >= 11.15).
# Uses trusted publishing (OIDC) - no token/OTP. Approve in the browser on npmjs.com.
stage-publish() {
    local version=${1:-$VERSION}

    if ! npm --version 2>/dev/null | awk -F. '{ if ($1 > 11 || ($1 == 11 && $2 > 15) || ($1 == 11 && $2 == 15)) ok = 1 } END { exit ok ? 0 : 1 }'; then
        error "npm stage publish requires npm CLI v11.15.0+ (found $(npm --version 2>/dev/null)). Update it with: npm install -g npm@11"
    fi

    # --- Skip when npm already has this major built from identical inputs ---
    # The published package carries a buildInfo fingerprint ("<tooling>-<source>").
    # Unchanged -> nothing to build or stage. Changed tooling or upstream tarball
    # -> rebuild. Force a rebuild with STAGE_FORCE=1.
    local local_tool local_src cur prev_info rec
    local_tool=$(tooling-hash)
    download "$version" >/dev/null 2>&1 || true
    local_src=$(sha256sum "cockpit-$version.tar.xz" 2>/dev/null | awk '{print $1}')

    # 1) Cross-run memory: this tag was already staged by this pipeline with
    #    identical inputs (covers versions still awaiting approval).
    rec=$(jq -c --arg t "$version" '.[$t] // empty' "${STAGE_MANIFEST:-state/stage-manifest.json}" 2>/dev/null || true)
    if [[ "${STAGE_FORCE:-0}" != "1" && -n "$rec" ]]; then
        local rt rs rv
        rt=$(jq -r '.t' <<<"$rec" 2>/dev/null || true)
        rs=$(jq -r '.s' <<<"$rec" 2>/dev/null || true)
        rv=$(jq -r '.v' <<<"$rec" 2>/dev/null || true)
        if [[ "$rt" == "$local_tool" && "$rs" == "$local_src" ]]; then
            log "No changes: $rv already staged/published with the same tooling+source. Skipping $version."
            return 0
        fi
        log "Inputs changed for $version: last staged $rv (${rt}-${rs}) != $local_tool-$local_src"
    fi

    # 2) Registry check: published version carries the same buildInfo.
    cur=$(published-latest "$version")
    if [[ "${STAGE_FORCE:-0}" != "1" && -n "$cur" && -n "$local_tool" && -n "$local_src" ]]; then
        prev_info=$(npm view "$PACKAGE_NAME@$cur" buildInfo 2>/dev/null || true)
        if [[ -n "$prev_info" && "$prev_info" == "$local_tool-$local_src" ]]; then
            log "No changes: published $cur was built with the same tooling+source. Skipping $version."
            return 0
        fi
        warn "Inputs changed for $version: published $cur (buildInfo ${prev_info:-none}) != $local_tool-$local_src - rebuilding"
    fi

    # Race guard: the computed next version is already live.
    local next
    next=$(version "$version" 2>/dev/null || true)
    if [[ -n "$next" ]] && npm view "$PACKAGE_NAME@$next" version >/dev/null 2>&1; then
        warn "$PACKAGE_NAME@$next is already published on npm - nothing to do"
        return 0
    fi

    log "Building and staging $PACKAGE_NAME for version $version"
    full "$version" false

    # npm rejects implicitly tagging "latest" when the new version is lower
    # than the current latest (parallel cockpit majors). Only the newest major
    # in STAGE_VERSIONS may own "latest"; older lines get their own tag.
    local versions="${STAGE_VERSIONS:-323 337 367}"
    local highest
    highest=$(echo "$versions" | tr ' ' '\n' | sort -t. -k1,1n -k2,2n | tail -1)
    local tag=latest
    if [[ "$version" != "$highest" ]]; then
        tag="line-$version"
    fi

    cd "$OUTPUT_DIR" || error "Cannot enter $OUTPUT_DIR"
    local ver
    ver=$(jq -r '.version' package.json 2>/dev/null || true)

    # Skip if this version is already live on the registry.
    if [[ -n "$ver" ]] && npm view "$PACKAGE_NAME@$ver" version >/dev/null 2>&1; then
        warn "$PACKAGE_NAME@$ver is already published on npm - nothing to do"
        cd - > /dev/null || true
        return 0
    fi

    # A previous run may already have staged this version (pending approval).
    # npm stage list needs interactive auth (not available via OIDC), so a
    # stage E409/"Cannot stage previously published version" means it's
    # already staged - treat as success and let the approval happen on npmjs.com.
    # Careful with set -e: `out=$(npm stage publish ...)` would kill the script
    # on failure and silently throw away npm's error, so run it under an `if`.
    local out rc
    if out=$(npm stage publish --access public --tag "$tag" --loglevel verbose 2>&1); then
        rc=0
    else
        rc=$?
    fi
    if [[ $rc -ne 0 ]]; then
        if grep -qi "Cannot stage previously published version" <<<"$out" || grep -qi "E409" <<<"$out"; then
            warn "$PACKAGE_NAME@$ver is already staged or published - nothing to do. Approve it at https://www.npmjs.com/package/$PACKAGE_NAME/staged"
            record-stage "$version" "$ver" "$local_tool" "$local_src"
            cd - > /dev/null || true
            return 0
        fi
        # Surface the real npm error: npm masks OIDC exchange failures unless
        # verbose, and GitHub redacts further. Print stdout+stderr and the npm
        # debug log tail so the actual auth failure is visible in CI output.
        echo "$out" >&2
        local dbg
        dbg=$(ls -t "$HOME"/.npm/_logs/*-debug-0.log 2>/dev/null | head -1)
        if [[ -n "$dbg" ]]; then
            echo "--- npm debug log: $dbg ---" >&2
            tail -60 "$dbg" >&2
        fi
        cd - > /dev/null || true
        error "npm stage publish failed (see message above)"
    fi
    record-stage "$version" "$ver" "$local_tool" "$local_src"
    log "Staged $PACKAGE_NAME@${ver:-$(jq -r '.version' package.json)} (tag: $tag) - approve it at https://www.npmjs.com/package/$PACKAGE_NAME/staged"
    cd - > /dev/null || true
}

# Direct publish fallback (not used by CI). Prompts for your 2FA code.
publish() {
    local target=${1:-}
    local start_dir
    start_dir=$(pwd)

    if ! npm whoami >/dev/null 2>&1; then
        error "Not authenticated with npm. Run 'npm login' first, then try again."
    fi
    log "Authenticated with npm as $(npm whoami 2>/dev/null)"

    # Publish a staged tarball: ./build.sh publish path/to/cockpit-base1-1.2.3.tgz
    if [[ -n "$target" && -f "$target" ]]; then
        local dir name ver
        dir=$(dirname "$target")
        name=$(basename "$target")
        ver="${name##*-}"; ver="${ver%.tgz}"
        [[ "$name" == "$PACKAGE_NAME-"*.tgz ]] || error "Not a $PACKAGE_NAME tarball: $target"

        if npm view "$PACKAGE_NAME@$ver" version >/dev/null 2>&1; then
            warn "$PACKAGE_NAME@$ver is already published on npm - nothing to do"
            return 0
        fi

        cd "$dir" || error "Cannot enter $dir"
        log "Publishing $PACKAGE_NAME@$ver from $name. When prompted, enter your 2FA code from your authenticator app."
        npm publish "$name" --access public || error "npm publish failed (see message above)"
        log "Published $PACKAGE_NAME@$ver"
        cd "$start_dir" || true
        return 0
    fi

    # Fallback: publish whatever was built last
    [[ -d "$OUTPUT_DIR" ]] || error "Output directory $OUTPUT_DIR not found - build it first (e.g. ./build.sh stage $VERSION)"
    [[ -f "$OUTPUT_DIR/package.json" ]] || error "package.json not found in $OUTPUT_DIR"
    cd "$OUTPUT_DIR" || error "Cannot enter $OUTPUT_DIR"
    log "Publishing from $OUTPUT_DIR. When prompted, enter your 2FA code from your authenticator app."
    npm publish --access public || error "npm publish failed (see message above)"
    log "Published successfully"
    cd "$start_dir" || exit
}

# Function to clean up build artifacts
cleanup() {
    log "Cleaning up build artifacts"

    rm -f *.tar.xz
    rm -rf "$BUILD_DIR"
    rm -rf "$OUTPUT_DIR"
    rm -rf "staging"
}

# Function to run full build
full() {
    local version=${1:-$VERSION}
    local publish_flag=${2:-false}
    
    log "Starting full build for version $version"
    
    download "$version"
    extract "$version"
    configure-build
    install-deps
    install-build-deps
    build
    
    local next_version
    next_version=$(version "$version")
    
    package "$next_version"
    patch
    copy
    
    if [[ "$publish_flag" == "true" ]]; then
        publish
    fi
        
    log "Build completed successfully for version $version"
}

# Help function
show_help() {
    cat << EOF
Usage: $0 [COMMAND] [OPTIONS]

Commands:
    download [VERSION]              Download cockpit tarball
    extract [VERSION]               Extract tarball
    configure-build                 Configure build environment
    install-deps                    Install npm dependencies
    install-build-deps              Install build dependencies
    build                           Build cockpit
    patch                           Patch cockpit
    version [MAJOR] [PACKAGE]       Determine next npm version
    package [VERSION]               Build base package
    copy                            Copy additional files
    publish [TARBALL]              Publish to npm directly (requires 2FA prompt)
    stage [VERSION]                 Build + npm pack tarball (inspect only, no publish)
    stage-publish [VERSION]         Build + npm stage publish (staged registry, approve in browser)
    cleanup                         Clean up artifacts
    full [VERSION] [PUBLISH]        Run full build (PUBLISH=true to publish)
    help                            Show this help

Environment Variables:
    VERSION         Default version to use (default: 323)
    PACKAGE_NAME    NPM package name (default: cockpit-base1)
    BUILD_DIR       Build directory (default: build)
    OUTPUT_DIR      Output directory (default: cockpit)

Examples:
    $0 full 337                     # Full build for version 337
    $0 stage 323                  # Build and stage tarball for version 323
    $0 stage-publish 323          # Build + npm stage publish (approve in browser on npmjs.com)
    $0 publish staged/...tgz      # Publish a staged tarball (local, prompts 2FA)
    $0 download 337                # Just download version 337
    $0 version 323                 # Get next version for major 323
EOF
}

# Main script logic
case "${1:-}" in
    download)
        download "$2"
        ;;
    extract)
        extract "$2"
        ;;
    configure-build)
        configure-build
        ;;
    install-deps)
        install-deps
        ;;
    install-build-deps)
        install-build-deps
        ;;
    build)
        build
        ;;
    patch)
        patch
        ;;
    version)
        version "$2" "$3"
        ;;
    package)
        package "$2"
        ;;
    copy)
        copy
        ;;
    stage)
        stage "$2"
        ;;
    stage-publish)
        stage-publish "$2"
        ;;
    publish)
        publish
        ;;
    cleanup)
        cleanup
        ;;
    full)
        full "$2" "$3"
        ;;
    help|--help|-h)
        show_help
        ;;
    "")
        warn "No command specified. Use 'help' to see available commands."
        show_help
        ;;
    *)
        error "Unknown command: $1. Use 'help' to see available commands."
        ;;
esac
