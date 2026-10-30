#!/usr/bin/env bash
#
# build-macos.sh — Build GpgFrontend natively on macOS (Apple Silicon or Intel)
#
# Produces a runnable GpgFrontend.app you build yourself from source — no .dmg,
# no Docker, no code signing. Derived from the project's own CI (.github/
# workflows/build.yml) and CMake logic.
#
# Uses the Xcode generator (-G Xcode): the project's src/CMakeLists.txt only
# sets MACOSX_BUNDLE / Info.plist / icon on the app target when
# CMAKE_GENERATOR is "Xcode" (see CMakeLists.txt:28, XCODE_BUILD). With Ninja
# or Unix Makefiles it silently falls back to building a bare CLI-style
# executable — no .app is ever produced. Requires the full Xcode.app
# (`xcodebuild -version`), not just the Command Line Tools.
#
# Usage:
#   cd /path/to/GpgFrontend
#   ./build-macos.sh
#
# Optional env toggles:
#   BUILD_TYPE=RelWithDebInfo   # or Release / Debug (default matches CI)
#   STATIC_GPGME=1              # self-contained static gpgme (like the release)
#                              # default 0 = link Homebrew's gpgme (simpler)
#   BUILD_MODE=release          # or nightly. release shares the "GpgFrontend"
#                              # profile with official builds; nightly gets a
#                              # separate "GpgFrontendTesting" profile and name
#
set -euo pipefail

BUILD_TYPE="${BUILD_TYPE:-RelWithDebInfo}"
STATIC_GPGME="${STATIC_GPGME:-0}"
BUILD_MODE="${BUILD_MODE:-release}"
JOBS="$(sysctl -n hw.logicalcpu)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- 0. Sanity checks ---------------------------------------------------------
[[ "$(uname -s)" == "Darwin" ]] || die "This script is for macOS only."
[[ -f CMakeLists.txt && -d third_party/gpgme ]] || \
  die "Run this from the root of the GpgFrontend checkout."

command -v brew >/dev/null || die "Homebrew not found. Install from https://brew.sh"
xcode-select -p >/dev/null 2>&1 || die "Xcode Command Line Tools missing. Run: xcode-select --install"
xcodebuild -version >/dev/null 2>&1 || die "Full Xcode.app not found (the CLI tools alone aren't enough for -G Xcode). Install Xcode from the App Store, then: sudo xcode-select -s /Applications/Xcode.app"

# --- 1. Dependencies (Homebrew) ----------------------------------------------
# Build tools + autotools (for the vendored gpgme chain) + libs + gnupg runtime.
# Only install what's actually missing -- 'brew install' on an already-current
# formula is a harmless no-op, but checking first skips the network/resolve
# overhead for a dozen formulae on every run.
REQUIRED_FORMULAE=(
  cmake ninja ccache pkg-config
  autoconf automake libtool texinfo gettext
  qt libarchive libsodium googletest gnupg gpgme openssl@3
)
MISSING_FORMULAE=""
for f in "${REQUIRED_FORMULAE[@]}"; do
  brew list --versions "$f" >/dev/null 2>&1 || MISSING_FORMULAE+="$f "
done
if [[ -n "${MISSING_FORMULAE}" ]]; then
  log "Installing missing Homebrew dependencies: ${MISSING_FORMULAE}"
  # shellcheck disable=SC2086
  brew install $MISSING_FORMULAE
else
  log "All Homebrew dependencies already installed."
fi

QT_PREFIX="$(brew --prefix qt)"
OPENSSL_PREFIX="$(brew --prefix openssl@3)"
export CMAKE_PREFIX_PATH="${QT_PREFIX}${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"

# --- 2. Rust toolchain (needed by corrosion for the rPGP backend) ------------
if ! command -v rustc >/dev/null 2>&1; then
  log "Rust not found — installing via rustup..."
  brew list rustup >/dev/null 2>&1 || brew install rustup
  # rustup is keg-only (it conflicts with the separate 'rust' formula), so its
  # bin dir isn't symlinked into the Homebrew prefix -- put it on PATH here.
  RUSTUP_PREFIX="$(brew --prefix rustup)"
  export PATH="${RUSTUP_PREFIX}/bin:${PATH}"
  rustup default stable
fi
command -v rustc >/dev/null || die "rustc still not on PATH. Add \"$(brew --prefix rustup)/bin\" to PATH and rerun."
log "Using $(rustc --version)"

# --- 3. Submodules ------------------------------------------------------------
log "Syncing git submodules (gpgme, libassuan, libgpg-error, corrosion, ...)"
git submodule update --init --recursive

# --- 4. Configure -------------------------------------------------------------
CMAKE_ARGS=(
  -B build -G Xcode
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}"
  -DCMAKE_PREFIX_PATH="${QT_PREFIX}"
  -DOPENSSL_ROOT_DIR="${OPENSSL_PREFIX}"
  # "installed" = normal /Applications app with data in the usual user
  # locations; deliberately not "sandbox" (that flavor moves key databases
  # into the app container and drops GnuPG/gpg-agent integration).
  -DGPGFRONTEND_BUILD_FLAVOR=installed
  -DGPGFRONTEND_BUILD_MODE="${BUILD_MODE}"
)
if [[ "${STATIC_GPGME}" == "1" ]]; then
  # This flag => third_party/CMakeLists.txt ExternalProject builds
  # libgpg-error/libassuan/gpgme statically and links them into the core.
  log "Configuring with STATIC gpgme (self-contained, like the official release)"
  CMAKE_ARGS+=( -DGPGFRONTEND_LINK_GPGME_INTO_CORE=ON )
else
  log "Configuring against Homebrew gpgme (simpler; app depends on brew gpgme)"
fi

log "cmake ${CMAKE_ARGS[*]}"
cmake "${CMAKE_ARGS[@]}"

# --- 5. Build -----------------------------------------------------------------
# Xcode is a multi-config generator: BUILD_TYPE only takes effect via --config
# here (the earlier -DCMAKE_BUILD_TYPE feeds the vendored autotools/corrosion
# sub-builds, which aren't multi-config aware).
#
# The trailing xcodebuild settings disable signing, mirroring upstream CI's
# unsigned build job: src/CMakeLists.txt bakes a team, identity and profile
# specifier into the project, and Xcode would otherwise try to resolve them.
log "Building with ${JOBS} parallel jobs (first build is slow — Qt + Rust + gpgme)"
cmake --build build --config "${BUILD_TYPE}" --parallel "${JOBS}" -- \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER=""

# --- 6. Locate the app bundle -------------------------------------------------
APP="$(find build -maxdepth 4 -name 'GpgFrontend.app' -type d | head -n1 || true)"
[[ -n "${APP}" ]] || die "Build finished but no GpgFrontend.app was found under build/. Check the build log."

log "Built: ${APP}"

# --- 7. Bundle Qt so it runs standalone --------------------------------------
# Without this the .app can't find Qt frameworks unless launched from a shell
# that has Qt on the library path. macdeployqt copies them in.
if [[ -x "${QT_PREFIX}/bin/macdeployqt" ]]; then
  log "Deploying Qt frameworks into the bundle (macdeployqt)..."
  "${QT_PREFIX}/bin/macdeployqt" "${APP}" -verbose=1 || \
    log "macdeployqt reported issues — the app may still run from this shell. See hints."
fi

cat <<EOF

--------------------------------------------------------------------------------
Done. To run:

    open "${APP}"

If macOS Gatekeeper blocks it (unsigned): right-click the app > Open, or
    xattr -dr com.apple.quarantine "${APP}"

Requires GnuPG at runtime — installed above via 'brew install gnupg' (gpg).
--------------------------------------------------------------------------------

TROUBLESHOOTING
  * "No CMAKE_CXX_COMPILER could be found" / xcodebuild plugin dlopen errors
    during configure: Xcode's simulator/toolchain components are out of date
    for this Xcode version. Run once:
        xcodebuild -runFirstLaunch
  * "makeinfo: command not found" during the gpgme chain (STATIC_GPGME=1):
        brew link --force texinfo   # texinfo is keg-only
  * CMake can't find Qt:  echo "\$CMAKE_PREFIX_PATH"  should point at $(brew --prefix qt)
  * Rust errors from corrosion:  ensure rustup's bin dir is on PATH, e.g.
        export PATH="$(brew --prefix rustup)/bin:\$PATH"   then rerun.
  * gpgme not found (STATIC_GPGME=0):  ensure 'brew install gpgme' succeeded and
        'pkg-config --exists gpgme && echo ok' prints ok.
  * Switching generators (e.g. you built before this script used Xcode):
    CMake refuses to reconfigure an existing cache with a different
    generator, so a clean rebuild is required, not just a re-run.
  * Clean slate:  rm -rf build && ./build-macos.sh
EOF
