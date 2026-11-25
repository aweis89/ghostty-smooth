# pcode fork helpers. Upstream's Makefile is left alone so rebases stay clean.
#
# Pcode.app is built from the pcode repo now: its Swift lives in app/macos
# there, and app/scripts/build.sh copies it into this fork at the commit in
# app/ghostty.lock. These recipes only point there.

default:
    @just --list

# Moved: build and install Pcode.app from the pcode repo.
install:
    @echo "Pcode.app is built from the pcode repo now: run 'make app' in its main checkout." >&2
    @echo "To try this checkout's Zig changes with it: GHOSTTY_SRC=$(pwd) make app" >&2
    @exit 1

# Moved: make app-status in the pcode repo.
status: install

# Moved: make app-restart in the pcode repo.
restart: install
