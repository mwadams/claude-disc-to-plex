<#
.SYNOPSIS
  THE ONE PLACE that decides whether an encoded output's length matches what its manifest declared.
  Dot-source this; it defines functions and does nothing on its own.

.WHY THIS EXISTS
  The rule was written twice on 2026-09-07 and the two copies immediately disagreed.

  `transcode.ps1` checks length TWICE - `expectSeconds` against the container duration and
  `expectFrames` against the video packet count. They are ONE QUANTITY IN TWO UNITS. The seconds
  check was made asymmetric so the dvdvideo demuxer's known under-declaration stopped quarantining
  correct encodes; the frame check was left symmetric at +-25. Both Definitive Sherlock Holmes discs
  were re-queued and failed again, saying both halves in consecutive lines:

      length +4.41s over the declared 4,587.00s - within the 15.00s over-allowance; ...
      !! WRONG LENGTH - output has 114,785 video frames, manifest expects 114,675

  110 frames at 25 fps IS 4.41 s. One guard accepted it and the next rejected it, so four correct
  films stayed quarantined and both jobs went back to _queue\failed - a whole extra cycle for
  nothing. Then `sweep-superseded-quarantine.ps1` needed the SAME judgement a third time, to decide
  whether a replacement is good enough to drop the artefact it supersedes.

  Three copies of a rule is three chances to fix one and forget the others, and the failure is
  silent both ways: too tight quarantines good work, too loose ships a wrong cut. So it lives here.

.THE RULE
  OVER (output longer than declared) is TOLERANT, because the dvdvideo demuxer under-declares:
  it emits more than MakeMKV writes into the catalogue. Measured overshoots on real discs run
  2.80-4.41 s on ~4,600 s films (0.06-0.10%). The allowance is the one this project already uses
  for the same question in disposition-analysis.ps1's Get-TruncationVerdict - benign at <=2 s
  absolute, or <=0.5% capped at 15 s - reused so one judgement is not made two ways.

  UNDER (output shorter than declared) stays TIGHT, because that is real loss: a truncated title,
  a wrong cut, or dropped frames. The founding case, The Champions D1 t2, published 2,494 s against
  3,179.6 enumerated - 27%, nowhere near any tolerance. Frames are tighter still (25 frames, ~1 s)
  because an under-run in the packet count means pictures are missing, which is the specific
  failure that guard was written for.

.NOTES
  Frame rate is derived from the manifest's OWN two figures where both are present - they describe
  the same title, so their ratio is the rate the expectation was built at. Callers that have only
  one figure must supply a probed rate.
#>

# The over-allowance, in seconds, for a title of the given declared length.
function Get-LengthOverAllowanceSeconds {
  param([Parameter(Mandatory)][double]$ExpectSeconds)
  return [Math]::Min(15.0, [Math]::Max(2.0, $ExpectSeconds * 0.005))
}

# How short an output may run before it is a failure. Deliberately a constant and deliberately
# small: see .THE RULE above.
function Get-LengthUnderAllowanceSeconds { return 2.0 }
function Get-FrameUnderAllowance { return 25 }

# Judge a duration. Returns Ok plus the numbers a caller needs to explain itself.
function Test-OutputDuration {
  param(
    [Parameter(Mandatory)][double]$GotSeconds,
    [Parameter(Mandatory)][double]$ExpectSeconds
  )
  $delta = $GotSeconds - $ExpectSeconds          # positive = output LONGER than declared
  $over  = Get-LengthOverAllowanceSeconds -ExpectSeconds $ExpectSeconds
  $under = Get-LengthUnderAllowanceSeconds
  $ok    = if ($delta -lt 0) { [Math]::Abs($delta) -le $under } else { $delta -le $over }
  [pscustomobject]@{
    Ok = $ok; Delta = $delta; OverAllowance = $over; UnderAllowance = $under
    # True when the output is legitimately long enough to be worth REPORTING but not failing -
    # the dvdvideo under-declaration. Callers log this so the overshoot is never silent.
    NotablyOver = ($ok -and $delta -gt $under)
  }
}

# The frame rate the manifest's two figures imply. $null when it cannot be derived - the caller
# should then probe the output rather than assume a rate.
function Get-ExpectedFps {
  param([double]$ExpectSeconds, [int]$ExpectFrames)
  if ($ExpectSeconds -gt 0 -and $ExpectFrames -gt 0) { return $ExpectFrames / $ExpectSeconds }
  return $null
}

# Judge a packet count, using the SAME allowance as the duration expressed in frames.
function Test-OutputFrameCount {
  param(
    [Parameter(Mandatory)][int]$GotFrames,
    [Parameter(Mandatory)][int]$ExpectFrames,
    [double]$ExpectSeconds = 0,
    [double]$Fps = 0
  )
  if ($Fps -le 0) {
    $derived = Get-ExpectedFps -ExpectSeconds $ExpectSeconds -ExpectFrames $ExpectFrames
    if ($null -ne $derived) { $Fps = $derived }
  }
  $overSec = if ($ExpectSeconds -gt 0) { Get-LengthOverAllowanceSeconds -ExpectSeconds $ExpectSeconds }
             else { Get-LengthUnderAllowanceSeconds }
  $underF  = Get-FrameUnderAllowance
  # NEVER TIGHTER than the 25 frames this guard has always allowed, whatever the arithmetic says -
  # a probe that returns a nonsense rate must not be able to make the gate stricter than it was.
  $overF   = [Math]::Max([double]$underF, $overSec * $Fps)
  $delta   = $GotFrames - $ExpectFrames
  $ok      = if ($delta -lt 0) { [Math]::Abs($delta) -le $underF } else { $delta -le $overF }
  [pscustomobject]@{
    Ok = $ok; Delta = $delta; OverAllowance = $overF; UnderAllowance = $underF; Fps = $Fps
    NotablyOver = ($ok -and $delta -gt $underF)
  }
}
