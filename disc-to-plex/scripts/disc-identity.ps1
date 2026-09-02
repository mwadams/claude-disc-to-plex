<#
  disc-identity.ps1 - the permanent record of WHAT IS ON EACH DISC, kept on the NAS.

  WHY
  Working out which episode a disc title actually contains is the expensive step, and the
  cheap sources disagree: mymovies.xml numbering and the Plex agent often differ, and
  settling it has meant sniffing on-screen title cards or matching audio. That effort was
  never written down, so the next encounter with the same disc paid for it again.

  KEY - the MyMovies disc ID (`MMDISCID-...`) from <disc>.dvdid.xml. It is derived from the
  disc, so it survives the folder being renamed and the disc moving to another drive. A
  folder name survives neither: E:\Movies\The Hound of the Baskervilles actually holds the
  1968 Peter Cushing 'Sherlock Holmes Collection'. Discs with no dvdid.xml fall back to
  FP-<sha1 of sorted title runtimes>.

  CLAIMS vs RESOLVED - a claim is what a metadata source asserts; `resolved` is what was
  established by looking at the CONTENT. mymovies and Plex claims are recorded side by side
  and neither is promoted to the answer. Recording a resolution that contradicts a claim
  files a disagreement automatically, so the conflict is preserved rather than smoothed over.

  USAGE
    disc-identity.ps1 -Action Lookup  -Disc 'E:\Movies\Babylon 5 Season 1 Disk 1'
    disc-identity.ps1 -Action Resolve -Disc '<path>' -Title 0 `
        -Work 'Babylon 5' -Kind 'Television Shows' -Season 1 -Episode 1 `
        -Name 'Midnight on the Firing Line' -Method title-card-ocr `
        -Evidence 'card at 00:01:12 reads "Midnight on the Firing Line"'
    disc-identity.ps1 -Action Claim -Disc '<path>' -Title 0 -Source plex -Season 1 -Episode 2
#>
param(
  [ValidateSet('Lookup','Resolve','Claim','Path','Record','Index')][string]$Action = 'Lookup',
  [Parameter(Mandatory)][string]$Disc,
  [int]$Title = -1,
  [string]$Kind, [string]$Work, [string]$Name,
  [int]$Season = -1, [int]$Episode = -1,
  # Record: the produced file, and EXACTLY what it was made from.
  #   -OutFile   the published NAS path of the .mkv
  #   -Source    one or more "t<makemkvTitle>[:<chapterStart>-<chapterEnd>][/pgc<N>][/clip<name>]"
  #              several are allowed: a stills gallery ships as ONE item, and compilation
  #              discs concat several shorts into one file.
  # DVD encoding uses `-f dvdvideo -title N`, where N is the PGC number and NOT the MakeMKV
  # title id, so the two are stored under different names and never conflated.
  [string]$OutFile,
  [string[]]$Source,
  [ValidateSet('title-card-ocr','audio-match','plex-agent','mymovies','operator','runtime')]
  [string]$Method,
  [string]$Evidence,
  [ValidateSet('confirmed','probable','unresolved')][string]$Confidence = 'confirmed',
  [ValidateSet('mymovies','plex')][string]$ClaimSource = 'plex',
  [string]$Store = ([IO.Path]::Combine('\\NASTEAMV','Multimedia','_disc-identity'))
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Disc)) { throw "disc folder not found: $Disc" }
if (-not (Test-Path -LiteralPath $Store)) { New-Item -ItemType Directory -Path $Store | Out-Null }

function Get-DiscId([string]$path) {
  $x = Get-ChildItem -LiteralPath $path -Filter *.dvdid.xml -File -EA SilentlyContinue |
       Select-Object -First 1
  if ($x) {
    $m = [regex]::Match((Get-Content -LiteralPath $x.FullName -Raw), '<ID>(.*?)</ID>')
    if ($m.Success -and $m.Groups[1].Value.Trim()) { return $m.Groups[1].Value.Trim() }
  }
  # fallback: fingerprint the sorted title runtimes (needs a prior enumeration alongside)
  $fp = Join-Path $path 'runtimes.txt'
  if (Test-Path -LiteralPath $fp) {
    $s = (Get-Content -LiteralPath $fp -Raw).Trim()
    $sha = [Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($s))
    return 'FP-' + (($sha | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0,12).ToUpper()
  }
  throw "no dvdid.xml and no runtimes.txt in $path - cannot key a record"
}

$discId = Get-DiscId $Disc
$safe   = ($discId -replace '[^A-Za-z0-9._-]','_')
$file   = Join-Path $Store "$safe.json"

if ($Action -eq 'Path') { $file; return }

if (-not (Test-Path -LiteralPath $file)) {
  if ($Action -eq 'Lookup') {
    Write-Host "NO RECORD for $discId ($(Split-Path $Disc -Leaf))" -ForegroundColor Yellow
    return
  }
  $rec = [ordered]@{
    schema='disc-identity/1'; discId=$discId; discIdSource='mymovies-discid'
    discFolder=(Split-Path $Disc -Leaf); sourceDrive=''; discTitle=$null; discYear=$null
    fingerprint=$null
    recorded=(Get-Date -Format 'yyyy-MM-dd'); updated=(Get-Date -Format 'yyyy-MM-dd')
    titles=@(); disagreements=@(); notes=@()
  } | ConvertTo-Json -Depth 8 | ConvertFrom-Json
} else {
  $rec = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
}

function Get-TitleRec($rec, [int]$n) {
  $t = @($rec.titles | Where-Object { $_.makemkvTitle -eq $n })
  if ($t.Count -eq 0) { throw "title $n is not in the record for $discId (it has $($rec.titles.Count) titles)" }
  $t[0]
}

switch ($Action) {

  'Lookup' {
    Write-Host "$discId  $($rec.discTitle) [$($rec.discFolder)]"
    $produced = @{}
    foreach ($o in @($rec.outputs)) { foreach ($sx in $o.sources) { $produced[$sx.makemkvTitle] = $o } }
    foreach ($t in $rec.titles) {
      $o = $produced[$t.makemkvTitle]
      $txt = if ($o) { Split-Path $o.outFile -Leaf } else { '(no output recorded)' }
      $cl = if ($t.claims.mymovies) { "mymovies S{0:D2}E{1:D2}" -f $t.claims.mymovies.season, $t.claims.mymovies.episode } else { '' }
      $cp = if ($t.claims.plex) { "plex S{0:D2}E{1:D2}" -f $t.claims.plex.season, $t.claims.plex.episode } else { '' }
      $conf = if ($o) { $o.confidence } else { 'unresolved' }
      "  t{0,-3} {1,7:N1} min  {2,-52} {3} {4} [{5}]" -f `
        $t.makemkvTitle, ($t.runtimeSec/60), $txt, $cl, $cp, $conf
    }
    if (@($rec.outputs).Count) {
      Write-Host "  OUTPUTS PRODUCED FROM THIS DISC:"
      foreach ($o in $rec.outputs) {
        $d = ($o.sources | ForEach-Object {
          't{0}{1}{2}' -f $_.makemkvTitle,
            $(if ($null -ne $_.chapterStart) { " ch$($_.chapterStart)-$($_.chapterEnd)" }),
            $(if ($null -ne $_.dvdTitle) { " pgc$($_.dvdTitle)" })
        }) -join ' + '
        "    {0}`n        <- {1}  [{2}, {3}]" -f $o.outFile, $d, $o.method, $o.confidence
      }
    }
    if ($rec.disagreements.Count) {
      Write-Host "  DISAGREEMENTS ON RECORD:" -ForegroundColor Yellow
      foreach ($d in $rec.disagreements) { "    t$($d.title): $($d.detail)" }
    }
  }

  'Claim' {
    if ($Title -lt 0) { throw '-Title is required' }
    $t = Get-TitleRec $rec $Title
    $t.claims.$ClaimSource = [pscustomobject]@{ season=$Season; episode=$Episode; name=$Name
                                           matchedBy='operator'; recorded=(Get-Date -Format 'yyyy-MM-dd') }
    Write-Host "recorded $ClaimSource claim for t$Title"
  }

  'Index' {
    # Reverse index: published .mkv -> the disc, titles and chapters that produced it.
    # Provenance has to answer "which disc made this file?", not only "what is on this disc?".
    $out = Join-Path $Store '_index-by-output.json'
    $map = [ordered]@{}
    foreach ($f in Get-ChildItem -LiteralPath $Store -Filter *.json -File |
                   Where-Object { $_.Name -ne '_index-by-output.json' }) {
      $r = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
      foreach ($o in @($r.outputs)) {
        if (-not $o.outFile) { continue }
        $map[$o.outFile] = [pscustomobject]@{
          discId = $r.discId; discFolder = $r.discFolder; sourceDrive = $r.sourceDrive
          discTitle = $r.discTitle; sources = $o.sources
          method = $o.method; confidence = $o.confidence; resolvedOn = $o.resolvedOn
        }
      }
    }
    $map | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $out -Encoding UTF8
    Write-Host "indexed $($map.Count) output file(s) -> $out"
    return
  }

  'Record' {
    if (-not $OutFile) { throw '-OutFile is required: which .mkv did this produce?' }
    if (-not $Source)  { throw '-Source is required: which title/chapters did it come from?' }
    if (-not $Method)  { throw '-Method is required: how was this established?' }
    if ($Method -in @('title-card-ocr','audio-match') -and -not $Evidence) {
      throw "-Evidence is required for $Method - a resolution with no evidence is an assertion"
    }
    $srcs = @()
    foreach ($s in $Source) {
      $m = [regex]::Match($s, '^t(?<t>\d+)(?::(?<cs>\d+)-(?<ce>\d+))?(?:/pgc(?<pgc>\d+))?(?:/clip(?<clip>[\w-]+))?$')
      if (-not $m.Success) { throw "unparseable -Source '$s' (want t2, t2:1-6, t2/pgc3, t2/clip00042)" }
      $tn = [int]$m.Groups['t'].Value
      if (-not @($rec.titles | Where-Object { $_.makemkvTitle -eq $tn })) {
        throw "-Source names t$tn but this disc's record has no such MakeMKV title"
      }
      $srcs += [pscustomobject]@{
        makemkvTitle = $tn
        chapterStart = if ($m.Groups['cs'].Success) { [int]$m.Groups['cs'].Value } else { $null }
        chapterEnd   = if ($m.Groups['ce'].Success) { [int]$m.Groups['ce'].Value } else { $null }
        dvdTitle     = if ($m.Groups['pgc'].Success) { [int]$m.Groups['pgc'].Value } else { $null }
        clip         = if ($m.Groups['clip'].Success) { $m.Groups['clip'].Value } else { $null }
      }
    }
    $rec.outputs = @($rec.outputs | Where-Object { $_.outFile -ne $OutFile }) + @([pscustomobject]@{
      outFile = $OutFile; kind = $Kind; work = $Work; season = $Season; episode = $Episode
      name = $Name; sources = $srcs; method = $Method; evidence = $Evidence
      confidence = $Confidence; resolvedOn = (Get-Date -Format 'yyyy-MM-dd')
    })
    foreach ($src in 'mymovies','plex') {
      foreach ($s in $srcs) {
        $t = @($rec.titles | Where-Object { $_.makemkvTitle -eq $s.makemkvTitle })[0]
        $c = $t.claims.$src
        if ($c -and $Season -ge 0 -and ($c.season -ne $Season -or $c.episode -ne $Episode)) {
          $detail = "{0} claimed t{1} = S{2:D2}E{3:D2}, recorded as S{4:D2}E{5:D2} by {6}" -f `
                    $src, $s.makemkvTitle, $c.season, $c.episode, $Season, $Episode, $Method
          $rec.disagreements += [pscustomobject]@{ title=$s.makemkvTitle; source=$src
                                                   detail=$detail; recorded=(Get-Date -Format 'yyyy-MM-dd') }
          Write-Host "  DISAGREEMENT FILED: $detail" -ForegroundColor Yellow
        }
      }
    }
    $desc = ($srcs | ForEach-Object {
      't{0}{1}' -f $_.makemkvTitle, $(if ($null -ne $_.chapterStart) { ":ch$($_.chapterStart)-$($_.chapterEnd)" })
    }) -join ' + '
    Write-Host "recorded $(Split-Path $OutFile -Leaf)  <-  $($rec.discFolder) [$desc]"
  }

  'Resolve' {
    if ($Title -lt 0)  { throw '-Title is required' }
    if (-not $Method)  { throw '-Method is required: how was this established?' }
    if ($Method -in @('title-card-ocr','audio-match') -and -not $Evidence) {
      throw "-Evidence is required for $Method - a resolution with no evidence is an assertion"
    }
    $t = Get-TitleRec $rec $Title
    $t.resolved   = [pscustomobject]@{ kind=$Kind; work=$Work; season=$Season; episode=$Episode; name=$Name }
    $t.method     = $Method
    $t.evidence   = $Evidence
    $t.confidence = $Confidence
    $t.resolvedOn = (Get-Date -Format 'yyyy-MM-dd')

    # preserve any conflict rather than quietly overwriting it
    foreach ($src in 'mymovies','plex') {
      $c = $t.claims.$src
      if ($c -and ($c.season -ne $Season -or $c.episode -ne $Episode)) {
        $detail = "{0} claimed S{1:D2}E{2:D2}, resolved to S{3:D2}E{4:D2} by {5}" -f `
                  $src, $c.season, $c.episode, $Season, $Episode, $Method
        $rec.disagreements += [pscustomobject]@{ title=$Title; source=$src; detail=$detail
                                                 recorded=(Get-Date -Format 'yyyy-MM-dd') }
        Write-Host "  DISAGREEMENT FILED: $detail" -ForegroundColor Yellow
      }
    }
    Write-Host "resolved t$Title -> $Work S$('{0:D2}' -f $Season)E$('{0:D2}' -f $Episode) ($Method)"
  }
}

if ($Action -in @('Resolve','Claim','Record')) {
  # ADD the property if the record has not got one. Records written by sweep-drive.ps1 carry
  # `sweptOn` and no `updated`, and assigning to a missing property on a ConvertFrom-Json object
  # THROWS - which, with ErrorActionPreference='Stop', aborted before the save. Eight
  # identifications reported "recorded ..." and none of them reached the disc: the success line
  # is printed by the action, the persistence happens here, and nothing tied the two together.
  $stamp = Get-Date -Format 'yyyy-MM-dd'
  if ($rec.PSObject.Properties.Name -contains 'updated') { $rec.updated = $stamp }
  else { $rec | Add-Member -NotePropertyName updated -NotePropertyValue $stamp -Force }
  $rec | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $file -Encoding UTF8
  Write-Host "saved $file"
}
