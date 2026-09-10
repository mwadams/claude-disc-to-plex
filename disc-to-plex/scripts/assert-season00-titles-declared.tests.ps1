<#
  Tests for assert-season00-titles-declared.ps1 - the gate that stops a bare-named Season 00 item
  publishing with no title Plex could get right.
  Run: pwsh -NoProfile -File assert-season00-titles-declared.tests.ps1   (exit 0 = all passed)

  WHAT THESE HAVE TO PROVE:
    - a BARE Season 00 output with no plexTitle is REFUSED, and named in the refusal;
    - a NAMED Season 00 output passes without a plexTitle (fix-plex-extras.ps1 reads the filename);
    - a bare output WITH a plexTitle passes (that is the carrier this guard exists to require);
    - numbered episodes and film extras are never touched;
    - the guard never refuses on something that is not its business - an unreadable or oddly-shaped
      manifest exits 0, because blocking a manifest the encoder reads happily would make the gate
      cheaper to bypass than to satisfy, which is how the LAST gate got bypassed three times.
#>
$ErrorActionPreference = 'Stop'
$fails = 0
function Check($name, $got, $want) {
  if ("$got" -eq "$want") { Write-Output "  ok   $name" }
  else { Write-Output "  FAIL $name - got '$got', want '$want'"; $script:fails++ }
}

$script = Join-Path $PSScriptRoot 'assert-season00-titles-declared.ps1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('s00titles-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

function Run([object]$manifest) {
  $p = Join-Path $tmp ('m-' + [guid]::NewGuid().ToString('N') + '.json')
  if ($manifest -is [string]) { Set-Content -LiteralPath $p -Value $manifest -Encoding UTF8 }
  else { ($manifest | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $p -Encoding UTF8 }
  $o = & pwsh -NoProfile -File $script -Manifest $p -NasRoot $fakeNas 2>&1 | ForEach-Object { "$_" }
  [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($o -join "`n") }
}
function Item([string]$out, [string]$plexTitle = '', [string[]]$supersedes = @()) {
  $h = [ordered]@{ title = 1; src = 'x'; kind = 'DVD'; out = $out }
  if ($plexTitle) { $h.plexTitle = $plexTitle }
  if ($supersedes.Count) { $h.supersedes = $supersedes }
  [pscustomobject]$h
}

$nas = 'D:/video/Television Shows/The League of Gentlemen (1999)/Season 00'

# An isolated stand-in for the library. The guard now asks whether the library ALREADY HOLDS an
# output's path - that is what makes a bare filename forced - so these cases must not be decided by
# whatever \NASTEAMV happens to contain on the day.
$fakeNas = Join-Path $tmp 'nas'
$fakeS00 = Join-Path $fakeNas 'Television Shows\The League of Gentlemen (1999)\Season 00'
New-Item -ItemType Directory -Force -Path $fakeS00 | Out-Null
try {
  # THE CASE THIS EXISTS FOR. A quality re-rip of a legacy special must keep the legacy filename or
  # it ships a duplicate instead of a replacement - so the name is bare and the manifest is the only
  # place the title can live.
  $r = Run @( (Item "$nas/The League Of Gentlemen S00E22.mkv") )
  Check 'bare Season 00, no plexTitle -> REFUSED'  $r.Code 2
  Check 'and the offending file is named'          ($r.Out -like '*The League Of Gentlemen S00E22.mkv*') 'True'
  Check 'and it says where the title should go'    ($r.Out -like '*plexTitle*') 'True'

  # A bare name is justified ONLY by an in-place `supersedes` that must keep the legacy NAS filename.
  # With that, plexTitle is what makes it titleable, and it passes.
  $r = Run @( (Item "$nas/The League Of Gentlemen S00E22.mkv" 'Series 1 Deleted Scene - The Job Centre' @("$nas/The League Of Gentlemen S00E22.mkv")) )
  Check 'bare + supersedes + plexTitle -> passes'  $r.Code 0

  # ...but a NEW extra has no such constraint, so a bare name there is just the convention being
  # dropped, and a plexTitle does not excuse it: Plex would look right while the NAS, the coverage
  # reports and every directory listing stayed wrong. references/naming.md requires
  # `<Show (Year)> - S00Exx - <Extra title>.mkv`.
  $r = Run @( (Item "$nas/The League Of Gentlemen S00E27.mkv" 'Some New Featurette') )
  Check 'bare NEW extra (no supersedes) -> REFUSED even with plexTitle' $r.Code 2
  Check 'and it says the name is the problem' ($r.Out -like '*BARE filename*') 'True'

  # ---- THE EXCUSE IS THE FACT, NOT THE FIELD -------------------------------------------------
  # _briefs/manifest.md rule 3 says an in-place overwrite carries NO `supersedes` (it retires
  # nothing), and this guard used to accept only a `supersedes` field as justification for a bare
  # name - so the correct manifest for a re-rip of a bare-named legacy extra was inexpressible, and
  # on 2026-09-10 that held four units (Star Cops Disks 1-3, The Feathered Serpent D1). The two
  # cases below differ by ONE fact: whether the library already holds that exact path.
  New-Item -ItemType File -Force -Path (Join-Path $fakeS00 'The League Of Gentlemen S00E31.mkv') | Out-Null
  $r = Run @( (Item "$nas/The League Of Gentlemen S00E31.mkv" 'Series 1 Deleted Scene - The Job Centre') )
  Check 'bare + ALREADY ON THE NAS + plexTitle -> passes (in-place, no supersedes)' $r.Code 0
  $r = Run @( (Item "$nas/The League Of Gentlemen S00E32.mkv" 'Series 1 Deleted Scene - The Job Centre') )
  Check 'bare + NOT on the NAS + plexTitle -> still REFUSED' $r.Code 2
  # An in-place replacement is still only titleable through plexTitle, so that requirement stands.
  $r = Run @( (Item "$nas/The League Of Gentlemen S00E31.mkv") )
  Check 'bare + on the NAS but NO plexTitle -> REFUSED' $r.Code 2
  $r = Run @( (Item "$nas/The League of Gentlemen (1999) - S00E27 - Some New Featurette.mkv") )
  Check 'the properly-named new extra passes'    $r.Code 0

  # A named output needs nothing: fix-plex-extras.ps1 parses the title straight out of the filename.
  $r = Run @( (Item "$nas/The League of Gentlemen (1999) - S00E63 - In Conversation - The League in Conversation with Paul Jackson.mkv") )
  Check 'named Season 00 -> passes without plexTitle' $r.Code 0

  # The separators are the whole distinction. "Show S00E22.mkv" is bare; "Show - S00E22 - Name.mkv"
  # is named. A guard that confused them would either wave through the real fault or block every
  # correctly-named extra.
  $r = Run @( (Item "$nas/Show - S00E07 - Something.mkv"), (Item "$nas/Show S00E08.mkv") )
  Check 'mixed manifest is refused for the bare one only' $r.Code 2
  Check 'the named one is not named in the refusal'       ($r.Out -like '*Show - S00E07*') 'False'

  # Not this guard's business.
  $r = Run @( (Item 'D:/video/Television Shows/Rumpole of the Bailey/Rumpole Of The Bailey S05E01.mkv') )
  Check 'a numbered episode is ignored'            $r.Code 0
  $r = Run @( (Item 'D:/video/Movies/A Prize Of Arms/Featurettes/Making Of.mkv') )
  Check 'a film extra in a subfolder is ignored'   $r.Code 0
  $r = Run @( (Item 'D:/video/Movies/A Prize Of Arms/A Prize Of Arms.mkv') )
  Check 'a film feature is ignored'                $r.Code 0

  # An empty plexTitle is the same fault as none - a whitespace string must not satisfy the rule.
  $r = Run @( (Item "$nas/The League Of Gentlemen S00E30.mkv" '   ') )
  Check 'a whitespace plexTitle does not count'    $r.Code 2

  # SHAPE TOLERANCE. This guard's job is titles, not schema. Refusing here would make the gate
  # cheaper to bypass than to satisfy - the documented reason the edition gate went unused.
  $r = Run '{ not json at all'
  Check 'unreadable manifest -> exit 0, not a refusal' $r.Code 0
  $r = Run ([pscustomobject]@{ items = @( (Item "$nas/The League Of Gentlemen S00E22.mkv") ) })
  Check 'an {items:[...]} manifest is still checked'    $r.Code 2
  $r = Run @()
  Check 'an empty manifest passes'                 $r.Code 0
  $r = Run @( ([pscustomobject]@{ title = 1; kind = 'DVD' }) )
  Check 'an item with no out is skipped'           $r.Code 0

  $reachedEnd = $true
}
catch { Write-Output "  FAIL exception: $($_.Exception.Message)"; $fails++ }
finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
Write-Output ''
if (-not $reachedEnd) { Write-Output 'the suite did not reach its end - treating as FAILED'; $fails++ }
if ($fails) { Write-Output "$fails test(s) FAILED"; exit 1 }
Write-Output 'all tests passed'
exit 0
