<#
.SYNOPSIS
  Fetch a show's CANONICAL season/episode structure from Plex's metadata provider, and optionally
  match a folder of ripped files to it by runtime.

.WHY
  Disc order is not episode order, and box-set season names are not season numbers. Both have to
  come from the authority Plex will actually use, BEFORE anything is encoded - renaming 40 episodes
  afterwards is the alternative.

  Two things that have already misled this project:

  1. `watch.plex.tv/show/<slug>` lists season NAMES in broadcast order with NO indices. Reading the
     order as the numbering is an inference. For Spartacus it happened to be right; it need not be.
  2. A wrong title in Season 00 says nothing about where a real season lives. After publishing a
     show's extras as S00E01.., the agent titled them with another season's episode names - because
     the show has no canonical season 0, so it filled the invented slots from the nearest season.

  The provider answers both directly, with indices.

.EXAMPLES
  # seasons, with their real index numbers
  pwsh -File plex-season-map.ps1 -Show "Spartacus"

  # canonical episode list for one season (titles, runtimes, air dates)
  pwsh -File plex-season-map.ps1 -Show "Spartacus" -Season 2

  # match ripped files to that season by RUNTIME - the check that catches a mis-ordered disc
  pwsh -File plex-season-map.ps1 -Show "Spartacus" -Season 2 -MatchDir D:\video\_stage\gota1-mkv

.NOTES
  Related: GET /library/metadata/<ratingKey>/matches?manual=1 on your own server is the API behind
  the UI's "Fix Match" dialog - candidate matches with guids and scores - if the show itself is
  matched to the wrong thing.
#>
param(
  [Parameter(Mandatory)][string]$Show,
  [int]$Section = 5,
  [int]$Season = -1,
  [string]$MatchDir,
  [string]$FfprobeDir = 'D:\video\.transcode-tools\ffmpeg-n7.1\ffmpeg-n7.1-latest-win64-gpl-7.1\bin'
)
$ErrorActionPreference = 'Stop'

function Env-Fallback($n){ $v=[Environment]::GetEnvironmentVariable($n,'Process'); if(-not $v){ $v=[Environment]::GetEnvironmentVariable($n,'User') }; $v }
$tok  = Env-Fallback 'PLEX_TOKEN'
$base = Env-Fallback 'PLEX_BASEURL'
if(-not $tok -or -not $base){ throw 'PLEX_TOKEN / PLEX_BASEURL not set.' }
$h = @{ 'X-Plex-Token'=$tok; 'Accept'='application/json' }

# --- find the show in the library and take its guid -----------------------------------------
$shows = @((Invoke-RestMethod "$base/library/sections/$Section/all?type=2" -Headers $h).MediaContainer.Metadata)
$s = $shows | Where-Object { $_.title -like "*$Show*" } | Select-Object -First 1
if(-not $s){ throw "No show matching '$Show' in section $Section." }
if($s.guid -notmatch 'plex://show/([0-9a-f]+)'){ throw "Show '$($s.title)' has guid '$($s.guid)' - not a plex:// guid, so the provider cannot be queried. Fix the match first." }
$showId = $Matches[1]
"SHOW: $($s.title) ($($s.year))  ratingKey=$($s.ratingKey)  guid=$($s.guid)"

# The provider returns XML whose children are <Directory>/<Video> ELEMENTS - not a Metadata array,
# so parse as XML rather than JSON.
function Provider-Children($id){
  $raw = Invoke-WebRequest "https://metadata.provider.plex.tv/library/metadata/$id/children?X-Plex-Token=$tok" -TimeoutSec 60 -UseBasicParsing
  ([xml]$raw.Content).MediaContainer.ChildNodes | Where-Object { $_.NodeType -eq 'Element' }
}

$seasons = Provider-Children $showId
''
'CANONICAL SEASONS (use these index numbers):'
foreach($x in $seasons){ "  index={0,-3} {1,-26} episodes={2}" -f $x.index, $x.title, $x.leafCount }

if($Season -lt 0){ return }

$sel = $seasons | Where-Object { [int]$_.index -eq $Season } | Select-Object -First 1
if(-not $sel){ throw "Season $Season not found. Available: $(($seasons | ForEach-Object { $_.index }) -join ', ')" }
$eps = Provider-Children $sel.ratingKey
''
"CANONICAL EPISODES - season $Season '$($sel.title)':"
$canon = @()
foreach($e in $eps){
  $mins = if($e.duration){ [math]::Round([double]$e.duration/60000,1) } else { 0 }
  $canon += [pscustomobject]@{ Index=[int]$e.index; Title=$e.title; Mins=$mins; Aired=$e.originallyAvailableAt }
  "  E{0:d2}  {1,-34} {2,6} min  aired {3}" -f [int]$e.index, $e.title, $mins, $e.originallyAvailableAt
}

if(-not $MatchDir){ return }

# --- match ripped files to canonical episodes BY RUNTIME ------------------------------------
$fp = Join-Path $FfprobeDir 'ffprobe.exe'
if(-not (Test-Path $MatchDir)){ throw "MatchDir not found: $MatchDir" }
''
"MATCHING FILES IN $MatchDir BY RUNTIME:"
$files = Get-ChildItem $MatchDir -File -Filter *.mkv | Sort-Object Name
foreach($f in $files){
  $d = "$(& $fp -v error -show_entries format=duration -of csv=p=0 $f.FullName 2>$null)".Trim()
  if(-not $d -or $d -eq 'N/A'){ "  {0,-44} NO DURATION" -f $f.Name; continue }
  $mins = [math]::Round([double](($d -split '[\s,]+' | Where-Object { $_ -ne '' } | Select-Object -First 1))/60,1)
  $ranked = $canon | Sort-Object { [math]::Abs($_.Mins - $mins) }
  $best = $ranked[0]; $next = $ranked[1]
  $delta = [math]::Round([math]::Abs($best.Mins - $mins), 1)
  # A match is only trustworthy if the runner-up is clearly worse. Episodes of near-identical
  # length are common, so say so rather than pretending the nearest is the answer.
  $gap = if($next){ [math]::Round([math]::Abs($next.Mins - $mins) - $delta, 1) } else { 99 }
  $flag = if($delta -gt 3){ 'NO CLOSE MATCH' } elseif($gap -lt 1){ 'AMBIGUOUS - verify from content' } else { 'ok' }
  "  {0,-44} {1,6} min -> E{2:d2} {3,-24} (d={4,4}, gap={5,4}) {6}" -f $f.Name, $mins, $best.Index, $best.Title, $delta, $gap, $flag
}
''
'Runtime agreement is CORROBORATION, not proof - two episodes can share a runtime. Where it says'
'AMBIGUOUS or NO CLOSE MATCH, identify from content (frames, dialogue, commentary references).'
