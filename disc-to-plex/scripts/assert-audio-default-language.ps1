<#
.SYNOPSIS
  Refuse a manifest whose FIRST kept audio track is a dub, for a work whose library already plays in
  another language. Exit 0 = nothing to say. Exit 2 = the default audio would be wrong.

.WHY THIS EXISTS
  `audioTracks` is an ORDERED list. transcode.ps1 muxes in that order, position 0 becomes the default
  stream, and Plex plays the default. Nothing decided which track went first, so it was whatever the
  manifest author wrote - and on a disc whose a:0 is a dub, that is the dub.

  2026-09-21, Deep Space Nine: 20 re-ripped episodes shipped with GERMAN as the default audio (S02
  E01/03/04/06/07/21/22/25, S04 E03/10/11/13/15/16/19/24, S06 E05/07/08/11). English was never lost -
  it sat last as the passthrough AC3 - but every one of them PLAYED IN GERMAN. Eight had already been
  confirmed and reclaimed. The operator found it by pressing play on S04E13.

  These are multi-language European discs, which is the same property that put a DANISH subtitle
  stream in the library and started the re-rip programme in the first place. The manifests
  re-selected audio as well as subtitles, and the verification after the re-rip checked subtitles
  only - the axis being fixed rather than every axis that changed.

.WHY IT REFUSES INSTEAD OF REORDERING
  The obvious fix - "promote English to the front" in derive-manifest-fields.ps1 - was written first
  and one of that script's own tests killed it inside a minute: a fixture with spoken FRENCH at a:0
  and English at a:1 came back reordered, i.e. a dub promoted over the programme audio. This library
  holds Porco Rosso (whose re-rip exists precisely to restore the original Japanese), Amelie, Black
  Narcissus. "English first" is not a rule here.

  And the distinction is NOT measurable from the streams: DS9 and a French film both look like
  "a:0 is not English and an English track exists". What differs is the language the PROGRAMME was
  made in - which lives in the dispositions and in what the work already publishes, not in the audio.

.HOW IT DECIDES, WITHOUT GUESSING
  It asks one question with an evidenced answer: WHAT LANGUAGE DOES THIS WORK ALREADY PLAY IN? Taken
  from the published library - the default audio stream of the work's existing episodes/films on the
  NAS. A work that already plays English in 25 of 26 episodes is an English-language work, and a new
  row that would default to German is wrong. A work that plays Japanese is a Japanese work, and a row
  defaulting to Japanese is right.

  A work with NOTHING published yet gets no opinion and passes - there is no evidence, and inventing
  one is how the reorder went wrong.

.EXAMPLE
  pwsh -File assert-audio-default-language.ps1 -Manifest D:/video/_queue/pending/some-disc.json
#>
param(
  [Parameter(Mandatory)][string]$Manifest,
  [string]$NasRoot = '\\NASTEAMV\Multimedia',
  [int]$MinSample  = 3,          # fewer published files than this = not enough to call it
  [double]$Majority = 0.8,       # share of published files that must agree before we call it
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'

function Get-WorkFromOut {
  param([Parameter(Mandatory)][string]$OutPath)
  if ($OutPath -match '(?i)[\\/](Movies|Television Shows)[\\/]([^\\/]+)[\\/]') {
    return @{ Kind = $Matches[1]; Work = $Matches[2] }
  }
  return $null
}

if ($SelfTest) {
  $fail = 0
  function T($n, $c) { if ($c) { "  ok   $n" } else { $script:fail++; "  FAIL $n" } }
  $a = Get-WorkFromOut -OutPath 'D:/video/Television Shows/Star Trek Deep Space Nine (1993)/Season 04/x.mkv'
  T 'TV work extracted'      ($a.Work -eq 'Star Trek Deep Space Nine (1993)' -and $a.Kind -eq 'Television Shows')
  $b = Get-WorkFromOut -OutPath 'D:\video\Movies\Porco Rosso\Porco Rosso.mkv'
  T 'movie work extracted'   ($b.Work -eq 'Porco Rosso' -and $b.Kind -eq 'Movies')
  T 'non-library path is null' ($null -eq (Get-WorkFromOut -OutPath 'D:/video/_stage/foo/bar.mkv'))
  if ($fail) { "SELFTEST FAILED - $fail case(s)"; exit 1 }
  'SELFTEST OK'; exit 0
}

if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { exit 0 }
try { $rows = @(Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json) } catch { exit 0 }
if (-not $rows.Count) { exit 0 }

$ff = 'ffprobe'
$cacheWorkLang = @{}

function Get-EstablishedLanguage {
  <# The language this work ALREADY plays in, from the default audio stream of what is published.
     Returns '' when there is not enough published evidence to call it. #>
  param([string]$Kind, [string]$Work)
  $key = "$Kind|$Work"
  if ($cacheWorkLang.ContainsKey($key)) { return $cacheWorkLang[$key] }
  $dir = Join-Path (Join-Path $NasRoot $Kind) $Work
  $langs = @{}
  $n = 0
  if (Test-Path -LiteralPath $dir -PathType Container) {
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Recurse -File -Filter *.mkv -ErrorAction SilentlyContinue | Select-Object -First 40)) {
      try {
        $j = & $ff -v quiet -print_format json -show_streams $f.FullName | ConvertFrom-Json
        $a = @($j.streams | Where-Object { $_.codec_type -eq 'audio' })
        if (-not $a.Count) { continue }
        $l = "$($a[0].tags.language)"
        if (-not $l) { continue }
        $n++
        if (-not $langs.ContainsKey($l)) { $langs[$l] = 0 }
        $langs[$l]++
      } catch { }
    }
  }
  $verdict = ''
  if ($n -ge $MinSample) {
    $top = @($langs.GetEnumerator() | Sort-Object Value -Descending)[0]
    if (($top.Value / [double]$n) -ge $Majority) { $verdict = $top.Key }
  }
  $cacheWorkLang[$key] = $verdict
  return $verdict
}

$bad = @()
foreach ($r in $rows) {
  $names = $r.PSObject.Properties.Name
  if ($names -notcontains 'audioLangs' -or $null -eq $r.audioLangs) { continue }
  $langs = @($r.audioLangs | ForEach-Object { "$_".Trim() })
  if ($langs.Count -lt 2) { continue }              # one track: no ordering decision exists
  $first = $langs[0]
  if (-not $first -or $first -eq 'zxx') { continue } # unknown or music: nothing asserted here
  $w = Get-WorkFromOut -OutPath "$($r.out)"
  if (-not $w) { continue }
  $established = Get-EstablishedLanguage -Kind $w.Kind -Work $w.Work
  if (-not $established) { continue }                # no published evidence: no opinion
  if ($first -eq $established) { continue }
  # The established language must actually be AVAILABLE on this row, or the row is not choosing
  # wrongly - it simply does not have that track, which is a different problem.
  if ($langs -notcontains $established) { continue }
  $bad += [pscustomobject]@{
    Out = (Split-Path "$($r.out)" -Leaf); Work = $w.Work
    First = $first; Should = $established; At = [array]::IndexOf($langs, $established); Langs = ($langs -join ',')
  }
}

if (-not $bad.Count) { exit 0 }

Write-Output ("REFUSE - {0} row(s) would publish with a DUB as the default audio:" -f $bad.Count)
foreach ($b in $bad) {
  Write-Output ("    {0}" -f $b.Out)
  Write-Output ("        audioLangs = [{0}] - position 0 is '{1}', but '{2}' is what '{3}' already plays in (it is at position {4})" -f `
                $b.Langs, $b.First, $b.Should, $b.Work, $b.At)
}
Write-Output '  audioTracks is ORDERED: position 0 becomes the default stream and Plex plays the default.'
Write-Output '  Reorder audioTracks (and audioLangs with it) so the programme audio is first. Nothing else'
Write-Output '  changes - no track is added or dropped, and this is not a re-encode.'
Write-Output '  If this work is genuinely foreign-language and the established language is the DUB, say so'
Write-Output '  in the dispositions and order it deliberately - this check reads what the library already'
Write-Output '  plays, which is evidence, not a preference.'
exit 2
