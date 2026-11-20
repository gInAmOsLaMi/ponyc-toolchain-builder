# ponyc-toolchain-builder

A cross-platform POSIX build script that compiles and installs three side-by-side `ponyc` compiler toolchains (plus self-hosted tools) from source in a single automated run, reusing the vendored LLVM build across all configurations.

## Features

- **OS, Distro & Architecture Auto-Detection:** Automatically configures CMake presets, compilers, bitcode (`-DPONY_RUNTIME_BITCODE`), and flags for Linux, FreeBSD, OpenBSD, DragonFly BSD, and macOS.
- **Smart Dependency Verification & Auto-Install:** Checks for required CLI tools and dev headers and installs missing packages automatically via system package managers (`apt`, `dnf`, `pacman`, `apk`, `zypper`, `pkg`, `pkg_add`, `brew`).
- **Dynamic CMake Scanner & 13-Stage Progress UI:** Reads `cmake/PonyUses.cmake` at runtime, displays 13-stage progress bars (`[1/13]` to `[13/13]`), handles self-healing LLVM caches, and supports both interactive and unattended CI environments (`INTERACTIVE=0`).

## Included Toolchains & Binaries

| Command | Sanitizer & Instrumentation Flags | Primary Use Case |
| :--- | :--- | :--- |
| **`ponyc-asan`** | `address_sanitizer`, `pool_memalign`, `undefined_behavior_sanitizer`, `coverage`, `systematic_testing`, `runtimestats`, `runtimestats_messages`, `reach_instrument` (`LTO=OFF`) | Detecting memory corruption, leaks, and UB |
| **`ponyc-tsan`** | `thread_sanitizer`, `undefined_behavior_sanitizer`, `coverage`, `systematic_testing`, `runtimestats`, `runtimestats_messages`, `reach_instrument` (`LTO=OFF`) | Detecting data races and sync issues |
| **`ponyc`** | Clean release preset (`PONY_USE_LTO=ON`, no sanitizers) | Production and release builds with LTO |
| **`pony-lsp` / `pony-lint` / `pony-doc`** | Self-hosted tools built with `PONY_THIN_LTO=1` | IDE language server, linter, and docs generator |

## Usage

1. Clone the official `ponyc` source repository with submodules:
   ```bash
   git clone --recurse-submodules https://github.com/gInAmOsLaMi/ponyc-toolchain-builder.git
   cd ponyc
   ```

2. Download `build-ponyc-suite.sh` into the root of the `ponyc` directory and run it:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/gInAmOsLaMi/ponyc-toolchain-builder/refs/heads/main/build-ponyc-suite.sh -o build-ponyc-suite.sh
   chmod +x build-ponyc-suite.sh
   ./build-ponyc-suite.sh
   ```
*(Tip: Override variables like `PREFIX_BASE` or `BIN_DIR` for user-local installations without `sudo`. For full parameter tables and extended options, refer to your script implementation.)*

## Acknowledgments

- Built for the [Pony programming language](https://ponylang.io) and the official [`ponylang/ponyc`](https://github.com/ponylang/ponyc) compiler.
- Build flags, sanitizer combinations, and platform presets are derived from the official [Building `ponyc` from Source](https://www.ponylang.io/contribute/compiler/building-ponyc-from-source/) and [Custom `ponyc` Builds](https://ponylang.io/use/compiler/custom-ponyc-builds/) documentation.
- Special thanks to the **Pony Developers & Contributors** for maintaining the CMake presets and `PonyUses.cmake` build infrastructure.

