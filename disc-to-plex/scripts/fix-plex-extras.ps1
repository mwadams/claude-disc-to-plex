<#
.SYNOPSIS
  Validate-and-fix a show's Extras (Plex Season 00 / "Specials") so Plex matches the
  files we actually produced — not the agent's guesses.

.WHY
  The Plex TV agent almost always mislabels bonus features: it injects wrong titles
  ("Episode 5"), wrong summaries (e.g. a DragonCon panel synopsis onto a making-of),
  and wrong posters pulled from unrelated online items. Our filenames are the source
  of truth (we named them from the disc's title cards / mymovies.xml). This script
  forces Plex to agree with the files and LOCKS the fields so a later refresh can't
  undo it.

.WHAT IT DOES  (per episode in the target season, matched to a local/NAS file by name)
  -Titles    : set Plex title = the <Title> parsed from the filename, then lock it.
  -Summaries : clear the summary (our extras have no canonical synopsis) and lock it,
               killing any wrong agent text. Use -KeepSummaries to leave them.
  -Posters   : extract a representative frame (~40% through) from the file and upload
               it as the episode poster. Uploaded posters auto-select and are sticky
               across refreshes, so no separate lock is needed.

.NOTES
  - Files are matched to Plex episodes by BASENAME (Plex Part.file is the *server's*
    path, e.g. /volume1/... on the NAS — not usable for local ffmpeg — so we take the
    leaf and look it up in -MediaDir, which you point at the real files, local or UNC).
  - PLEX_TOKEN / PLEX_BASEURL: read from the User environment if the process env is
    empty (child shells launched before the vars were set inherit a stale env).
  - Idempotent: safe to re-run. Poster upload adds a new selected poster each run;
    harmless but pass -Posters only when you actually want to (re)set art.

.EXAMPLE
  pwsh -File fix-plex-extras.ps1 -Show "Deep Space" -MediaDir "\\NAS\media\Television Shows\Star Trek Deep Space Nine (1993)\Season 00"
#>
param(
  [string]$Show,                                  # substring match on series title
  [string]$RatingKey,                             # exact show ratingKey - prefer this in bulk runs
  [Parameter(Mandatory)] [string]$MediaDir,      # folder holding the Season-N mkv files (local or UNC)
  [int]$Season = 0,
  [int]$Section = 5,                              # Plex library section id (5 = "TV programmes" here)
  [switch]$KeepSummaries,                         # skip the clear+lock of summaries
  [switch]$NoTitles,                              # skip title set+lock
  [switch]$NoPosters,                             # skip poster extraction+upload
  [int]$FromIndex = 0,                            # only process episodes with index >= this (e.g. new extras only)
  [int]$ToIndex = 0,                              # only process episodes with index <= this (0 = no upper bound)
  [string]$FfmpegDir = "D:\video\.transcode-tools\ffmpeg-n7.1\ffmpeg-n7.1-latest-win64-gpl-7.1\bin",
  [double]$PosterAt = 0.40                        # fraction of duration to grab the poster frame
)

$ErrorActionPreference = 'Stop'
function Env-Fallback($name){ $v=[Environment]::GetEnvironmentVariable($name,'Process'); if(-not $v){ $v=[Environment]::GetEnvironmentVariable($name,'User') }; $v }
$tok  = Env-Fallback 'PLEX_TOKEN'
$base = Env-Fallback 'PLEX_BASEURL'
if(-not $tok -or -not $base){ throw "PLEX_TOKEN / PLEX_BASEURL not set (User or Process env)." }
$h  = @{ "X-Plex-Token"=$tok; "Accept"="application/json" }
$ff = Join-Path $FfmpegDir 'ffmpeg.exe'; $fp = Join-Path $FfmpegDir 'ffprobe.exe'
if(-not (Test-Path $MediaDir)){ throw "MediaDir not found: $MediaDir" }

# --- the season must be the one MediaDir actually holds -------------------------------------
# `-Season` defaults to 0 because extras have always lived in Season 00. That stopped being true
# the moment a show put REAL episodes there (Spartacus: Gods of the Arena is season 0 in the
# tvdbAiring tree, with its extras moved to Season 90). Run without -Season then, and this script
# cheerfully cleared and LOCKED the summaries of six correctly-matched episodes - while reporting
# "file not in MediaDir" for every single one. Evidence of the wrong target is not a reason to
# continue: derive the season from the files, and refuse when it disagrees.
# NOT just *.mkv. This pipeline writes .mkv, but the library also holds older transfers in .mp4,
# and globbing for mkv alone made this script throw "No SxxEyy-named .mkv files in MediaDir" on
# SEVEN shows in one bulk run (Adam Adamant Lives, Big Train, Callan, Quatermass, Spindoe,
# Big Breadwinner Hogg, A Bit of Fry & Laurie) whose Season 00 is entirely .mp4. The message named
# the extension, which is the only reason it was diagnosable rather than just "no files".
$mediaExt = @('*.mkv', '*.mp4', '*.m4v', '*.avi')
$dirSeasons = @($mediaExt | ForEach-Object { Get-ChildItem $MediaDir -Filter $_ -File -EA SilentlyContinue } |
                ForEach-Object { if($_.Name -match '[Ss](\d{1,3})[Ee]\d{1,3}'){ [int]$Matches[1] } } |
                Sort-Object -Unique)
if($dirSeasons.Count -eq 0){ throw "No SxxEyy-named .mkv files in MediaDir - cannot tell which season this is: $MediaDir" }
if($dirSeasons.Count -gt 1){ throw "MediaDir mixes seasons ($($dirSeasons -join ', ')) - point this at ONE season folder: $MediaDir" }
if($PSBoundParameters.ContainsKey('Season')){
  if($Season -ne $dirSeasons[0]){
    throw "REFUSING: -Season $Season was given but MediaDir holds season $($dirSeasons[0]) files. One of them is wrong, and guessing would edit the wrong episodes: $MediaDir"
  }
} else {
  $Season = $dirSeasons[0]
  Write-Host "season not specified - taking $Season from the files in MediaDir"
}

# --- locate show -> season -> episodes ---
$allmeta = @((Invoke-RestMethod "$base/library/sections/$Section/all?type=2" -Headers $h).MediaContainer.Metadata)
if ($RatingKey) {
  # Exact target. -Show is a SUBSTRING match that silently takes the FIRST hit, which is fine when
  # a human is watching and dangerous in a bulk run: "Rome" also matches "Rome: Power & Glory",
  # "Raven" matches "Raven's Home", and the library holds two Randall & Hopkirks. Pass -RatingKey
  # when driving this from a script so the show cannot be mistaken.
  $showObj = $allmeta | Where-Object { "$($_.ratingKey)" -eq "$RatingKey" } | Select-Object -First 1
  if (-not $showObj) { throw "No show with ratingKey $RatingKey in section $Section." }
} else {
  $matches = @($allmeta | Where-Object { $_.title -like "*$Show*" -and $_.ratingKey })
  if ($matches.Count -gt 1) {
    Write-Warning ("'{0}' matched {1} shows: {2}. Taking the first - pass -RatingKey to be exact." -f `
      $Show, $matches.Count, (($matches | ForEach-Object { "$($_.title) [$($_.ratingKey)]" }) -join '; '))
  }
  $showObj = $matches | Select-Object -First 1
  if(-not $showObj -or -not $showObj.ratingKey){ throw "No show matching '$Show' in section $Section (matched $($allmeta.Count) shows)." }
}
$seasonMeta = (Invoke-RestMethod "$base/library/metadata/$($showObj.ratingKey)/children" -Headers $h).MediaContainer.Metadata |
              Where-Object { $_.index -eq $Season } | Select-Object -First 1
if(-not $seasonMeta){ throw "Show '$($showObj.title)' has no season index $Season." }
$eps = (Invoke-RestMethod "$base/library/metadata/$($seasonMeta.ratingKey)/children" -Headers $h).MediaContainer.Metadata | Sort-Object index
Write-Host "SHOW: $($showObj.title)  Season $Season  ($($eps.Count) items)`n"

# PID-suffixed: the ratingKey+season key is unique per TARGET but not per RUN, and a stale dir
# from an earlier run could feed old posters into a new pass. Same shape (weaker instance) as
# the catalogue scratch collision of 2026-08-23.
$tmp = Join-Path $env:TEMP ("plexposters_{0}_{1}_{2}" -f $showObj.ratingKey,$Season,$PID)
New-Item -ItemType Directory -Force $tmp | Out-Null

foreach($e in $eps){
  if($FromIndex -and $e.index -lt $FromIndex){ continue }
  if($ToIndex   -and $e.index -gt $ToIndex){ continue }
  $rk   = $e.ratingKey
  $leaf = Split-Path $e.Media[0].Part[0].file -Leaf
  $file = Join-Path $MediaDir $leaf
  $haveFile = Test-Path $file
  $line = "E{0:D2} rk={1} {2}" -f $e.index,$rk,$e.title

  # title from filename:  " - SxxEyy[-Ezz] - <Title>.mkv"
  if(-not $NoTitles){
    if($leaf -match ' - S\d+E\d+(?:-E\d+)? - (.+)\.[^.]+$'){
      $title = $matches[1]
      $enc = [uri]::EscapeDataString($title)
      Invoke-RestMethod "$base/library/metadata/$rk`?type=4&title.value=$enc&title.locked=1" -Headers @{ "X-Plex-Token"=$tok } -Method Put | Out-Null
      $line += " | title='$title' set+locked"
    } else { $line += " | title: (couldn't parse filename)" }
  }

  if(-not $KeepSummaries){
    Invoke-RestMethod "$base/library/metadata/$rk`?type=4&summary.value=&summary.locked=1" -Headers @{ "X-Plex-Token"=$tok } -Method Put | Out-Null
    $line += " | summary cleared+locked"
  }

  if(-not $NoPosters){
    if($haveFile){
      $dur = [double](& $fp -v error -show_entries format=duration -of default=nw=1:nk=1 $file)
      $t   = [Math]::Max(2,[Math]::Round($dur*$PosterAt,0))
      $jpg = Join-Path $tmp ("s{0:D2}e{1:D2}.jpg" -f $Season,$e.index)
      & $ff -y -v error -ss $t -i $file -frames:v 1 -vf "scale=640:-1" -q:v 3 $jpg 2>$null
      if((Test-Path $jpg) -and (Get-Item $jpg).Length -gt 3000){
        Invoke-RestMethod "$base/library/metadata/$rk/posters?X-Plex-Token=$tok" -Method Post -InFile $jpg -ContentType 'image/jpeg' | Out-Null
        $line += (" | poster @{0}s uploaded" -f $t)
      } else { $line += " | poster: extract failed/too-small" }
    } else { $line += " | poster: file not in MediaDir ($leaf)" }
  }
  Write-Host $line
}
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`nDone. Re-open the season in Plex to confirm."
