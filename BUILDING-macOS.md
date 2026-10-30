# Building GpgFrontend on macOS (this fork)

This fork tracks [saturneric/GpgFrontend](https://github.com/saturneric/GpgFrontend)
and adds one thing: `build-macos.sh`, a script that builds a working,
self-contained `GpgFrontend.app` on your own Mac from source. It does not need
an Apple Developer account, Docker, or a code-signing certificate.

The result is a build trusted only by the machine that built it. It is meant
for personal use, not redistribution.

## Why this build is not sandboxed

Upstream can build an App Sandbox flavor (`GPGFRONTEND_BUILD_FLAVOR=sandbox`)
for the Mac App Store. This script deliberately builds the `installed` flavor
instead, because the sandbox:

- moves key databases into the app's container, which macOS can delete along
  with the app;
- cuts the app off from `~/.gnupg`, the system `gpg-agent`, and smart cards
  (YubiKey and similar), which the GnuPG workflow and Git commit signing rely on;
- needs entitlements tied to the upstream maintainer's Apple Team ID, which a
  local build cannot use.

Keys stay in `~/.gnupg`, owned by GnuPG, exactly where the `gpg` command line
tool expects them.

## Requirements

Tested on the setup below. Newer versions usually work. When something
breaks, the cause is most often an Xcode or Qt upgrade (see
[Troubleshooting](#troubleshooting)).

| Component | Tested version | Notes |
| --------- | -------------- | ----- |
| macOS | 26.7, Apple Silicon | Intel: Homebrew is in `/usr/local` |
| Xcode | 27.0 | The full Xcode.app, not just the Command Line Tools |
| Homebrew | current | <https://brew.sh> |
| Rust | 1.97.1 via `rustup` | Builds the rPGP engine (corrosion) |

### Homebrew formulae

The script installs any that are missing. Versions are what this fork was last
built and verified with:

| Formula | Tested version | Used for |
| ------- | -------------- | -------- |
| `cmake` | 4.4.5 | Build system (3.24 or newer required) |
| `ninja` | 1.13.2 | Vendored sub-builds |
| `ccache` | 4.14.2 | Compiler cache |
| `pkg-config` (`pkgconf`) | 3.0.10 | Library discovery |
| `autoconf` | 2.73 | Vendored libgpg-error / libassuan / gpgme chain |
| `automake` | 1.19 | Same |
| `libtool` | 2.6.2 | Same |
| `texinfo` | 7.3 | Same (`makeinfo`) |
| `gettext` | 1.0 | Same |
| `qt` | 6.12.0 | UI toolkit (upstream CI pins 6.11.3) |
| `libarchive` | 3.8.10 | Archive support |
| `libsodium` | 1.0.22 | Core crypto helpers, IM module |
| `openssl@3` | 3.5.9 | Email module TLS |
| `googletest` | 1.18.0 | Unit tests (optional build) |
| `gnupg` | 2.5.24 | The `gpg` / `gpg-agent` runtime the app drives |
| `gpgme` | 2.2.0 | GnuPG Made Easy, linked by default |

To match the upstream CI's Qt exactly, install Qt 6.11.3 with the
[Qt online installer](https://www.qt.io/download-qt-installer) or `aqtinstall`,
then point `CMAKE_PREFIX_PATH` at it.

## First-time setup

```sh
# Xcode: install from the App Store, then select it and finish its setup
sudo xcode-select -s /Applications/Xcode.app
xcodebuild -runFirstLaunch

# Clone this fork with its submodules
git clone --recursive https://github.com/x5j4d0/GpgFrontend.git
cd GpgFrontend
git remote add upstream https://github.com/saturneric/GpgFrontend.git
```

## Build

From the repository root:

```sh
./build-macos.sh
```

The first build takes a while because it compiles Qt-heavy C++, the Rust rPGP
backend, and the module set. Later runs are incremental.

Optional environment toggles:

| Variable | Default | Effect |
| -------- | ------- | ------ |
| `BUILD_TYPE` | `RelWithDebInfo` | Or `Release` / `Debug` |
| `BUILD_MODE` | `release` | `nightly`: separate "Testing" app and profile |
| `STATIC_GPGME` | `0` | `1`: static vendored gpgme, like releases |

Example:

```sh
BUILD_TYPE=Release STATIC_GPGME=1 ./build-macos.sh
```

The app lands at `build/RelWithDebInfo/RelWithDebInfo/GpgFrontend.app`. The
path follows `BUILD_TYPE`.

### What the script does

1. Checks for macOS, Homebrew, and the full Xcode, then installs missing formulae.
2. Makes sure Rust is available, installing `rustup` if needed.
3. Syncs all git submodules.
4. Configures with CMake's Xcode generator: `BUILD_FLAVOR=installed`,
   `BUILD_MODE=release`, and OpenSSL from Homebrew.
5. Builds with code signing disabled.
6. Stages the module tree (`cmake --install`, runtime component).
7. Rewrites Homebrew Qt references in module libraries to `@rpath` (see below),
   then runs upstream's `scripts/bundle_macos_module_deps.sh` to pull private
   dependencies (OpenSSL, libsodium) into each module.
8. Places modules in the bundle: descriptors under `Contents/Resources/modules`,
   code under `Contents/Frameworks/GpgFrontendModules`.
9. Runs `macdeployqt` for the app and every module library.
10. Runs upstream's `scripts/verify_macos_bundle_modules.sh`. The build fails if
    any module would not load.
11. Seals the bundle with an ad-hoc signature.

Steps 6 to 10 mirror the macOS packaging in upstream's
`.github/workflows/build.yml`.

### The Homebrew Qt fix

Homebrew's Qt links by absolute path (`<brew prefix>/opt/qtbase/lib/...`),
while the Qt that upstream CI uses links via `@rpath`. Upstream's dependency
bundler leaves `@rpath` references alone but treats absolute paths as private
dependencies. With Homebrew Qt, that means it would copy a second QtCore next
to every module, and the modules would then fail to load. The script rewrites
those references to `@rpath` first, so every module shares the app's single Qt
in `Contents/Frameworks`.

### Ad-hoc signing

Apple Silicon refuses to run any binary that has no signature at all. The script
signs with `codesign --sign -` ("ad-hoc"), which involves no certificate or
identity and is trusted by nothing but the local machine. `spctl` reports such
an app as "rejected", and `amfid` logs it as "adhoc signed". Both are expected
and harmless for an app you built yourself, since locally built files carry no
quarantine flag.

## Verify and install

```sh
APP=build/RelWithDebInfo/RelWithDebInfo/GpgFrontend.app

# Version and build info
"$APP/Contents/MacOS/GpgFrontend" -v

# Module smoke test, the same one upstream CI runs.
# Expect: discovered 6, loaded 6, refused 0
"$APP/Contents/MacOS/GpgFrontend" --module-status /tmp/gf-modules.json

# Install: quit GpgFrontend first, keep the previous copy as a rollback
mv /Applications/GpgFrontend.app ~/GpgFrontend-previous.app
ditto "$APP" /Applications/GpgFrontend.app
```

Quit the app, and don't click its Dock icon, while installing. During the
`mv` / `ditto` window the bundle is missing or half-copied, and macOS reports
"The application GpgFrontend.app can't be opened". Launching again after the
copy finishes works.

## Version shown in the app

The About dialog and `GpgFrontend -v` report the **upstream** commit this fork
is based on, not the fork's own `HEAD`. For example:

```text
Git Branch: v2.2.4-8-gb9023dc0
Source Code Information: upstream_v2.2.4-8-gb9023dc0
```

That reads as "upstream release v2.2.4, plus 8 upstream commits, at
`b9023dc0`". This needs an `upstream` remote and a recent `git fetch
upstream`. Without one, the app reports the fork's `HEAD` as usual. Set
`-DGPGFRONTEND_UPSTREAM_REF=` (empty) to always report `HEAD`. The internal
build ID, which module verification relies on, always uses the real `HEAD`.

## Your data

- **Keys** live in `~/.gnupg`, owned by GnuPG. GpgFrontend also keeps its
  `gf_keydb.sqlite` there.
- **Profile and settings** live in
  `~/Library/Application Support/BKTUS/GpgFrontend`, shared with official
  release builds.
- **Nightly-mode profile** (only with `BUILD_MODE=nightly`) lives in
  `~/Library/Application Support/BKTUS/GpgFrontendTesting`.

Back up `~/.gnupg` before running a build that is much newer than your last
one. New versions can upgrade the profile format, after which older builds may
not be able to read it.

## Keeping the fork current

```sh
git fetch upstream --tags
git switch main
git merge --ff-only upstream/main   # this fork's main only adds commits on top
git submodule sync --recursive
git submodule update --init --recursive --force
./build-macos.sh
```

If `--ff-only` refuses, `main` has commits of its own. Rebase them onto
`upstream/main` instead.

## Branches

- **`main`**: upstream plus `build-macos.sh`, this document, and `.gitignore`
  additions.
- **`devcontainer-edits`**: a repaired `.devcontainer/` (Debian, Qt 6, Rust,
  noVNC desktop) for Linux development and testing, plus the same macOS
  script. Upstream removed its devcontainer in August 2026.

## Troubleshooting

### After an Xcode upgrade

Configure fails with "No CMAKE_CXX_COMPILER could be found" or xcodebuild
plugin errors. Finish Xcode's setup, then do a clean build:

```sh
xcodebuild -runFirstLaunch
rm -rf build && ./build-macos.sh
```

### Switching generators or a stale build directory

CMake refuses to reconfigure a cache made with a different generator or a much
older CMake. Use `rm -rf build` to start fresh.

### A submodule file always shows as modified

Older commits of the `modules` submodule tracked two translation files whose
names differ only in letter case (`it_IT.ts` and `it_iT.ts`). macOS file
systems are case-insensitive, so one always looks modified and blocks submodule
checkout. Current upstream has fixed this. If you hit it on an old checkout:

```sh
git submodule update --init --recursive --force
```

### `makeinfo: command not found` (with `STATIC_GPGME=1`)

`texinfo` is keg-only:

```sh
brew link --force texinfo
```

### CMake cannot find Qt

`CMAKE_PREFIX_PATH` must include the Qt prefix (`brew --prefix qt`).

### Rust errors from corrosion

Put rustup's toolchain on `PATH`:

```sh
export PATH="$(brew --prefix rustup)/bin:$PATH"
```

### Module verification fails ("do not resolve in the bundle")

Some module dependency isn't inside the app. The script stops instead of
installing a bundle whose modules macOS would refuse at load time. Check the
FAIL lines: Qt frameworks point at a Qt deployment problem (step 7 or 9), and
other libraries at `bundle_macos_module_deps.sh`.

### `invalidateFilter is deprecated` warnings

These come from Qt 6.12, newer than what upstream CI builds against. They are
harmless.
