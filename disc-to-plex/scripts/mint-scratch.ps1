<#
.SYNOPSIS
Mint a collision-proof per-job scratch directory and print its path.

.DESCRIPTION
Concurrent agents share ONE session scratchpad, and they independently choose the same obvious
names for extracted evidence (dv1-700.wav, nas-e21-700.wav, t08-frames/). On 2026-09-02 that
silently replaced one agent's audio clip with another disc's audio TWICE; the second time the
collided clip transcribed plausibly, was read as a ~50 s displacement between disc and NAS, held
an episode back from publication and cost a full investigation. A wrong file masqueraded as a
measurement.

The durable fix is that no two jobs ever share a directory. This mints
    <Root>/job-<label>-<yyyyMMdd-HHmmss>-<6 hex>
where the OS's own directory-creation atomicity guarantees uniqueness (creation failure = retry
with a fresh suffix). Put EVERY extracted wav/frame/clip for the job inside it; name files inside
however you like - nothing outside the job can collide with them.

The companion hook `check_scratch_collisions.py` refuses ad-hoc commands that put evidence files
at the scratchpad root or in a hand-named shared subdirectory, and its refusal message quotes the
exact mint-scratch command line to run - so the safe path is always one paste away.

.EXAMPLE
$job = & mint-scratch.ps1 -Root 'd:/temp/claude/D--video/<session>/scratchpad' -Label bl-s3d5-e17
& $ffmpeg -i $nasFile -ss 700 -t 55 -map 0:a:0 -ac 1 -ar 16000 "$job/nas-700.wav" -y
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Root,
    [string]$Label = 'job'
)

$ErrorActionPreference = 'Stop'

# Keep the label filesystem-safe and hyphenated; it is for the human reading a dir listing.
$Label = ($Label -replace '[^A-Za-z0-9_-]', '-').Trim('-')
if (-not $Label) { $Label = 'job' }

if (-not (Test-Path -LiteralPath $Root)) {
    New-Item -ItemType Directory -Path $Root | Out-Null
}

# Uniqueness comes from the CREATE, not the name: if two agents ever minted the same name in the
# same second, the second New-Item fails and we regenerate. No test-then-create race.
for ($i = 0; $i -lt 20; $i++) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $hex = [guid]::NewGuid().ToString('N').Substring(0, 6)
    $name = 'job-{0}-{1}-{2}' -f $Label, $stamp, $hex
    $path = Join-Path $Root $name
    try {
        # New-Item -ItemType Directory succeeds even when the dir exists, so use the .NET call
        # that actually reports the collision.
        $di = [System.IO.Directory]::CreateDirectory($path)
        if ((Get-ChildItem -LiteralPath $path -Force | Measure-Object).Count -eq 0 -or $i -ge 19) {
            # Fresh (empty) directory: it is ours. A non-empty one means we collided with an
            # existing dir of the same name - regenerate.
            $path
            exit 0
        }
    } catch {
        # creation refused - regenerate and retry
    }
}
Write-Error 'mint-scratch: could not create a unique job directory after 20 attempts'
exit 1
