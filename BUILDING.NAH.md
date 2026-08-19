# Building NahSupport locally

## macOS (arm64)

CI (`build-macos-arm64` in `.github/workflows/nah-build.yml`) is the source of
truth. Local setup mirrors it:

1. **Xcode** (full app, not just CLT - the Flutter macOS build needs xcodebuild)
   and **Rosetta 2** (`softwareupdate --install-rosetta --agree-to-license` -
   Flutter 3.24.5's `gen_snapshot_arm64` is an x86_64 binary).
2. **Rust** stable with target `aarch64-apple-darwin` (CI pins 1.81; any recent
   stable works locally).
3. **Homebrew deps**: `brew install create-dmg nasm pkg-config cocoapods`
   (CocoaPods is preinstalled on the CI runners).
   CI uses NASM 2.16 from nasm.us (x86_64 + Rosetta); on a local Mac without
   Rosetta, brew's NASM 3.x is fine - arm64 aom never assembles x86 asm, the
   port just requires nasm to exist.
   Do NOT point bindgen at brew's llvm: libclang 22 makes bindgen 0.65 emit
   opaque `_address`-only structs and scrap fails with E0560. Use Xcode's
   libclang (below). CI gets away with `brew install llvm` because the keg is
   unlinked, so clang-sys falls back to the Xcode toolchain anyway.
4. **vcpkg** at the pinned commit, deps for `arm64-osx` (~25 min):
   ```bash
   git clone https://github.com/microsoft/vcpkg ~/vcpkg
   cd ~/vcpkg && git checkout 120deac3062162151622ca4860575a33844ba10b
   ./bootstrap-vcpkg.sh -disableMetrics
   # from the repo root (uses vcpkg.json):
   VCPKG_ROOT=~/vcpkg ~/vcpkg/vcpkg install --triplet arm64-osx \
     --x-install-root=~/vcpkg/installed
   ```
5. **Flutter 3.24.5** (same pin/breakage notes as Windows below). Extract the
   arm64 SDK zip, then apply both CI patches:
   ```bash
   cd <flutter>; git apply <repo>/.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff
   sed -i -e 's/_setFramesEnabledState(false);/\/\/_setFramesEnabledState(false);/g' \
     packages/flutter/lib/src/scheduler/binding.dart
   ```
6. **Bridge files**: download a CI `bridge-artifact` and drop the files in place
   (adds `flutter/macos/Runner/bridge_generated.h` on top of the four Windows
   ones).
7. `git submodule update --init --recursive` on a fresh clone.

**Build** (produces `flutter/build/macos/Build/Products/Release/NAHSupport.app`
with the `service` binary copied in; the dmg step in build.py is commented out):

```bash
export PATH=<flutter>/bin:$PATH VCPKG_ROOT=~/vcpkg
export LIBCLANG_PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib
export NAH_RENDEZVOUS_SERVER=... NAH_RS_PUB_KEY=... NAH_API_BASE=...   # see README.NAH
./build.py --flutter --hwcodec --unix-file-copy-paste --screencapturekit
# Unsigned builds MUST be re-signed plain ad-hoc or dyld refuses to load
# FlutterMacOS.framework (hardened-runtime ad-hoc = library validation on):
codesign --force --deep --sign - flutter/build/macos/Build/Products/Release/NAHSupport.app
```

**Dmg** (what CI runs):

```bash
create-dmg --volname "NAHSupport" --window-pos 200 120 --window-size 800 400 \
  --icon-size 100 --icon "NAHSupport.app" 200 190 --hide-extension "NAHSupport.app" \
  --app-drop-link 600 185 NahSupport.dmg \
  flutter/build/macos/Build/Products/Release/NAHSupport.app
```

To test session registration, rename the dmg to `NahSupport-<code>.dmg`, mount
it and launch the app from the mounted volume (the code is recovered from the
backing dmg's filename via `hdiutil info`).

### Signed release (local - the primary macOS release path)

`./nah-release-macos.sh` runs the whole chain: build -> Developer ID codesign
(inside-out, hardened runtime, Release.entitlements) -> create-dmg ->
`notarytool submit --wait` -> staple -> `spctl` verify. The CI macOS job is
dispatch-only (macOS runners bill at 10x and drain the free Actions allowance)
and runs the same steps.

One-time: import the Developer ID .p12 (1Password: "Nutty About Hosting -
macOS Developer ID Signing") into the login keychain. Per run:

```bash
export NAH_RENDEZVOUS_SERVER=... NAH_RS_PUB_KEY=... NAH_API_BASE=...
export APPLE_API_KEY_P8=~/path/AuthKey_XXXX.p8 APPLE_API_KEY_ID=XXXX APPLE_API_ISSUER_ID=...
./nah-release-macos.sh                      # NahSupport.dmg (support flavor)
NAH_FLAVOR=technician ./nah-release-macos.sh  # NahSupportTechnician.dmg
```

The p12 password and .p8 live in 1Password; the .p8 is an App Store Connect
API key (Users and Access -> Integrations -> Team Keys, role Developer).

The macOS AppIcon is generated from `flutter/assets/icon.svg`; regenerate with
sharp + `iconutil` into `flutter/macos/Runner/AppIcon.icns` if the logo changes
(same treatment as `nah-assets/gen-icons.js`: centered, ~12% padding).

## Windows

CI (`.github/workflows/nah-build.yml`) is the source of truth and produces the
signed, shippable artifacts. These notes are for building on a dev machine to
iterate faster than the ~40-minute CI cycle.

### Prerequisites (one-time)

1. **Rust** (MSVC toolchain) + target `x86_64-pc-windows-msvc`.
2. **Visual Studio** with the C++ workload (provides MSVC + the Windows SDK /
   UCRT headers). Any recent VS edition works.
3. **vcpkg** with the native codec deps built for `x64-windows-static`:
   ```bash
   git clone https://github.com/microsoft/vcpkg C:/vcpkg
   cd C:/vcpkg && git checkout 120deac3062162151622ca4860575a33844ba10b
   ./bootstrap-vcpkg.bat
   # from the repo root (uses vcpkg.json):
   VCPKG_ROOT=C:/vcpkg ./vcpkg.exe install --triplet x64-windows-static \
     --x-install-root=C:/vcpkg/installed
   ```
   (~25 min; builds ffmpeg, aom, libvpx, libyuv, opus.)
4. **libclang** for bindgen. If you can't install full LLVM (needs admin),
   the pip package provides just the DLL:
   ```bash
   pip install libclang   # -> .../site-packages/clang/native/libclang.dll
   ```
   The pip package does **not** ship clang's builtin resource headers
   (`stddef.h` etc). Get them by extracting an LLVM release with 7-Zip (no
   install needed) - only `lib/clang/<ver>/include` is required:
   ```bash
   curl -fsSL -o llvm.exe \
     https://github.com/llvm/llvm-project/releases/download/llvmorg-18.1.8/LLVM-18.1.8-win64.exe
   "C:/Program Files/7-Zip/7z.exe" x llvm.exe -oLLVM "lib/clang/18/include/*"
   ```

### Building the Rust core (librustdesk.dll)

Must run inside a **VS developer environment** (sets `INCLUDE` to the UCRT +
Windows SDK header paths - without it bindgen's clang can't find `stdlib.h`).

```bat
call "C:\Program Files\Microsoft Visual Studio\<ver>\<ed>\VC\Auxiliary\Build\vcvars64.bat"
set VCPKG_ROOT=C:\vcpkg
set LIBCLANG_PATH=C:\Python\Python313\Lib\site-packages\clang\native
:: Forward slashes! BINDGEN_EXTRA_CLANG_ARGS is shell-word split and eats
:: backslashes on Windows, so a C:\... path silently corrupts.
set BINDGEN_EXTRA_CLANG_ARGS=-isystem C:/path/to/LLVM/lib/clang/18/include
cargo build --lib
```

Produces `target/debug/librustdesk.dll` - the core the Flutter UI links against.

### Building the full Flutter desktop app locally (VERIFIED - fast UI loop)

Reproduced end to end on Windows + VS 2026. Once set up, UI edits hot-reload in
seconds; only Rust changes need the ~30s `cargo build`.

**One-time setup:**

1. **Flutter 3.24.5** (the version CI pins - a newer Flutter breaks: DialogTheme
   was renamed to DialogThemeData, and extended_text / google_fonts break).
   Download the SDK zip and extract somewhere, e.g. `C:\flutter-3245`:
   `flutter_windows_3.24.5-stable.zip` from the Flutter release storage.
2. **VS 2026 generator patch.** Flutter 3.24.5's VS->CMake-generator switch only
   knows up to VS 2022, so VS 2026 (major 18) falls through to "Visual Studio 16
   2019" and CMake can't find it. Add the VS 2026 case in
   `<flutter>/packages/flutter_tools/lib/src/windows/visual_studio.dart`
   (`cmakeGenerator` getter):
   ```dart
   18 => 'Visual Studio 18 2026',
   ```
   Then delete `<flutter>/bin/cache/flutter_tools.stamp` so the tool recompiles.
   (Only needed while VS 2026 is newer than what Flutter 3.24.5 knows.)
3. **Bridge files.** Reuse a CI `bridge-artifact` instead of installing the
   codegen tool - download it and drop the four files in place:
   `flutter/lib/generated_bridge.dart`, `flutter/lib/generated_bridge.freezed.dart`,
   `src/bridge_generated.rs`, `src/bridge_generated.io.rs` (all gitignored).

**Build + run:**

```bat
:: 1. Rust lib WITH the flutter feature (in a VS dev shell, env as above):
cargo build --lib --features flutter        :: -> target/debug/librustdesk.dll

:: 2. Flutter app (uses the patched 3.24.5; VS-bundled CMake supports VS 2026):
set PATH=C:\flutter-3245\flutter\bin;%PATH%
cd flutter
flutter pub get
flutter build windows --debug               :: -> build/windows/x64/runner/Debug/rustdesk.exe
:: CMake copies librustdesk.dll next to the exe automatically.
```

For the fast UI loop use `flutter run -d windows` instead of `build`, then press
`r` for hot reload after Dart edits. `dart analyze <file>` is a good pre-build
check (catches Dart errors in ~1s without a full build).

### Gotchas learned

- `BINDGEN_EXTRA_CLANG_ARGS` with backslash paths -> silently mangled. Use `/`.
- pip `libclang` has no resource headers -> `stddef.h not found`. Add
  `-isystem <llvm>/lib/clang/<ver>/include`.
- Not in a VS dev shell -> `stdlib.h not found`. Run under `vcvars64.bat`.
- Flutter newer than 3.24.5 -> DialogTheme/TabBarTheme + package breakage. Pin 3.24.5.
- Flutter 3.24.5 + VS 2026 -> wrong CMake generator. Patch visual_studio.dart (above).
- Stale `flutter/build/windows` CMake cache after switching VS/Flutter ->
  "generator does not match"; `rm -rf flutter/build/windows` and rebuild.
