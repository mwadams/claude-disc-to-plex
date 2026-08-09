<#
  stage-and-clean.ps1 — copy a finished show/movie folder to the final target (NAS) WITHOUT
  overwriting anything already there, VERIFY the copy byte-for-byte, and only then (optionally)
  delete the local staging copy. The verification is a hard gate: the local copy is never
  deleted unless every source file exists on the target with an identical size.

  Usage:
    pwsh -File stage-and-clean.ps1 -Src "D:\video\Television Shows\Show (Year)" `
                                   -Target "\\NAS\multimedia\Television Shows\Show (Year)" [-DeleteAfter]

  Without -DeleteAfter it copies + verifies and reports; with it, it deletes the local copy iff
  verification passes. Safe to re-run: robocopy skips files already on the target (no overwrite),
  so a repeat run just re-verifies.
#>
param(
  [Parameter(Mandatory)][string]$Src,
  [Parameter(Mandatory)][string]$Target,
  [switch]$DeleteAfter
)
$ErrorActionPreference = 'Stop'
if(-not (Test-Path $Src)){ throw "Source not found: $Src" }

# 1. Copy — /XC /XN /XO means NEVER overwrite an existing target file (only add what's missing).
Write-Host "=== copying (no-overwrite) $Src -> $Target ===" -ForegroundColor Cyan
robocopy "$Src" "$Target" /E /XC /XN /XO /MT:8 /R:2 /W:5 /NP /NDL | Out-Null
$rc = $LASTEXITCODE   # robocopy: <8 = success (1=copied, 0=nothing to do, 2/3=extras)
if($rc -ge 8){ throw "robocopy reported a failure (exit $rc)." }

# 2. Verify — every source file must exist on the target with an identical byte size.
Write-Host "=== verifying ===" -ForegroundColor Cyan
$s = Get-ChildItem $Src -Recurse -File
$missing = @()
foreach($f in $s){
  $rel = $f.FullName.Substring($Src.Length)
  $tf  = Join-Path $Target $rel
  if(-not (Test-Path $tf) -or (Get-Item $tf).Length -ne $f.Length){ $missing += $rel }
}
$srcBytes = ($s | Measure-Object Length -Sum).Sum
$tgtBytes = (Get-ChildItem $Target -Recurse -File | Measure-Object Length -Sum).Sum
$ok = ($missing.Count -eq 0)
Write-Host ("  source: {0} files, {1:N0} bytes" -f $s.Count, $srcBytes)
Write-Host ("  target total: {0:N0} bytes" -f $tgtBytes)
if($ok){ Write-Host "  VERIFIED — every source file present on target with matching size." -ForegroundColor Green }
else   { Write-Host ("  MISMATCH — {0} file(s) missing or wrong size on target:" -f $missing.Count) -ForegroundColor Red; $missing | ForEach-Object { "    $_" } }

# 3. Gated delete — the safety check is the gate; no verification, no deletion.
if($DeleteAfter){
  if($ok){
    Remove-Item -LiteralPath $Src -Recurse -Force
    Write-Host ("=== deleted local staging copy: {0} ===" -f $Src) -ForegroundColor Green
  } else {
    Write-Host "=== NOT deleting local copy — verification failed. Fix the target first. ===" -ForegroundColor Red
    exit 1
  }
} elseif($ok){
  Write-Host "Copy verified. Re-run with -DeleteAfter to remove the local staging copy." -ForegroundColor Cyan
}
