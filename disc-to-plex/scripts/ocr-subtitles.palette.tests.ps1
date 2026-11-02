<#
  Tests for ocr-subtitles.ps1's Repair-VobSubPalette (2026-11-02).
  Run: pwsh -File ocr-subtitles.palette.tests.ps1     (exit 0 = all passed)

  Batman (1989): the disc authors BLANK cues (SET_COLOR 0000, SET_CONTRAST 0000). One came first, so
  colour was read from it and contrast from a later cue - every index mapped to black, the repair
  saw "no anti-alias" and did nothing, and 988 cues of clean English OCR'd at 1%. Colour and contrast
  must come from the SAME visible cue. The function is loaded from the script by AST, so the test
  exercises the shipped code. Fixtures are synthetic SPU packets in an MPEG-PS wrapper: a row of
  2 fill (index 1 -> entry 9), 1 anti-alias (index 2 -> entry 8), 2 outline (index 3 -> entry 0).
#>
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'ocr-subtitles.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('ocrpal-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$pass = 0; $fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { $script:pass++; Write-Host "  PASS  $name" } else { $script:fail++; Write-Host "  FAIL  $name`n        $detail" }
}
$tk = $null; $er = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tk, [ref]$er)
$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Repair-VobSubPalette' }, $true)
Invoke-Expression $fn.Extent.Text

# One SPU: 8x2 bitmap, both rows the same: (2 x idx1)(1 x idx2)(2 x idx3)(3 x idx0) = nibbles 9 6 B C.
function New-Spu([byte]$col1, [byte]$col2, [byte]$con1, [byte]$con2, [byte[]]$row = @(0x96, 0xBC)) {
  $pix = [byte[]]($row + $row)                 # field 0 row, then field 1 row
  $off0 = 4; $off1 = 4 + $row.Length
  $dcsqAt = 4 + $pix.Length
  $cmds = [byte[]](@(0x03, $col1, $col2), @(0x04, $con1, $con2),
                   @(0x05, 0x00, 0x00, 0x07, 0x00, 0x00, 0x01),      # x 0..7, y 0..1
                   @(0x06, 0x00, $off0, 0x00, $off1), @(0x01), @(0xFF) | ForEach-Object { $_ })
  $dcsq = [byte[]](@(0x00, 0x00, [byte]($dcsqAt -shr 8), [byte]($dcsqAt -band 255)) + $cmds)
  $size = 4 + $pix.Length + $dcsq.Length
  return [byte[]](@([byte]($size -shr 8), [byte]($size -band 255), [byte]($dcsqAt -shr 8), [byte]($dcsqAt -band 255)) + $pix + $dcsq)
}
# Wrap one SPU in a pack header + private_stream_1 PES, padded to a 2 KB sector.
function New-Sector([byte[]]$spu) {
  $pack = [byte[]](0x00, 0x00, 0x01, 0xBA, 0x44, 0, 4, 0, 4, 1, 1, 0x89, 0xC3, 0xF8)
  $plen = 3 + 1 + $spu.Length
  $pes = [byte[]](@(0x00, 0x00, 0x01, 0xBD, [byte]($plen -shr 8), [byte]($plen -band 255), 0x81, 0x00, 0x00, 0x20) + $spu)
  $sec = New-Object byte[] 2048
  [Array]::Copy($pack, 0, $sec, 0, $pack.Length)
  [Array]::Copy($pes, 0, $sec, $pack.Length, $pes.Length)
  return $sec
}
$palette = 'palette: 000000, 818181, 818181, 818181, 818181, 818181, 818181, fefefe, 818181, b9b9b9, 818181, 818181, 818181, 818181, 818181, 818181'
function New-Track([string]$name, [object[]]$spus) {
  $idx = Join-Path $root "$name.idx"; $sub = [IO.Path]::ChangeExtension($idx, '.sub')
  $bytes = New-Object System.Collections.Generic.List[byte]
  $lines = @('# VobSub index file, v7', 'size: 720x576', $palette, 'id: en, index: 0')
  $n = 0
  foreach ($s in $spus) { $lines += ('timestamp: 00:00:0{0}:000, filepos: {1:x9}' -f ($n + 1), $bytes.Count); $bytes.AddRange([byte[]](New-Sector $s)); $n++ }
  [IO.File]::WriteAllLines($idx, [string[]]$lines)
  [IO.File]::WriteAllBytes($sub, $bytes.ToArray())
  return $idx
}
function Entry([string]$idx, [int]$e) { ((Get-Content -LiteralPath $idx | Where-Object { $_ -match '^palette:' }) -replace '^palette:\s*', '' -split ',')[$e].Trim() }
try {
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  $blank = New-Spu 0x00 0x00 0x00 0x00
  $real  = New-Spu 0x08 0x90 0xFF 0xF0          # idx3->0, idx2->8, idx1->9, idx0->0; contrast 15,15,15,0

  Write-Host '1. REAL (Batman): a blank cue first, then real cues'
  $i = New-Track 'batman' @($blank, $real, $real)
  $r = Repair-VobSubPalette -IdxPath $i
  Check 'the repair fires' ($r -match 'merged into #b9b9b9') "returned [$r]"
  Check 'the anti-alias entry (8) is repainted to the fill' ((Entry $i 8) -eq 'b9b9b9') (Entry $i 8)
  Check 'the outline entry (0) is untouched' ((Entry $i 0) -eq '000000') (Entry $i 0)

  Write-Host '2. the same disc without the blank cue - unchanged behaviour'
  $i = New-Track 'plain' @($real, $real)
  Check 'repaired the same way' ((Repair-VobSubPalette -IdxPath $i) -match 'merged into #b9b9b9' -and (Entry $i 8) -eq 'b9b9b9')

  Write-Host '3. known-negative: only blank cues - nothing visible, nothing repaired'
  $i = New-Track 'blank' @($blank, $blank)
  Check 'returns nothing' ($null -eq (Repair-VobSubPalette -IdxPath $i))
  Check 'palette untouched' ((Entry $i 8) -eq '818181')

  Write-Host '4. known-negative: no anti-alias ink (below the 0.15 weight) - left alone, blank cue first or not'
  # One two-nibble run 0x21 = (8 << 2) | 1: the whole 8-wide row is fill, no anti-alias pixel at all.
  $thin = New-Spu 0x08 0x90 0xFF 0xF0 @(0x21)
  $i = New-Track 'thin' @($blank, $thin, $thin)
  $rt = Repair-VobSubPalette -IdxPath $i
  Check 'no repair when anti-alias is a token share of the fill' ($null -eq $rt -and (Entry $i 8) -eq '818181') "returned [$rt], entry 8 = $(Entry $i 8)"
}
catch { Write-Host "  FAIL exception: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"; $fail++ }
finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ("{0} passed, {1} failed" -f $pass, $fail)
if ($fail) { exit 1 }
Write-Host 'all tests passed'
exit 0
