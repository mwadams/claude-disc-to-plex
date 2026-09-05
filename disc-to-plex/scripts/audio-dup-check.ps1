# Is a second audio track a REAL commentary, or a duplicate of the programme audio?
#
# WHY THIS EXISTS. identify-audio.py transcribes a track, which CANNOT answer this question. A
# commentary carries the programme audio underneath it and the commentators fall silent for long
# stretches, so a sample taken during a gap transcribes as the programme dialogue and reads as a
# duplicate. That is not a hypothetical: on Gangsters (2026-08-20) S02E01 was declared "duplicate,
# no commentary" from a transcript at 35:00, and the track was a real commentary. The same set had
# the opposite error — `commentary:1` applied to four episodes whose second track was a byte-for-byte
# copy — because one episode's genuine commentary was generalised to its whole series.
#
# Discs frequently give EVERY title the same two-stream layout and fill the unused slot with a copy,
# so "it has two English tracks" tells you nothing. Decoding both and comparing hashes does:
# identical PCM at several offsets = duplicate; different at every offset = a real second programme.
#
# Sampling several offsets matters. One offset can collide (both silent, both a music sting), and a
# commentary that starts late would look identical near the top of the file.
#
# 🔴 "TRACKS DIFFER" IS NOT "COMMENTARY". READ THIS BEFORE TRUSTING A COMMENTARY VERDICT.
# This script compares decoded PCM. That answers "are these the same bits?" - it CANNOT answer "are
# these the same programme audio?", because a LOSSY RE-ENCODE OF THE SAME MIX decodes to different
# PCM at every offset and lands here as COMMENTARY. That layout is the Blu-ray norm: a lossless
# TrueHD/DTS-HD MA 5.1 track plus a Dolby Digital 5.1 COMPATIBILITY track carrying the identical mix.
# Casino Royale (2026-09-05) had exactly this - a:1 was reported "COMMENTARY (tracks differ)
# [DIFF DIFF DIFF]" at all three offsets and is in fact the AC3 5.1 twin of the TrueHD primary.
# analyze-tracks.py had already hinted at it ("differs from the primary but shows FEW COMMENTARY
# CUES"), and this script flatly contradicted that hint.
#
# So when a track is 5.1 and the primary is a lossless codec, DO NOT ship a `commentary:` tag on this
# script's word alone. Settle it with a PHASE-INSENSITIVE ENVELOPE CORRELATION, which is codec-blind:
#   ffmpeg -ss <t> -t 60 -i <src> -map 0:a:<n> -ac 1 -ar 16000 -c:a pcm_s16le out.wav   (per track)
#   python audio-envelope-correlate.py a0.wav aN.wav --max-lag 10
# Measured on Casino Royale at 1800 s and 4200 s:
#   a:1  r = 0.973 / 0.983 at near-zero lag  -> SAME MIX, a duplicate. Not a commentary.
#   a:2  r = 0.736 / 0.673                   -> programme bed plus speech on top. A real commentary.
# A commentary still correlates well above zero precisely BECAUSE it carries the programme audio
# underneath, which is the same property that defeats a transcript sampled during a pause. Roughly:
# r > 0.95 = same mix; r in the 0.5-0.85 band with a lossless primary = something layered over it.
#
#   pwsh -File audio-dup-check.ps1 -Path "D:\video\_stage\gang-d4-mkv"
#   pwsh -File audio-dup-check.ps1 -Path "<one file>" -TrackA 0 -TrackB 2
param(
  [Parameter(Mandatory)][string]$Path,          # a file, or a folder of .mkv
  [int]$TrackA = 0,
  [int]$TrackB = 1,
  [int[]]$Offsets = @(300, 1200, 2400),         # seconds; skipped if past the end
  [int]$Window = 15                             # seconds decoded per sample
)

$paths   = Get-Content 'D:\video\.transcode-tools\tool-paths.json' -Raw | ConvertFrom-Json
$ff      = $paths.ffmpeg
$ffprobe = Join-Path (Split-Path $ff) 'ffprobe.exe'

$files = if (Test-Path -LiteralPath $Path -PathType Container) {
  @(Get-ChildItem -LiteralPath $Path -Filter *.mkv -File | Sort-Object Name)
} else { @(Get-Item -LiteralPath $Path) }
if (-not $files) { throw "no .mkv found at $Path" }

function Hash-Seg([string]$file, [int]$at, [int]$track) {
  # decode to raw PCM at a fixed rate/layout so the comparison is of SOUND, not of container bytes
  $tmp = [IO.Path]::GetTempFileName()
  try {
    & $ff -v error -ss $at -t $Window -i $file -map "0:a:$track" -f s16le -ac 2 -ar 48000 -y $tmp 2>$null | Out-Null
    if ((Get-Item $tmp).Length -eq 0) { return $null }
    return (Get-FileHash -LiteralPath $tmp -Algorithm MD5).Hash.Substring(0,12)
  } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

$anyCommentary = $false
foreach ($f in $files) {
  $na = @(& $ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 $f.FullName).Count
  if ($na -le [Math]::Max($TrackA,$TrackB)) { "{0,-52} only $na audio track(s) - skipped" -f $f.Name; continue }

  $dur = [double](& $ffprobe -v error -show_entries format=duration -of csv=p=0 $f.FullName)
  $res = @()
  foreach ($o in $Offsets) {
    if ($o + $Window -ge $dur) { continue }
    $a = Hash-Seg $f.FullName $o $TrackA
    $b = Hash-Seg $f.FullName $o $TrackB
    if ($null -eq $a -or $null -eq $b) { continue }
    if ($a -eq $b) { $res += 'same' } else { $res += 'DIFF' }
  }
  if (-not $res) { "{0,-52} too short to sample" -f $f.Name; continue }

  # A single DIFF is enough: identical audio cannot differ anywhere. Silence/collisions only ever
  # produce false 'same', never a false 'DIFF'.
  $verdict = 'duplicate  (identical everywhere)'
  if ($res -contains 'DIFF') { $anyCommentary = $true; $verdict = 'COMMENTARY (tracks differ)' }
  "{0,-52} a{1}/a{2}  {3,-22} [{4}]" -f $f.Name, $TrackA, $TrackB, $verdict, ($res -join ' ')
}

if ($anyCommentary) {
  ''
  'Tracks marked COMMENTARY: keep BOTH and set "commentary": <source index> on that item.'
  'Tracks marked duplicate: keep ONE - shipping the copy tagged "Audio Commentary" is a wrong label.'
  'Decide PER TITLE. Commentary is commonly only on a pilot and each series opener/finale.'
}
