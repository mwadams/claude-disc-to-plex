# Run ONE machine-transcribed .srt through a Claude correction pass, and report what it cost.
#
# WHY THIS EXISTS
# ---------------
# faster-whisper produces fluent text with homophone errors a dictionary cannot catch, because
# both spellings are real words. Measured in this library's own output: "Patrick McGoon" for
# McGoohan, "send bag" for sandbag, "watered by the chef" for "wanted by the chief". A reader
# spots each instantly; no spell-checker ever will.
#
# THE DANGER IS THE SAME THING THAT MAKES IT WORK. A language model writes fluent English, so a
# hallucinated line is indistinguishable from a correct one across 700 cues nobody will re-read.
# So the model is never allowed to return a rewritten transcript. It returns a LIST OF
# SUBSTITUTIONS, and apply-srt-corrections.py refuses any whose `from` text does not actually
# occur in the cue it names - a proposal that cannot be located was not read off this transcript.
# Timings and cue count are copied through untouched; the original is kept; a diff is written.
#
# INVOCATION MATTERS. Plain `claude -p` boots the whole agent harness and took over eight minutes
# on 60 lines without returning. With `--model haiku --allowed-tools "" --output-format json` the
# same input came back in 50 seconds. Tools are useless here - this is a pure reading task.
#
#   pwsh -File correct-srt.ps1 -Srt "<file.eng.srt>" [-DryRun] [-Model haiku]
param(
  [Parameter(Mandatory)][string]$Srt,
  [string]$Model = 'haiku',
  # Reasoning effort. Measured on Danger Man S03E07 (766 cues): the default produced 12,635 output
  # tokens of which 12,159 - NINETY-SIX PER CENT - were thinking, to emit ten short substitutions.
  # This is a reading task, not a reasoning one, so the default is the wrong trade here.
  [ValidateSet('low','medium','high','xhigh','max')][string]$Effort = 'low',
  [double]$MaxChangePct = 8.0,
  [switch]$DryRun,
  [string]$Work = 'd:/temp/claude/srt-correct'
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Srt)) { throw "no such subtitle: $Srt" }
New-Item -ItemType Directory -Force $Work | Out-Null

# SPACE-FREE WORKING NAMES. The payload path is handed to bash, and every episode name here
# contains spaces ("Danger Man - S03E07 - ..."). Quoting that through PowerShell -> wsl ->
# bash -lc -> cat is three nested layers, and it silently split the path on the first
# attempt. Sanitising the name removes the problem rather than out-quoting it.
$stem   = ([IO.Path]::GetFileNameWithoutExtension($Srt) -replace '[^A-Za-z0-9]', '_')
$review = Join-Path $Work "$stem.review.txt"
$reply  = Join-Path $Work "$stem.reply.json"
$fixes  = Join-Path $Work "$stem.fixes.json"

# ---- 1. prepare the review text (cues + this episode's cast list + suspect-word hints)
& python 'D:/video/.claude/skills/disc-to-plex/scripts/prepare-srt-review.py' $Srt --out $review | Out-Host
if (-not (Test-Path $review)) { throw 'prepare-srt-review.py produced nothing' }

# ---- 2. put the INSTRUCTIONS in the input, not on the command line.
# The prompt contains braces, quotes and brackets; threading that through PowerShell -> wsl ->
# bash -lc -> claude is three layers of quoting and a reliable source of silent corruption. The
# instruction block goes at the top of the stdin payload instead, and -p stays trivial.
$instr = @'
You are proofreading a MACHINE TRANSCRIPT of spoken dialogue. Below the marker line is the
episode's cast list (spell those names correctly) and then the transcript, one cue per line as
"<cue number>|<text>".

Return ONLY a JSON array. No prose, no markdown fence. Each element:
  {"cue": <number>, "from": "<text exactly as it appears now>", "to": "<corrected text>", "why": "<short reason>"}

RULES
- Correct only what is WRONG: mis-heard words that make no sense in context, and misspelled
  character or actor names. "storks" heard as "stalks" is the target case.
- The "from" string MUST be copied character-for-character from the cue text. If you cannot quote
  it exactly, omit the correction. A proposal that does not match is discarded anyway.
- Do NOT change style, punctuation, capitalisation, contractions or informal speech. This is
  transcribed speech, not prose. Do not tidy it.
- Do NOT merge, split, reorder or re-time cues. Text substitutions only.
- If a line is merely odd but could be what was said, LEAVE IT. Silence is better than invention.
- If nothing is wrong, return []

--- INPUT FOLLOWS ---
'@
$payload = Join-Path $Work "$stem.payload.txt"
Set-Content -LiteralPath $payload -Value ($instr + "`n" + (Get-Content -LiteralPath $review -Raw)) -Encoding UTF8

# ---- 3. ask Claude, via WSL. stdin/stdout only: nothing crosses the Windows/WSL path boundary,
# so there is no /mnt translation and nothing for MSYS to rewrite.
# Translate D:/temp/... to /mnt/d/temp/... ourselves: one substitution, no shell interpolation,
# and the sanitised stem above guarantees there are no spaces left to split on.
$wslPayload = ($payload -replace '\\', '/') -replace '^([A-Za-z]):', '/mnt/$1'
$wslPayload = $wslPayload.Substring(0,5) + $wslPayload.Substring(5,1).ToLower() + $wslPayload.Substring(6)
$cmd = "cat $wslPayload | claude -p --model $Model --effort $Effort --allowed-tools '' --output-format json 'Follow the instructions at the top of the input.'"
$sw = [Diagnostics.Stopwatch]::StartNew()
$raw = & wsl -- bash -lc $cmd 2>&1 | Out-String
$sw.Stop()
Set-Content -LiteralPath $reply -Value $raw -Encoding UTF8

# ---- 4. pull the JSON array out of the envelope, and report USAGE (tokens, not dollars - this
# is an allowance, and thinking tokens have dominated every measurement so far).
try { $env0 = $raw | ConvertFrom-Json } catch { throw "CLI did not return JSON. First 200 chars: $($raw.Substring(0,[Math]::Min(200,$raw.Length)))" }
$u = $env0.usage
"  model {0}   {1:N1}s   in {2}  out {3} (thinking {4})  cacheR {5}  cacheW {6}" -f `
  $Model, $sw.Elapsed.TotalSeconds, $u.input_tokens, $u.output_tokens,
  $u.output_tokens_details.thinking_tokens, $u.cache_read_input_tokens, $u.cache_creation_input_tokens | Out-Host

$body = "$($env0.result)"
$m = [regex]::Match($body, '\[[\s\S]*\]')       # tolerate a stray markdown fence
if (-not $m.Success) { throw "no JSON array in the reply. Body: $($body.Substring(0,[Math]::Min(300,$body.Length)))" }
Set-Content -LiteralPath $fixes -Value $m.Value -Encoding UTF8
$count = (@($m.Value | ConvertFrom-Json)).Count
"  proposed $count correction(s) -> $fixes" | Out-Host

# ---- 5. apply, guarded. A refusal here is the system working, not a setback.
$applyArgs = @('D:/video/.claude/skills/disc-to-plex/scripts/apply-srt-corrections.py', $Srt,
               '--corrections', $fixes, '--max-change-pct', $MaxChangePct)
if ($DryRun) { $applyArgs += '--dry-run' }
& python @applyArgs | Out-Host
exit $LASTEXITCODE
