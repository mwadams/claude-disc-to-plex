# Refuse to enumerate or rip a staging folder that is still being copied.
#
# WHY. MakeMKV enumerates whatever stream files are PRESENT. Run it against a half-copied folder
# and it returns a SHORTER, entirely plausible title list - no error, no warning - and that list
# becomes the episode mapping. It has now cost two units:
#
#   Spartacus Vengeance D1   enumerated mid-copy, reported ONE episode.  Caught at the time.
#   The Newsroom S2 D1       enumerated mid-copy, reported 6 titles of 13. Shipped 2 episodes
#                            instead of 3 and ZERO of its 6 extras. NOT caught - it looked like a
#                            complete disc, and the missing episode was rationalised for two days
#                            as "absent from the set" because the runtimes of what remained still
#                            fitted a story. The user found it by noticing the on-screen title card.
#
# The fetch script already records verified copies in _fetch-done.txt. That gate protected the
# FETCH and nothing else: enumeration is a separate command and never consulted it. So this check
# lives where the damage happens, and THROWS rather than warns.
#
# Read-only. Touches nothing on E: or the NAS.
param(
  [Parameter(Mandatory)][string]$StageDir,                 # e.g. D:\video\_stage\THE_NEWSROOM_S2_DISC1
  [string]$SrcRoot  = 'E:\',                               # where the disc was copied FROM
  [string]$DoneFile = 'D:\video\_fetch-done.txt',
  [int]$SettleSeconds = 6,                                 # re-measure after this to catch a live copy
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $StageDir)) { throw "ABORT: staging folder not found: $StageDir" }
$name = Split-Path $StageDir -Leaf

function Measure-Tree($p) {
  $m = Get-ChildItem -LiteralPath $p -Recurse -File -EA SilentlyContinue | Measure-Object Length -Sum
  [pscustomobject]@{ Count = [int]$m.Count; Bytes = [long]$m.Sum }
}

$local = Measure-Tree $StageDir

# --- 1. is it still growing? -----------------------------------------------------------------
# A copy in flight is the case this exists for, and it is detectable without the source: measure
# twice. This runs first because it is cheap and needs no E: access.
Start-Sleep -Seconds $SettleSeconds
$again = Measure-Tree $StageDir
if ($again.Bytes -ne $local.Bytes -or $again.Count -ne $local.Count) {
  # NB the parentheses: -f binds tighter than +, so without them only the LAST fragment is
  # formatted and the placeholders survive into the message verbatim.
  throw (("ABORT: $name is STILL BEING COPIED - grew by {0:N0} byte(s) / {1} file(s) in {2}s. " +
          "Wait for the fetch to verify before enumerating.") -f
         ($again.Bytes - $local.Bytes), ($again.Count - $local.Count), $SettleSeconds)
}

# --- 2. does it match the source? ------------------------------------------------------------
$src = Join-Path $SrcRoot $name
if (Test-Path -LiteralPath $src) {
  $s = Measure-Tree $src
  if ($s.Count -ne $local.Count -or $s.Bytes -ne $local.Bytes) {
    throw (("ABORT: $name is INCOMPLETE - source {0} file(s)/{1:N0} bytes, staged {2}/{3:N0} " +
            "(short by {4} file(s), {5:N0} bytes). Enumerating this would silently drop titles.") -f
           $s.Count, $s.Bytes, $local.Count, $local.Bytes, ($s.Count-$local.Count), ($s.Bytes-$local.Bytes))
  }
  if (-not $Quiet) { "OK: $name matches source - $($local.Count) files, $('{0:N2}' -f ($local.Bytes/1GB)) GB" }
  exit 0
}

# --- 3. source gone (already reclaimed): fall back to the done-list ---------------------------
$done = if (Test-Path -LiteralPath $DoneFile) { @(Get-Content -LiteralPath $DoneFile | Where-Object { $_.Trim() }) } else { @() }
if ($done -contains $name) {
  if (-not $Quiet) { "OK: $name not on $SrcRoot but recorded as verified in $(Split-Path $DoneFile -Leaf)" }
  exit 0
}
throw "ABORT: $name is neither present on $SrcRoot nor recorded in $DoneFile - completeness cannot be established."
