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
    
    cd "$BUILD_DIR" && npm ci || error "Failed to install npm dependencies"
    cd - > /dev/null
}

# Function to install TypeScript globally
install-ts() {
    log "Installing TypeScript globally"
    
    if command -v tsc &> /dev/null; then
        warn "TypeScript already installed, skipping"
    else
        npm install -g typescript || error "Failed to install TypeScript"
    fi
}

# Function to build cockpit
build() {
    log "Building cockpit"
    
    [[ -d "$BUILD_DIR" ]] || error "Build directory $BUILD_DIR not found"
    
    cd "$BUILD_DIR" && node build.js || error "Failed to build cockpit"
    cd - > /dev/null
}

# Function to determine next npm version
version() {
    local major=${1:-$VERSION}
    local package=${2:-$PACKAGE_NAME}
    
    # Get all published versions for this major
    local versions
    versions=$(npm view "$package" versions --json 2>/dev/null | jq -r ".[]" | grep "^$major\.[0-9]\+\.[0-9]\+$" || true)
    
    local next_version
    if [[ -z "$versions" ]]; then
        next_version="$major.0.1"
    else
        # Find the highest minor
        local max_minor
        max_minor=$(echo "$versions" | awk -F. '{print $2}' | sort -n | tail -1)
        # Find the highest patch for that minor
        local max_patch
        max_patch=$(echo "$versions" | grep "^$major\.$max_minor\.[0-9]\+$" | awk -F. '{print $3}' | sort -n | tail -1)
        local next_patch=$((max_patch + 1))
        next_version="$major.$max_minor.$next_patch"
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
    
    # Convert TypeScript files to ESM
    for file in "$OUTPUT_DIR/lib/"*.ts; do
        if [[ -f "$file" ]]; then
            tsc "$file" --outDir "$OUTPUT_DIR/lib" --declaration false --esModuleInterop --noEmitOnError false || warn "TypeScript compilation failed for $file"
            rm -f "$file"
        fi
    done
    
    # Convert TSX files to ESM
    for file in "$OUTPUT_DIR/lib/"*.tsx; do
        if [[ -f "$file" ]]; then
            tsc "$file" --outDir "$OUTPUT_DIR/lib" --declaration false --esModuleInterop --noEmitOnError false --jsx react || warn "TSX compilation failed for $file"
            rm -f "$file"
        fi
    done
    
    # Create package.json
    local base_package="{\"name\": \"$PACKAGE_NAME\", \"version\": \"$next_version\", \"main\": \"index.mjs\", \"type\": \"module\", \"license\": \"MIT\"}"
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
}

# Function to copy additional files
copy() {
    log "Copying additional files"
    
    [[ -f "README.md" ]] && cp README.md "$OUTPUT_DIR/" || warn "README.md not found"
}

# Function to publish to npm
publish() {
    log "Publishing package to npm"
    
    [[ -d "$OUTPUT_DIR" ]] || error "Output directory $OUTPUT_DIR not found"
    [[ -f "$OUTPUT_DIR/package.json" ]] || error "package.json not found in $OUTPUT_DIR"
    
    cd "$OUTPUT_DIR" && npm publish --access public || error "Failed to publish package"
    cd - > /dev/null
}

# Function to clean up build artifacts
cleanup() {
    log "Cleaning up build artifacts"

    rm -f *.tar.xz
    rm -rf "$BUILD_DIR"
    rm -rf "$OUTPUT_DIR"
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
    install-ts
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
    install-ts                      Install TypeScript globally
    build                           Build cockpit
    patch                           Patch cockpit
    version [MAJOR] [PACKAGE]       Determine next npm version
    package [VERSION]               Build base package
    copy                            Copy additional files
    publish                         Publish to npm
    cleanup [VERSION]               Clean up artifacts
    full [VERSION] [PUBLISH]        Run full build (PUBLISH=true to publish)
    help                            Show this help

Environment Variables:
    VERSION         Default version to use (default: 323)
    PACKAGE_NAME    NPM package name (default: cockpit-base1)
    BUILD_DIR       Build directory (default: build)
    OUTPUT_DIR      Output directory (default: cockpit)

Examples:
    $0 full 337                     # Full build for version 337
    $0 full 323 true               # Full build for version 323 with publishing
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
    install-ts)
        install-ts
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
