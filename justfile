# pcode fork helpers. Upstream's Makefile is left alone so rebases stay clean.

# List recipes.
default:
    @just --list

# Build the macOS app (ReleaseFast) and install it as builds/current.
install:
    scripts/install-macos.sh --build

# Install the last build again without rebuilding.
reinstall:
    scripts/install-macos.sh

# Show whether this terminal and running instances are on the latest build.
status:
    @scripts/status.sh

# Trash old builds/pcode-*.app bundles, keeping current and any running one.
prune *args:
    scripts/prune-builds.sh {{args}}

# Build, install, then prune the old bundles.
refresh: install prune
