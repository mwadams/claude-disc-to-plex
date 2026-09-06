<#
  THE ONE PLACE that decides whether a line in a dispositions file (or a closure-verdict sidecar)
  is a CLOSURE VERDICT rather than prose mentioning one.

.WHY THIS LIBRARY EXISTS
  The rule lived in TWO files - `_dispositions-loop.ps1`'s Get-ClosureVerdict and
  `close-ships-nothing.ps1`'s $verdictRx - kept in step by a comment reading "Keep this identical to
  $rxNothing in _dispositions-loop.ps1. Never loosen either back."

  That convention failed the first time it was tested. On 2026-09-06 the anchored rule was found to
  accept a WRAPPED SENTENCE whose tail begins a physical line:

      # All three questions resolve to "something is worth shipping" - this is NOT a case for
      # NOTHING IS WORTH SHIPPING. The feature (dv5/t02) has a real quality gain, and the reading

  `A Warning to the Curious` was closed as shipping nothing on that fragment, while its own
  disposition recorded a quality gain AND a wholly missing Michael Hordern reading. The fix was
  applied to Get-ClosureVerdict - and the disc was RE-CLOSED THREE MINUTES LATER by the copy in
  close-ships-nothing.ps1, which nobody had updated. One rule, two implementations, one fixed.

  So the rule now lives here, once. Both callers dot-source it. There is no second copy to forget.

.THE RULE
  A verdict is an ASSERTION. Two conditions, both necessary:

    1. ANCHORED - after the comment hash is stripped, the line BEGINS with the marker and is
       followed by ':' or '.' or nothing. Prose ABOUT a verdict - above all a DENIAL of one -
       embeds it mid-sentence. This closed four discs carrying 18 real titles in September 2026
       (Day of the Triffids, The Box of Delights, Dead Poets Society, Dirty Harry) before it was
       added on 2026-09-05.

    2. NOT A CONTINUATION - the preceding non-blank line must be blank, a separator/banner, an
       ALL-CAPS heading, or end in terminal punctuation. Anchoring alone assumes one physical line
       is one logical statement; word wrap breaks that and puts a mid-sentence mention at a line
       start, where condition 1 cannot see the difference.

  Checked against every real occurrence in the catalogue: the genuine verdicts (Ghostwatch,
  Flambards Disk 3, Fight Club Disk 1, and the banner-led ones on Edge of Darkness Disk 2 and
  Flambards Disk 1) all follow a "==== VERDICT ====" banner or a blank comment line, while every
  false one either embeds the marker mid-sentence or continues the line above it.

.THE REAL FIX, STILL OWED
  This is a better guard, not a good design. A verdict should be a FIELD in a structured artefact,
  not a phrase a regex has to recognise in free text - see follow-up.md. Until then, this at least
  has one implementation rather than two.
#>

$script:ClosureRxNothing = '(?i)^NOTHING\s+(IS\s+)?WORTH\s+SHIPPING\s*([:.]|$)'
$script:ClosureRxOutside = '(?i)^SHIPPED\s+VIA\s+NON-MANIFEST\s+ROUTE\s*([:.]|$)'

function Get-ClosureMarkerPattern {
  param([ValidateSet('ships-nothing', 'shipped-outside')][string]$Kind = 'ships-nothing')
  if ($Kind -eq 'ships-nothing') { return $script:ClosureRxNothing }
  return $script:ClosureRxOutside
}

function Remove-ClosureCommentPrefix {
  # UNTYPED and null-tolerant on purpose. A [string] parameter rejects $null outright and throws on
  # anything array-shaped, and Get-Content can hand back either when a dispositions file is empty,
  # missing, or single-line. A verdict parser that THROWS is worse than one that finds nothing: the
  # caller is a closure gate, and an exception there stalls the whole dispositions pass.
  param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()]$Line)
  if ($null -eq $Line) { return '' }
  return ("$Line" -replace '^\s*#\s*', '').Trim()
}

function Test-ClosureLineIsContinuation {
  <# True when this line is the tail of a sentence begun on an earlier line, and therefore cannot be
     an assertion no matter what it starts with. #>
  param(
    [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Lines,
    [Parameter(Mandatory)][int]$Index
  )
  if ($null -eq $Lines) { return $false }
  for ($j = $Index - 1; $j -ge 0; $j--) {
    $prev = Remove-ClosureCommentPrefix $Lines[$j]
    if (-not $prev)                     { return $false }   # blank -> a fresh statement
    if ($prev -match '^[=\-_*]{3,}')    { return $false }   # separator / banner
    if ($prev -match '[.:!?]$')         { return $false }   # the sentence above ended
    if ($prev -cmatch '^[^a-z]+$')      { return $false }   # ALL-CAPS heading, e.g. "VERDICT"
    return $true                                            # prose that ran on
  }
  return $false                                             # nothing above it
}

function Find-ClosureVerdictIndex {
  <# Index of the first line that is a genuine verdict assertion, or -1. #>
  param(
    [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Lines,
    [ValidateSet('ships-nothing', 'shipped-outside')][string]$Kind = 'ships-nothing'
  )
  if ($null -eq $Lines) { return -1 }
  $rx = Get-ClosureMarkerPattern -Kind $Kind
  for ($i = 0; $i -lt $Lines.Count; $i++) {
    if ((Remove-ClosureCommentPrefix $Lines[$i]) -notmatch $rx) { continue }
    if (Test-ClosureLineIsContinuation -Lines $Lines -Index $i)  { continue }
    return $i
  }
  return -1
}

function Get-ClosureVerdictLines {
  <# Every genuine verdict assertion in the text, cleaned. Empty when there is none - which is the
     answer for a file that merely DISCUSSES a verdict. #>
  param(
    [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Lines,
    [ValidateSet('ships-nothing', 'shipped-outside')][string]$Kind = 'ships-nothing'
  )
  $out = @()
  if ($null -eq $Lines) { return ,$out }
  $rx = Get-ClosureMarkerPattern -Kind $Kind
  for ($i = 0; $i -lt $Lines.Count; $i++) {
    $clean = Remove-ClosureCommentPrefix $Lines[$i]
    if ($clean -notmatch $rx) { continue }
    if (Test-ClosureLineIsContinuation -Lines $Lines -Index $i) { continue }
    $out += $clean
  }
  return ,$out
}
