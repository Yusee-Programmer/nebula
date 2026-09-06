#!/usr/bin/env bash
# Regenerates toolkit/ui/palette.tr from scripts/tailwind-palette.txt.
#
# The palette is 22 hues x 11 shades = 242 colors. Hand-writing that many hex
# literals into Tauraro source is a transcription-error machine -- one wrong
# nibble in the middle of it renders as a plausible-but-wrong color that no
# test would catch -- so the values live in one flat data table and this
# script emits the code. Same reasoning as scripts/bake-font.ps1: generated
# data belongs in a generated file.
#
#   ./scripts/gen-palette.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DATA=scripts/tailwind-palette.txt
OUT=toolkit/ui/palette.tr

{
cat <<'HDR'
# toolkit.ui.palette — GENERATED. Do not edit by hand.
#
# Regenerate with scripts/gen-palette.sh (data: scripts/tailwind-palette.txt).
#
# The full Tailwind color palette: 22 hues x 11 shades (50, 100..900, 950),
# packed 0x00RRGGBB, the same encoding toolkit.types.rgb() produces and every
# Canvas backend writes directly.
#
# This module imports NOTHING on purpose. toolkit.ui.style imports it, and
# Tauraro rejects circular imports, so it cannot import style's own unset()
# sentinel back -- it re-declares the identical value as no_color() instead.
# The two must stay equal; they are both "-1", and there is a compile-checked
# assertion of that in style.tr's resolve_color_token.

# Same value as toolkit.ui.style.unset(). See the note above for why this is
# a second declaration rather than an import.
pub def no_color() -> int:
    return 0 - 1

# Shade index for a Tailwind shade number, or -1 if it is not one of the
# eleven real steps. Callers use this to tell "bg-blue-500" (a shade) from
# "bg-blue-foo" (a typo) before doing any lookup.
pub def shade_index(shade: int) -> int:
    if shade == 50: return 0
    if shade == 100: return 1
    if shade == 200: return 2
    if shade == 300: return 3
    if shade == 400: return 4
    if shade == 500: return 5
    if shade == 600: return 6
    if shade == 700: return 7
    if shade == 800: return 8
    if shade == 900: return 9
    if shade == 950: return 10
    return 0 - 1

# One hue + one shade number -> packed color, or no_color() for an unknown
# hue or a shade that is not a real Tailwind step. Bare `bg-blue` (no shade)
# is handled by the caller, which substitutes 500 -- Tailwind's own default.
pub def color_shade(hue: str, shade: int) -> int:
    mut i = shade_index(shade)
    if i < 0:
        return no_color()
HDR

while read -r hue s50 s100 s200 s300 s400 s500 s600 s700 s800 s900 s950; do
  [ -z "$hue" ] && continue
  echo ""
  echo "    if hue == \"$hue\":"
  n=0
  for v in "$s50" "$s100" "$s200" "$s300" "$s400" "$s500" "$s600" "$s700" "$s800" "$s900" "$s950"; do
    up=$(echo "$v" | tr 'a-f' 'A-F')
    echo "        if i == $n: return 0x$up"
    n=$((n+1))
  done
  echo "        return no_color()"
done < "$DATA"

cat <<'FTR'

    return no_color()
FTR
} > "$OUT"

echo "wrote $OUT ($(wc -l < "$OUT") lines, $(grep -c 'return 0x' "$OUT") colors)"
