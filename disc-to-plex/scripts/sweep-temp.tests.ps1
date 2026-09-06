<#
  Tests for sweep-temp.ps1. Run: pwsh -NoProfile -File sweep-temp.tests.ps1   (exit 0 = all passed)

  WHAT THESE HAVE TO PROVE:
    - BOTH separators are swept. `cards_11464` and `card-502e0c07` are made by different scripts
      (verify-title-cards.ps1 uses `_`, read-card.ps1 uses `-`), and the first version of the
      allowlist matched literal 'cards-' and therefore walked straight past seven `cards_NNNNN`
      directories while reporting success. A sweep that misses silently is worse than one that
      errors, so this is the headline case;
    - the age gates are SEPARATE and correctly sized - evidence scratch in hours, ad-hoc agent dirs
      in hours, scratchpads in days. Sizing evidence at the -Days rule made the sweep list none of
      the 18 orphans it existed to remove;
    - `tasks\` is never touched, at any age - the harness reads those back by path;
    - directories that are not ours are never touched, whatever their age or size;
    - a live session's recent scratchpad files survive while its stale ones go;
    - -WhatIf removes nothing.
  Everything runs against a sandbox temp root; the real D:\temp is never involved.
#>
$ErrorActionPreference = 'Stop'
$script:fails = 0
function Check($name, $got, $want) {
  if ("$got" -eq "$want") { Write-Output "  ok   $name" }
  else { Write-Output "  FAIL $name - got '$got', want '$want'"; $script:fails++ }
}

$script = Join-Path $PSScriptRoot 'sweep-temp.ps1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('sweeptemp-' + [guid]::NewGuid().ToString('N'))
$root = Join-Path $tmp 'temp'

function NewDir([string]$rel, [datetime]$age, [int]$bytes = 1024) {
  $p = Join-Path $root $rel
  New-Item -ItemType Directory -Path $p -Force | Out-Null
  $f = Join-Path $p 'payload.bin'
  [IO.File]::WriteAllBytes($f, [byte[]]::new($bytes))
  (Get-Item -LiteralPath $f).LastWriteTime = $age
  (Get-Item -LiteralPath $p).LastWriteTime = $age
  return $p
}
function Exists([string]$rel) { Test-Path -LiteralPath (Join-Path $root $rel) }
function Run([string[]]$extra) {
  # -Temp is honoured, so the sandbox stands in for D:\temp. The script's own guard requires the
  # resolved root to start with D:\temp, so these tests set -Temp to a path under it.
  $a = @('-NoProfile', '-File', $script, '-Temp', $root) + $extra
  $o = & pwsh @a 2>&1 | ForEach-Object { "$_" }
  [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($o -join "`n") }
}

try {
  New-Item -ItemType Directory -Path $root -Force | Out-Null
  $old  = (Get-Date).AddDays(-5)
  $recent = (Get-Date)

  # THE REGRESSION. Both separators, both must go.
  NewDir 'cards_11464'      $old | Out-Null
  NewDir 'card-502e0c07'    $old | Out-Null
  NewDir 'capture-evidence-8248-96118492' $old | Out-Null
  NewDir 'disposition-evidence-780b5beb'  $old | Out-Null
  NewDir 'seconv_ocr_5b2b603e'            $old | Out-Null
  # NOT ours, at the same age - must survive.
  NewDir 'scoped_dir_9f2'   $old | Out-Null
  NewDir 'chrome_drag123'   $old | Out-Null
  NewDir 'bp2w1glh'         $old | Out-Null
  NewDir 'tmpljusiy6o'      $old | Out-Null
  # Recent evidence scratch - a LIVE run must not have its working directory taken.
  NewDir 'capture-evidence-999-live'      $recent | Out-Null

  $r = Run @()
  Check 'cards_ (underscore) swept'         (Exists 'cards_11464') 'False'
  Check 'card- (hyphen) swept'              (Exists 'card-502e0c07') 'False'
  Check 'capture-evidence swept'            (Exists 'capture-evidence-8248-96118492') 'False'
  Check 'disposition-evidence swept'        (Exists 'disposition-evidence-780b5beb') 'False'
  Check 'seconv_ocr swept'                  (Exists 'seconv_ocr_5b2b603e') 'False'
  Check 'scoped_dir NOT ours - survives'    (Exists 'scoped_dir_9f2') 'True'
  Check 'chrome_drag NOT ours - survives'   (Exists 'chrome_drag123') 'True'
  Check 'VS installer cache survives'       (Exists 'bp2w1glh') 'True'
  Check 'bare tmp<random> survives'         (Exists 'tmpljusiy6o') 'True'
  Check 'a LIVE evidence dir survives'      (Exists 'capture-evidence-999-live') 'True'
  Check 'exit 0'                            $r.Code 0

  # ---- session scratchpads, and the thing that must never be touched ----------------------------
  $sess = 'claude/D--video/91319c72-9b1d-4137-b9ce-50c482a7a9fd'
  NewDir "$sess/scratchpad/stale" $old    | Out-Null
  NewDir "$sess/scratchpad/fresh" $recent | Out-Null
  NewDir "$sess/tasks"            $old    | Out-Null      # old AND in a live session: still sacred
  $r = Run @()
  Check 'stale scratchpad file swept'       (Exists "$sess/scratchpad/stale/payload.bin") 'False'
  Check 'recent scratchpad file survives'   (Exists "$sess/scratchpad/fresh/payload.bin") 'True'
  Check 'tasks/ is NEVER swept'             (Exists "$sess/tasks/payload.bin") 'True'

  # ---- ad-hoc agent working directories ----------------------------------------------------------
  # Aged in HOURS: dead when its agent finished. Under the -Days rule these survived at 1.73 GB.
  NewDir 'claude/ghostwatch'      (Get-Date).AddHours(-20) | Out-Null
  NewDir 'claude/still-working'   (Get-Date).AddHours(-1)  | Out-Null
  $r = Run @()
  Check 'stale ad-hoc agent dir swept'      (Exists 'claude/ghostwatch') 'False'
  Check 'recent ad-hoc agent dir survives'  (Exists 'claude/still-working') 'True'
  Check 'the project dir is NOT swept as ad-hoc' (Exists 'claude/D--video') 'True'

  # ---- -WhatIf ------------------------------------------------------------------------------------
  NewDir 'cards_99999' $old | Out-Null
  $r = Run @('-WhatIf')
  Check 'WhatIf removes nothing'            (Exists 'cards_99999') 'True'
  Check 'WhatIf says what it would do'      ($r.Out -like '*WOULD*cards_99999*') 'True'

  $script:reachedEnd = $true
}
catch { Write-Output "  FAIL exception: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"; $script:fails++ }
finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
Write-Output ''
if (-not $reachedEnd) { Write-Output 'the suite did not reach its end - treating as FAILED'; $fails++ }
if ($fails) { Write-Output "$fails test(s) FAILED"; exit 1 }
Write-Output 'all tests passed'
exit 0
