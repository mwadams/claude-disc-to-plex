<#
  Derive subtitle lexicons from TVDB metadata via Plex - ONE PER EPISODE, plus a show base.

  WHY PER EPISODE
  Guest cast is where ASR actually fails. A show-level prompt for Danger Man gives you "John
  Drake" and little else, because that is the only recurring name; but the episode "View from
  the Villa" turns on Stella Delroy, Gina Scarlotti, Mego and Mayne - names no general
  vocabulary contains, spoken repeatedly, and mangled every time. Those live in the EPISODE's
  cast list, not the show's. A single show-level prompt would also grow to hundreds of names
  across a long-running series, diluting the bias and overflowing Whisper's prompt window.

  WHY NOT WRITE THEM BY HAND
  A hand-written lexicon is a memory test and it fails. For Day of the Triffids I supplied
  "Bill Masen, Josella Playton, Coker" from recollection; the episode's dialogue actually names
  Tom, George, Anderson and Sussex, and TVDB records the character as "Jo Playton", not
  Josella. The cast list would have been right without my remembering anything.

  LAYOUT
    _lexicons\<Work>\_show.json      recurring cast + terms; the fallback, and used for films
    _lexicons\<Work>\S01E03.json     that episode's title, guest cast and summary terms
  The worker merges show base + episode, episode winning.

  `fixes` is deliberately EMPTY in generated files. A mis-hearing cannot be predicted from a
  cast list - "trippy" for "triffid" was only discoverable by reading real output - and a fix
  for an error that does not occur is dead weight, while a wrong one damages correct text.
  Entries are added by hand from observed errors; regeneration preserves them.

  Read-only against Plex.
#>
param(
  [Parameter(Mandatory)][string]$Show,
  [string]$OutDir = 'D:\video\_lexicons',
  [int]$Section = 0,
  [switch]$Force
)
$ErrorActionPreference = 'Stop'

$token = [Environment]::GetEnvironmentVariable('PLEX_TOKEN', 'User')
$base  = [Environment]::GetEnvironmentVariable('PLEX_BASEURL', 'User')
if (-not $token -or -not $base) { throw 'PLEX_TOKEN / PLEX_BASEURL not set for this user' }
function Plex($path) {
  $sep = if ($path.Contains('?')) { '&' } else { '?' }
  Invoke-RestMethod "$base$path${sep}X-Plex-Token=$token"
}
function Norm([string]$s) {
  $s = $s.ToLower() -replace '\(\d{4}\)', ' ' -replace '&', ' and ' -replace '[^a-z0-9]+', ' '
  ($s.Trim() -replace '^(the|a|an)\s+', '') -replace '\s+', ' '
}
function Safe([string]$s) { ($s -replace '[\\/:*?"<>|]', '_') }

# Strictly: exact title, else normalised-exact. A loose substring match once mapped
# "Harry Potter and the Prisoner of Azkaban" onto "The Prisoner (1967)".
$sections = if ($Section) { @($Section) } else { @(5, 6) }
$all = @()
foreach ($s in $sections) {
  $r = Plex "/library/sections/$s/all"
  $all += @($r.MediaContainer.Directory) + @($r.MediaContainer.Video) | Where-Object { $_.title }
}
$item = @($all | Where-Object { $_.title -eq $Show })
if ($item.Count -ne 1) {
  $n = Norm $Show
  $near = @($all | Where-Object { (Norm $_.title) -eq $n })
  if ($near.Count -gt 1) { throw "'$Show' is ambiguous: $(($near | ForEach-Object { $_.title }) -join '; ')" }
  $item = $near
}
if ($item.Count -ne 1) { throw "no Plex item matching '$Show'" }
$item = $item[0]
Write-Host "matched: $($item.title) ratingKey=$($item.ratingKey) type=$($item.type)"

$workDir = Join-Path $OutDir (Safe $Show)
if (-not (Test-Path -LiteralPath $workDir)) { New-Item -ItemType Directory -Path $workDir -Force | Out-Null }

$STOP = @('The','A','An','And','But','He','She','They','It','His','Her','Their','When','After',
          'Before','While','With','From','As','At','In','On','To','For','Of','This','That',
          'There','Now','Then','Meanwhile','However','Season','Episode','Part','One','Two',
          'Three','Four','Five','But','So','Who','What','Why','How')

function Get-Terms([string[]]$texts, [int]$minCount = 1) {
  $t = @{}
  foreach ($s in $texts) {
    foreach ($m in [regex]::Matches("$s", '\b[A-Z][a-zA-Z''\-]{2,}\b')) {
      if ($STOP -contains $m.Value) { continue }
      $t[$m.Value] = ($t[$m.Value] + 1)
    }
  }
  @($t.GetEnumerator() | Where-Object { $_.Value -ge $minCount } |
    Sort-Object Value -Descending | ForEach-Object { $_.Key })
}

function Write-Lexicon($path, $obj) {
  # Never silently discard hand-added fixes - they are the expensive part.
  $keep = @{}
  if ((Test-Path -LiteralPath $path) -and -not $Force) {
    $old = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($old.fixes) { $old.fixes.PSObject.Properties | ForEach-Object { $keep[$_.Name] = $_.Value } }
  }
  $obj.fixes = $keep
  $obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
  return $keep.Count
}

# --- show base: recurring cast + terms from the show summary
$meta = Plex "/library/metadata/$($item.ratingKey)"
$node = @($meta.MediaContainer.Directory) + @($meta.MediaContainer.Video) | Where-Object { $_ } | Select-Object -First 1
$showRoles = @($node.Role | Where-Object { $_.role } | ForEach-Object { "$($_.role)".Trim() } |
               Where-Object { $_ -notmatch '^(self|narrator|uncredited)$' } | Select-Object -Unique)
$showTerms = Get-Terms @($node.summary) 1

$showPrompt = "$($item.title). " + ((@($showRoles) + @($showTerms | Select-Object -First 20) |
                Where-Object { $_ }) -join ', ') + '.'
$kept = Write-Lexicon (Join-Path $workDir '_show.json') ([ordered]@{
  work = $item.title; scope = 'show'; ratingKey = $item.ratingKey
  source = 'plex/tvdb cast + summary'; generated = (Get-Date -Format 'yyyy-MM-dd HH:mm')
  prompt = $showPrompt; characters = $showRoles; terms = @($showTerms | Select-Object -First 20)
  fixes = @{}
  note = 'fixes are added from OBSERVED mis-hearings only - never predicted'
})
Write-Host "  _show.json           cast=$($showRoles.Count) terms=$($showTerms.Count) keptFixes=$kept"

if ($item.type -ne 'show') { Write-Host 'film - show base only'; return }

# --- one per episode: guest cast is the whole point
$n = 0
foreach ($sn in @((Plex "/library/metadata/$($item.ratingKey)/children").MediaContainer.Directory)) {
  if ($null -eq $sn.index -or -not $sn.ratingKey) { continue }
  foreach ($ep in @((Plex "/library/metadata/$($sn.ratingKey)/children").MediaContainer.Video)) {
    if ($null -eq $ep.index) { continue }
    $key = 'S{0:D2}E{1:D2}' -f [int]$sn.index, [int]$ep.index

    $full = @((Plex "/library/metadata/$($ep.ratingKey)").MediaContainer.Video)[0]
    $roles = @($full.Role | Where-Object { $_.role } | ForEach-Object { "$($_.role)".Trim() } |
               Where-Object { $_ -notmatch '^(self|narrator|uncredited)$' } | Select-Object -Unique)
    $terms = Get-Terms @($full.summary, $full.title) 1

    # episode names first (most specific), then episode terms, then the show's recurring cast.
    # Whisper's prompt window is finite; what is most likely to be spoken and mangled goes first.
    $parts = @($ep.title) + $roles + @($terms | Select-Object -First 15) +
             @($showRoles | Select-Object -First 8)
    $prompt = "$($item.title). " + ((@($parts | Where-Object { $_ } | Select-Object -Unique)) -join ', ') + '.'

    $kept = Write-Lexicon (Join-Path $workDir "$key.json") ([ordered]@{
      work = $item.title; scope = 'episode'; episode = $key; title = $ep.title
      ratingKey = $ep.ratingKey; source = 'plex/tvdb guest cast + episode summary'
      generated = (Get-Date -Format 'yyyy-MM-dd HH:mm')
      prompt = $prompt; characters = $roles; terms = @($terms | Select-Object -First 15)
      fixes = @{}
      note = 'fixes are added from OBSERVED mis-hearings only - never predicted'
    })
    $n++
    if ($n -le 3 -or $n % 25 -eq 0) {
      Write-Host ("  {0,-8} cast={1,-3} terms={2,-3} {3}" -f $key, $roles.Count, $terms.Count, $ep.title)
    }
  }
}
Write-Host "wrote $n episode lexicon(s) -> $workDir"
