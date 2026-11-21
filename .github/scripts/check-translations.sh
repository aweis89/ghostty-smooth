#!/usr/bin/env bash

set -euxo pipefail

old=$(mktemp -d)
cp po/*.po po/com.mitchellh.ghostty.pot "$old"/
zig build update-translations

# Compare previous POT to current POT
msgcmp "$old"/com.mitchellh.ghostty.pot po/com.mitchellh.ghostty.pot --use-untranslated

# Compare committed POs (before regeneration) to current POT
for f in "$old"/*.po; do
  # Ignore untranslated entries
  msgcmp --use-untranslated "$f" po/com.mitchellh.ghostty.pot;
done
