# Repository Guidelines

## Project Structure & Module Organization

`build.sh` orchestrates image builds. Scripts live in `scripts/`; runtime configuration, systemd units, NetworkManager profiles, and templates live in `configs/`. Prebuilt device trees are under `dtbs/`, while `src/` contains the `lk2nd`, `qhypstub`, `qtestsign`, `gt`, and `libusbgx` Git submodules. Executable Bash tests are in `tests/`, and `.github/workflows/` covers both supported hosts. Treat `build/`, `dist/`, `files/`, `mnt/`, `rootfs/`, and generated images or archives as disposable outputs.

## Build, Test, and Development Commands

- `git submodule update --init --recursive` populates the sources required for firmware and gadget-tool builds.
- `sudo ./build.sh` builds a generic Debian image on Ubuntu 22.04 AMD64 or Ubuntu 24.04 ARM64.
- `sudo env OPENSTICK_BOARD=ufi003 ./build.sh` creates a board-specific image; valid profiles are `ufi003` and `uz801`.
- `for test in tests/test-*.sh; do "$test"; done` runs the fast regression suite without building an image.
- `sudo scripts/install_deps.sh` installs host packages. `README.md` documents individual stages; artifacts appear in `files/`.

## Coding Style & Naming Conventions

Use four-space indentation in shell scripts. Keep production scripts POSIX `sh` unless a Bash feature is genuinely required; tests use Bash with `set -Eeuo pipefail`. Quote expansions, use uppercase names for exported configuration, and use lowercase snake_case for functions and local variables. Follow existing kebab-case filenames such as `openstick-board-profile.sh` and `test-image-configuration.sh`. Preserve accurate ShellCheck source and suppression comments.

## Testing Guidelines

Tests are self-contained shell programs; there is no coverage threshold. Run the full suite before submitting, plus a relevant image build when changing rootfs, bootloader, DTB, or packaging logic. Name new tests `tests/test-<behavior>.sh`, use temporary directories and command stubs, and avoid physical modem hardware or root access.

## Commit & Pull Request Guidelines

Use short, imperative commit subjects. Existing history commonly uses optional scopes such as `fix:`, `build:`, `docs:`, and `ci:`. Keep each commit focused. Pull requests should explain the affected build stage or device behavior, identify tested host architecture and board profile, list verification commands, link relevant issues, and include build logs or artifact checks when firmware output changes.

## Safety & Agent Workflow

Before editing, inspect the current branch, worktree, upstream, and ahead/behind state. Obtain approval before switching or creating branches or running fetch, pull, merge, rebase, reset, force-push, or discarding changes. Flashing commands can brick devices; keep device writes outside automated tests and never commit generated firmware or local backups.
