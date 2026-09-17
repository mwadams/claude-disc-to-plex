<#
.SYNOPSIS
  Tests for apply-srt-corrections.py - the cue-anchored path and the `"cue": "all"` recurring-name
  path, against a scratch transcript and a scratch lexicon (never D:/video/_lexicons).
  Exit 0 = all passed.
#>
$ErrorActionPreference = 'Stop'
$py = Join-Path $PSScriptRoot 'apply-srt-corrections.py'
$root = Join-Path ([IO.Path]::GetTempPath()) ('asc-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { Write-Host "  PASS  $name" } else { $script:fail++; Write-Host "  FAIL  $name`n$detail" }
}

try {
  $show = 'Test Show (1965)'
  $season = Join-Path $root "lib/$show/Season 01"
  $lex = Join-Path $root 'lex'
  $corpus = Join-Path $root 'corpus/Other Show/Season 01'
  New-Item -ItemType Directory -Force -Path $season, (Join-Path $lex $show), (Join-Path $root 'orig'), $corpus | Out-Null
  # Another show's dialogue: 'revenge' is ordinary lowercase English there; no Bly/Blythe at all.
  Set-Content -LiteralPath (Join-Path $corpus 'x.srt') -Value ((1..6 | ForEach-Object { "$_`n00:00:0$_,000 --> 00:00:0$_,500`nthey swore revenge on him`n" }) -join "`n")
  Set-Content -LiteralPath (Join-Path $lex "$show/_show.json") -Value (@{ work = 'Test Show'; characters = @('Caswell Bligh', 'Kenneth Bligh', 'Sir John Wilder', 'Sir Gordon Revidge'); terms = @(); fixes = @{} } | ConvertTo-Json)

  $cues = @(
    'Good morning, Mr. Bly.',                 # 1
    "We're meeting at Bly's tomorrow.",       # 2
    'Mr. Kerris Bly is late again.',          # 3
    'Blythe will not like it.',               # 4
    'A blight on the whole business.',        # 5  ordinary word - must never be swept
    'Ask Blyton, he knows.',                  # 6  a different name containing Bly - must not change
    'Sir John Wilder said so.',               # 7
    'Revenge is a dish best served cold.'     # 8  sentence-initial ORDINARY word, capitalised
  )
  $srt = Join-Path $season "$show - S01E01 - Pilot.eng.srt"
  $body = for ($i = 0; $i -lt $cues.Count; $i++) { "{0}`n00:00:{1:D2},000 --> 00:00:{2:D2},000`n{3}`n" -f ($i + 1), ($i * 3), ($i * 3 + 2), $cues[$i] }
  $original = ($body -join "`n")

  function Run($fixes, [switch]$DryRun) {
    Set-Content -LiteralPath $srt -Value $original -NoNewline
    $fx = Join-Path $root 'fixes.json'
    Set-Content -LiteralPath $fx -Value (ConvertTo-Json -InputObject @($fixes) -Depth 4)
    # A 7-cue transcript trips the 15% cue cap on any fix at all; the cap is not what is tested here.
    $args2 = @($py, $srt, '--corrections', $fx, '--backup-dir', (Join-Path $root 'orig'), '--lexicon-dir', $lex, '--corpus-dir', (Join-Path $root 'corpus'), '--max-change-pct', '100')
    if ($DryRun) { $args2 += '--dry-run' }
    $o = @(& python @args2 2>&1 | ForEach-Object { "$_" })
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($o -join "`n"); Text = (Get-Content -LiteralPath $srt -Raw) }
  }

  Write-Host 'recurring-name corrections'
  $r = Run @(
    @{ cue = 'all'; from = 'Bly'; to = 'Bligh'; why = 'cast surname' },
    @{ cue = 'all'; from = 'Blythe'; to = 'Bligh'; why = 'cast surname' },
    @{ cue = 3; from = 'Mr. Kerris Bly'; to = 'Mr. Kenneth Bligh'; why = 'cue-anchored, same cue as an all' }
  )
  Check 'applies (exit 0)' ($r.Code -eq 0) $r.Out
  Check '"Bly" is corrected in every cue' ($r.Text -match 'Good morning, Mr\. Bligh\.' -and $r.Text -notmatch '\bBly\b')
  Check 'a possessive carries through ("Bly''s" -> "Bligh''s")' ($r.Text -match "meeting at Bligh's tomorrow")
  Check 'a second variant ("Blythe") is corrected' ($r.Text -match 'Bligh will not like it')
  Check 'a cue-anchored fix in the same cue is NOT lost to the all-substitution' ($r.Text -match 'Mr\. Kenneth Bligh is late')
  Check 'a longer name containing the variant ("Blyton") is untouched' ($r.Text -match 'Ask Blyton, he knows')
  Check 'an ordinary word ("blight") is untouched' ($r.Text -match 'A blight on the whole')
  $learned = (Get-Content -LiteralPath (Join-Path $lex "$show/_show.json") -Raw | ConvertFrom-Json).fixes
  Check 'the observed mis-hearings are learned into the show lexicon' (@($learned.PSObject.Properties | Where-Object { $_.Value -eq 'Bligh' }).Count -ge 2) ($learned | ConvertTo-Json)
  $diff = Get-Content -LiteralPath ($srt -replace '\.srt$', '.corrections.json') -Raw | ConvertFrom-Json
  Check 'a learned fix is case-sensitive, so a case-insensitive transcriber cannot apply it to lowercase words' (@($learned.PSObject.Properties | Where-Object { $_.Name -like '*(?-i:*' }).Count -ge 2) ($learned | ConvertTo-Json)
  Check 'the diff marks all-substitutions with scope "all"' (@($diff.corrections | Where-Object { $_.scope -eq 'all' }).Count -ge 3)

  Write-Host 'guards'
  $r = Run @(
    @{ cue = 'all'; from = 'blight'; to = 'Bligh'; why = 'lowercase word' },
    @{ cue = 'all'; from = 'Bly'; to = 'Blyton'; why = 'not a lexicon name' },
    @{ cue = 1; from = 'Mr. Bly'; to = 'Mr. Bligh'; why = 'valid' },
    @{ cue = 2; from = "Bly's"; to = "Bligh's"; why = 'valid' },
    @{ cue = 4; from = 'Blythe'; to = 'Bligh'; why = 'valid' },
    @{ cue = 7; from = 'Wilder'; to = 'Wilder'; why = 'identical' },
    @{ cue = 3; from = 'Kerris'; to = 'Kenneth'; why = 'valid' },
    @{ cue = 3; from = 'Bly'; to = 'Bligh'; why = 'valid' },
    @{ cue = 6; from = 'knows'; to = 'knows.'; why = 'valid' },
    @{ cue = 7; from = 'said'; to = 'says'; why = 'valid' },
    @{ cue = 1; from = 'morning'; to = 'Morning'; why = 'valid' }
  ) -DryRun
  Check 'a lowercase word cannot be swept by "all"' ($r.Out -match "all: 'blight' is not a capitalised name")
  Check 'an "all" correction must move TO a lexicon name' ($r.Out -match "introduces 'Blyton', not a name in this show's lexicon")
  Check 'a dry run leaves the transcript untouched' ($r.Text -eq $original)

  $r = Run @(@{ cue = 'all'; from = 'Revenge'; to = 'Revidge'; why = 'capitalised ordinary word' }) -DryRun
  Check 'a capitalised ORDINARY word (used in lowercase in other shows) cannot be swept by "all"' ($r.Out -match "all: 'Revenge' contains 'Revenge', an ordinary word in other shows' dialogue \(revenge x6\)") $r.Out

  $r = Run @(@{ cue = 'all'; from = 'Nobody'; to = 'Bligh'; why = 'absent' }) -DryRun
  Check 'an "all" name that does not occur is dropped, not applied' ($r.Out -match "all: 'Nobody' does not occur")
}
finally {
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
if ($fail) { Write-Host "$fail test(s) FAILED"; exit 1 }
Write-Host 'all tests passed'
exit 0
