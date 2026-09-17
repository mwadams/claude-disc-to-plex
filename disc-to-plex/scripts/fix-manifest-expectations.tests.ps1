<#
.SYNOPSIS
  Tests for fix-manifest-expectations.ps1 against tiny generated media. Exit 0 = all passed.
#>
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'fix-manifest-expectations.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('fme-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { Write-Host "  PASS  $name" } else { $script:fail++; Write-Host "  FAIL  $name`n$detail" }
}
try {
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  $ff = (Get-Content 'D:/video/.transcode-tools/tool-paths.json' -Raw | ConvertFrom-Json).ffmpeg
  # Two silent-video sources of known length: 10 s and 30 s.
  $a = Join-Path $root 'a.mkv'; $b = Join-Path $root 'b.mkv'
  & $ff -v error -f lavfi -i 'color=c=black:s=320x240:r=25' -t 10 -y $a
  & $ff -v error -f lavfi -i 'color=c=black:s=320x240:r=25' -t 30 -y $b
  $m = Join-Path $root 'm.json'

  function Write-Manifest($rows) { Set-Content -LiteralPath $m -Value (ConvertTo-Json -InputObject @($rows) -Depth 6) -Encoding UTF8 }
  function Run([switch]$WhatIf) {
    $args2 = @($script, '-Manifest', $m); if ($WhatIf) { $args2 += '-WhatIf' }
    $o = @(& pwsh -NoProfile -File @args2 2>&1 | ForEach-Object { "$_" })
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($o -join "`n"); Rows = @(Get-Content -LiteralPath $m -Raw | ConvertFrom-Json) }
  }

  Write-Host 'the clerical class is corrected'
  Write-Manifest @(@{ out = 'x/A.mkv'; src = ($a -replace '\\', '/'); kind = 'MKV'; expectSeconds = 9.04 })
  $r = Run
  Check 'exit 0' ($r.Code -eq 0) $r.Text
  Check 'expectSeconds now the container duration' ([math]::Abs([double]$r.Rows[0].expectSeconds - 10.0) -le 0.2) ($r.Rows[0].expectSeconds)
  Check 'the original is kept beside it' (Test-Path -LiteralPath ($m + '.before-expectations-fix'))

  Write-Host 'a row already correct is left alone'
  Write-Manifest @(@{ out = 'x/A.mkv'; src = ($a -replace '\\', '/'); kind = 'MKV'; expectSeconds = 10.0 })
  $r = Run
  Check 'exit 0, nothing corrected' ($r.Code -eq 0 -and $r.Text -match '0 row\(s\) corrected') $r.Text

  Write-Host 'a WRONG SOURCE is never silently fixed'
  # 30 s source, row claims 10 s: 20 s out - the "this row names the wrong title" class.
  Write-Manifest @(@{ out = 'x/B.mkv'; src = ($b -replace '\\', '/'); kind = 'MKV'; expectSeconds = 10.0 })
  $r = Run
  Check 'exit 2' ($r.Code -eq 2) $r.Text
  Check 'says it was left alone' ($r.Text -match 'LEFT ALONE, past the') $r.Text
  Check 'the row is UNCHANGED' ([double]$r.Rows[0].expectSeconds -eq 10.0) ($r.Rows[0].expectSeconds)

  Write-Host 'WhatIf writes nothing'
  Write-Manifest @(@{ out = 'x/A.mkv'; src = ($a -replace '\\', '/'); kind = 'MKV'; expectSeconds = 9.04 })
  $r = Run -WhatIf
  Check 'exit 0 and the row is untouched' ($r.Code -eq 0 -and [double]$r.Rows[0].expectSeconds -eq 9.04) $r.Text

  Write-Host 'rows this must not touch'
  Write-Manifest @(
    @{ out = 'x/S.mkv'; src = ($a -replace '\\', '/'); kind = 'STILLS'; expectSeconds = 3.0 },
    @{ out = 'x/T.mkv'; src = ($a -replace '\\', '/'); kind = 'DVD'; title = 4; expectSeconds = 3.0 },
    @{ out = 'x/F.mkv'; src = ($root -replace '\\', '/'); kind = 'DVD'; expectSeconds = 3.0 }
  )
  $r = Run
  Check 'STILLS, titled and folder rows are all skipped' ($r.Code -eq 0 -and $r.Text -match '0 row\(s\) corrected.*0 measurable') $r.Text
  Check 'expectFrames is never touched' ($r.Text -notmatch 'expectFrames')
}
finally {
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
if ($fail) { Write-Host "$fail test(s) FAILED"; exit 1 }
Write-Host 'all tests passed'
exit 0
