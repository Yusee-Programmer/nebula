# Bakes a TTF into a fixed 8x14 bitmap glyph atlas, emitted as compiled-in
# Tauraro source (toolkit/text/font_data.tr). Each pixel stores a 0-16
# COVERAGE LEVEL, not a single bit -- the same 16-level scale
# toolkit.ui.interp's fill_circle_aa/paint_rounded_rect_aa already blend
# against for circles and rounded corners (mix_color(fg, bg, coverage)),
# so text uses that exact same blend function with zero new code there.
# (2026-09-05: this used to threshold to 1 bit/pixel -- see git history if
# you need the old format. Blocky hard-edged letterforms at an 8x14 cell
# were the single most visible "not smooth" thing in the whole toolkit, more
# than any rounded corner; this is the fix.)
#
#   .\scripts\bake-font.ps1
#
# WHY a baked bitmap atlas rather than parsing the TTF on-device: Tauraro's
# stdlib has no font/curve-rasterizer support at all (confirmed by searching
# std/ -- see CLAUDE.md), and real TTF glyph outlines are quadratic Bezier
# curves that want float or fixed-point scanline rasterization -- a large,
# risky undertaking to write from scratch and get correct on the freestanding
# tiers, which have no filesystem to load a .ttf from at runtime anyway. A
# baked bitmap atlas turns "render text" into a lookup + blend: no curve
# math, no float dependency at USE time (only at BAKE time, here, offline, in
# .NET), and it is IDENTICAL and equally safe on all four tiers (hosted,
# Cortex-M, UEFI, SDL2), because it is just data -- a coverage byte per pixel
# is exactly as portable as the old coverage bit was.
#
# The technique: render each glyph supersampled (4x) with real antialiasing
# via GDI+, then box-downsample each 4x4 block down to one 0-16 coverage
# level per output pixel -- this looks far better at 8x14 than rendering
# directly at 8x14 with hinting would, and MUCH better than a hard 1-bit
# threshold of the same supersampled data (which is what this script used to
# do -- the antialiasing information was already being computed and then
# thrown away at the last step).
#
# Source font: tools/fonts/JetBrainsMono.ttf (SIL OFL 1.1 -- see the adjacent
# JetBrainsMono-OFL.txt). Covers ASCII 32 (space) through 126 (~), 95 glyphs.

param(
    [string]$FontPath = "tools\fonts\JetBrainsMono.ttf",
    [string]$OutTr    = "toolkit\text\font_data.tr",
    [string]$PreviewPng = "tools\fonts\preview.png",
    [int]$CellW = 8,
    [int]$CellH = 14,
    [int]$Supersample = 4
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

if (-not (Test-Path $FontPath)) { throw "no such font file: $FontPath" }

$sw = $CellW * $Supersample
$sh = $CellH * $Supersample

# New-Object's parenthesized "TypeName(args)" shorthand only reliably
# evaluates bare variables inside the parens, not expressions or enum
# member-access chains -- see tau_bugs.txt on ppm-to-png.ps1 for the same
# bug found once already. Using -ArgumentList explicitly everywhere here
# avoids relying on which forms happen to work.
$pfc = New-Object -TypeName System.Drawing.Text.PrivateFontCollection
$pfc.AddFontFile((Resolve-Path $FontPath).Path)
$family = $pfc.Families[0]
Write-Host "loaded font family: $($family.Name)"

# --- Derive a font pixel-size that makes the monospace advance width match
#     our supersampled cell width exactly, rather than guessing a point size.
$probeSize = 64.0
$probeFontStyle = [System.Drawing.FontStyle]::Regular
$probeUnit = [System.Drawing.GraphicsUnit]::Pixel
$probeFont = New-Object -TypeName System.Drawing.Font -ArgumentList $family, ([float]$probeSize), $probeFontStyle, $probeUnit
$probeBmp = New-Object -TypeName System.Drawing.Bitmap -ArgumentList 1, 1
$probeGfx = [System.Drawing.Graphics]::FromImage($probeBmp)
$genericTypographic = [System.Drawing.StringFormat]::GenericTypographic
$fmt = New-Object -TypeName System.Drawing.StringFormat -ArgumentList $genericTypographic
$fmt.FormatFlags = $fmt.FormatFlags -bor [System.Drawing.StringFormatFlags]::MeasureTrailingSpaces
$advance = $probeGfx.MeasureString("M", $probeFont, [System.Drawing.PointF]::new(0, 0), $fmt).Width
$probeGfx.Dispose(); $probeBmp.Dispose(); $probeFont.Dispose()

$fontSize = $probeSize * ($sw / $advance)
Write-Host "derived font pixel size: $([math]::Round($fontSize, 2)) (target advance ${sw}px, measured ${advance}px @ ${probeSize}px)"

$font = New-Object -TypeName System.Drawing.Font -ArgumentList $family, ([float]$fontSize), $probeFontStyle, $probeUnit

# Vertical placement: center the font's design ascent+descent band within the
# supersampled cell height, using the family's own design-unit metrics scaled
# to this font size -- not a guessed offset.
$emHeight = $family.GetEmHeight([System.Drawing.FontStyle]::Regular)
$ascent = $family.GetCellAscent([System.Drawing.FontStyle]::Regular)
$lineSpacing = $family.GetLineSpacing([System.Drawing.FontStyle]::Regular)
$scale = $fontSize / $emHeight
$scaledLineSpacing = $lineSpacing * $scale
$scaledAscent = $ascent * $scale
$baselineY = [math]::Max(0, ($sh - $scaledLineSpacing) / 2.0 + $scaledAscent)

# --- Render + downsample each glyph -----------------------------------------

$first = 32
$count = 95   # through 126 inclusive
$glyphBytes = New-Object 'System.Collections.Generic.List[byte]'  # count * CellH bytes

# For the human-readable verification preview.
$previewCols = 16
$previewRows = [math]::Ceiling($count / $previewCols)
$previewW = $previewCols * ($CellW + 1)
$previewH = [int]($previewRows * ($CellH + 1))
$preview = New-Object -TypeName System.Drawing.Bitmap -ArgumentList $previewW, $previewH
Write-Host "preview canvas: $($preview.Width) x $($preview.Height)"
$pgfx = [System.Drawing.Graphics]::FromImage($preview)
$pgfx.Clear([System.Drawing.Color]::FromArgb(30, 30, 30))

for ($gi = 0; $gi -lt $count; $gi++) {
    $ch = [char]($first + $gi)

    $bmp = New-Object -TypeName System.Drawing.Bitmap -ArgumentList $sw, $sh
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    $gfx.Clear([System.Drawing.Color]::Black)
    $gfx.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $gfx.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
    $brush = [System.Drawing.Brushes]::White
    $gfx.DrawString([string]$ch, $font, $brush, [System.Drawing.PointF]::new(0, [float]($baselineY - $scaledAscent)), $fmt)
    $gfx.Dispose()

    for ($row = 0; $row -lt $CellH; $row++) {
        for ($col = 0; $col -lt $CellW; $col++) {
            $sum = 0
            for ($sy = 0; $sy -lt $Supersample; $sy++) {
                for ($sx = 0; $sx -lt $Supersample; $sx++) {
                    $px = $bmp.GetPixel($col * $Supersample + $sx, $row * $Supersample + $sy)
                    $sum += $px.R   # white text on black -- R channel is coverage
                }
            }
            # 0-255 average -> 0-16 coverage level, the same scale
            # toolkit.ui.interp.mix_color already blends circles/rounded
            # corners against -- text reuses that exact function unchanged.
            $avg = $sum / ($Supersample * $Supersample)
            $level = [math]::Round($avg * 16 / 255)
            if ($level -gt 16) { $level = 16 }
            $glyphBytes.Add([byte]$level)

            if ($level -gt 0) {
                [int]$pcol = $gi % $previewCols
                [int]$prow = [math]::Floor($gi / $previewCols)
                [int]$px2 = $pcol * ($CellW + 1) + $col
                [int]$py2 = $prow * ($CellH + 1) + $row
                if ($px2 -ge 0 -and $px2 -lt $preview.Width -and $py2 -ge 0 -and $py2 -lt $preview.Height) {
                    [int]$shade = [math]::Round($level * 255 / 16)
                    $preview.SetPixel($px2, $py2, [System.Drawing.Color]::FromArgb($shade, $shade, $shade))
                }
            }
        }
    }
    $bmp.Dispose()
}

$pgfx.Dispose()
New-Item -ItemType Directory -Force (Split-Path $PreviewPng) | Out-Null
$preview.Save($PreviewPng, [System.Drawing.Imaging.ImageFormat]::Png)
$preview.Dispose()
Write-Host "wrote preview: $PreviewPng"

$font.Dispose()
$pfc.Dispose()

# --- Emit toolkit/text/font_data.tr -----------------------------------------

$sb = New-Object System.Text.StringBuilder
[void]$sb.Append("# toolkit.text.font_data -- GENERATED FILE, do not hand-edit.`n")
[void]$sb.Append("#`n")
[void]$sb.Append("# Baked from tools/fonts/JetBrainsMono.ttf (SIL OFL 1.1, see the adjacent`n")
[void]$sb.Append("# JetBrainsMono-OFL.txt) by scripts/bake-font.ps1. Regenerate with that script,`n")
[void]$sb.Append("# never by editing this file directly.`n")
[void]$sb.Append("#`n")
[void]$sb.Append("# One glyph is $($CellW * $CellH) consecutive bytes, row-major, ONE BYTE PER`n")
[void]$sb.Append("# PIXEL: a 0-16 coverage level (0 = fully background, 16 = fully foreground,`n")
[void]$sb.Append("# values between are a real antialiased edge), the same scale`n")
[void]$sb.Append("# toolkit.ui.interp.mix_color() already uses for circles/rounded corners.`n")
[void]$sb.Append("# Glyph index = codepoint - font_first_char(); byte offset = glyph_index *`n")
[void]$sb.Append("# ($CellW * $CellH) + row * $CellW + col.`n")
[void]$sb.Append("`n")
[void]$sb.Append("pub def font_cell_w() -> int:`n    return $CellW`n`n")
[void]$sb.Append("pub def font_cell_h() -> int:`n    return $CellH`n`n")
[void]$sb.Append("pub def font_first_char() -> int:`n    return $first`n`n")
[void]$sb.Append("pub def font_glyph_count() -> int:`n    return $count`n`n")
[void]$sb.Append("pub def font_coverage() -> List[u8]:`n    return [")

for ($i = 0; $i -lt $glyphBytes.Count; $i++) {
    if ($i -gt 0) { [void]$sb.Append(", ") }
    [void]$sb.Append("$($glyphBytes[$i]) as u8")
}
[void]$sb.Append("]`n")

New-Item -ItemType Directory -Force (Split-Path $OutTr) | Out-Null
[System.IO.File]::WriteAllText((Join-Path (Get-Location) $OutTr), $sb.ToString())

Write-Host ""
Write-Host "wrote $OutTr" -ForegroundColor Green
Write-Host "  $($glyphBytes.Count) bytes, $count glyphs, ${CellW}x${CellH} cells"
