<#
  Tests for fix-sentence-case.ps1. Run: pwsh -NoProfile -File fix-sentence-case.tests.ps1
  WHAT THESE HAVE TO PROVE:
    - it capitalises real sentence starts, including the Clayhanger line that prompted the work;
    - it NEVER lowercases: proper nouns the LLM correction pass fixed, and ALL-CAPS title cards,
      survive untouched. That is the one way this pass could destroy work rather than add to it;
    - a cue wrapped mid-sentence does not gain a capital in its middle;
    - only a machine transcript is eligible - an OCR sidecar is the disc's own subtitles;
    - timestamps, indices and blank lines are byte-identical afterwards;
    - a second run is a no-op.
#>
$ErrorActionPreference = 'Stop'
$fails = 0
function Check($n, $got, $want) {
  if ("$got" -ceq "$want") { Write-Output "  ok   $n" }
  else { Write-Output "  FAIL $n`n         got  '$got'`n         want '$want'"; $script:fails++ }
}

# Pull the function out of the script so the pure logic can be tested without touching files.
$src = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fix-sentence-case.ps1') -Raw
$fn = ([regex]::Match($src, '(?s)function Set-SentenceCase.*?\n\}\n')).Value
if (-not $fn) { Write-Output 'FAIL could not extract Set-SentenceCase'; exit 1 }
. ([scriptblock]::Create($fn))

Write-Output '1. the line that prompted this'
Check 'Clayhanger cue 111' `
  (Set-SentenceCase 'the boat. why do they bring clay all the way from rung corn? no they don''t bring it from rung corn.') `
  'The boat. Why do they bring clay all the way from rung corn? No they don''t bring it from rung corn.'
# NOTE: "rung corn" stays wrong here ON PURPOSE - that is a proper-noun fix and belongs to the LLM
# correction pass with a widened lexicon, not to a casing regex. This test documents the boundary.

Write-Output ''
Write-Output '2. it must never LOWERCASE anything'
Check 'ALL-CAPS title card survives'      (Set-SentenceCase 'CLAYHANGER') 'CLAYHANGER'
Check 'proper nouns mid-sentence survive' (Set-SentenceCase 'they bring it from Cornwall. it comes round by the sea.') 'They bring it from Cornwall. It comes round by the sea.'
Check 'a corrected name is not flattened' (Set-SentenceCase 'and Stifford said so.') 'And Stifford said so.'
Check 'mixed caps inside a word'          (Set-SentenceCase 'the McGoohan episode.') 'The McGoohan episode.'

Write-Output ''
Write-Output '3. sentence starts, and things that only look like them'
Check 'after ? and !'            (Set-SentenceCase 'what? no! really.') 'What? No! Really.'
Check 'a comma is NOT a start'   (Set-SentenceCase 'well, no.') 'Well, no.'
Check 'a colon is NOT a start'   (Set-SentenceCase 'listen: no.') 'Listen: no.'
Check 'closing quote intervenes' (Set-SentenceCase '"stop." he said.') '"Stop." He said.'
Check 'ellipsis'                 (Set-SentenceCase 'well... maybe.') 'Well... Maybe.'
Check 'decimal is not a start'   (Set-SentenceCase 'it cost 3.50 today.') 'It cost 3.50 today.'

Write-Output ''
Write-Output '4. the first-person pronoun'
Check 'bare i'      (Set-SentenceCase 'and i said no.')      'And I said no.'
Check "i'm / i'll"  (Set-SentenceCase 'so i''m off and i''ll go.') 'So I''m off and I''ll go.'
Check 'not inside a word' (Set-SentenceCase 'the big list.')  'The big list.'
Check 'not in i.e.-like runs' (Set-SentenceCase 'the hi there.') 'The hi there.'

Write-Output ''
Write-Output '5. a cue wrapped mid-sentence must not gain an interior capital'
$wrapped = "where does that clay come from? what? that`nclay? runcorn. can't you see painted all"
Check 'wrapped cue' (Set-SentenceCase $wrapped) "Where does that clay come from? What? That`nclay? Runcorn. Can't you see painted all"

Write-Output ''
Write-Output '6. idempotent'
$once = Set-SentenceCase 'the boat. why not?'
Check 'second pass changes nothing' (Set-SentenceCase $once) $once

Write-Output ''
if ($fails) { Write-Output "$fails test(s) FAILED"; exit 1 }
Write-Output 'all tests passed'
exit 0
