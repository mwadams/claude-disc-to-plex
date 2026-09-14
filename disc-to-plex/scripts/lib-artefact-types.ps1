# The CLOSED list of file types that may reach the library, and the test the publish path uses.
#
# WHY A POSITIVE RULE AND NOT A SUFFIX BLOCKLIST. When transcode.ps1's expectSeconds/expectFrames
# guard fires it moves the bad output aside as `<name>.mkv.wrong-length`, precisely so the resume
# check cannot mistake it for a good encode. On 2026-09-02/03 two such quarantine artefacts reached
# the NAS (The Champions S00E05 `.wrong-length`, 406 MB, and S00E06 `.pre-retime-short`, 101 MB):
# publish-work.ps1's partial-file guard only ffprobes files whose EXTENSION is `.mkv`, and a file
# named `....mkv.wrong-length` has extension `.wrong-length`, so it was neither duration-checked
# nor excluded - robocopy /E simply copied it. Nothing in this pipeline may delete from the NAS,
# so each one becomes a hand-removal chore for the user.
#
# A blocklist of quarantine suffixes cannot fix this class of defect, only that instance of it:
# `.pre-retime-short` appears in NO script at all - it was an ad-hoc "move it aside" name invented
# during a retime fix, and the next incident will invent another. The quarantine namespace is
# open-ended by nature. The ARTEFACT namespace is closed, small, and changes only when the
# pipeline deliberately gains a new output type - which is when this list gets its new entry.
# This is also exactly the working-set contract CLAUDE.md already states in prose: "Only finished
# library artefacts belong there: the .mkv, its .srt, its sidecar .json."
#
# The list, and why each entry is there:
#   .mkv .mp4 .avi        media (mkv is the pipeline's output; mp4/avi are legacy library media)
#   .srt                  OCR/transcription sidecar subtitles (<name>.eng.srt)
#   .json                 provenance / corrections sidecars (<name>.eng.provenance.json etc.)
#   .nfo .jpg .jpeg .png  metadata and artwork
#
# Compared on the FINAL extension only ([IO.Path]::GetExtension), which is exactly the property
# that let the quarantine files through the old .mkv-only check: `X.mkv.wrong-length` has final
# extension `.wrong-length` and fails this test no matter what suffix the next incident invents.

function Test-LibraryArtefact {
  param([Parameter(Mandatory)][string]$Name)
  $ext = [IO.Path]::GetExtension($Name).ToLowerInvariant()
  return @('.mkv','.mp4','.avi','.srt','.json','.nfo','.jpg','.jpeg','.png') -contains $ext
}

# IS THIS LOCAL FILE INSIDE WHAT THE OPERATOR CONFIRMED?
#
# $Covers is a reclaim artefact's coversOutputs: anchored, regex-escaped MEDIA leaf names, exactly the
# files put in front of the operator. Empty = the whole work. ONE implementation, two callers
# (_release-published.ps1 deciding what it may delete, _reclaim-loop.ps1 deciding whether the
# confirmed part is done), because a second copy of this rule is how the two would disagree.
#
# 2026-09-14: the per-work release took only the WORK NAME and never read coversOutputs, so Intergalactic
# E05-E08 lost their local copies on a confirmation given for E01-E04, and an approval scoped to Xena
# Series 1 would have released Series 2 S02E01-E04 the same way.
#
# A media file is in scope only if ITS OWN leaf matches. A sidecar (.eng.srt, .provenance.json, ...)
# belongs to the media file named by its LONGEST dotted prefix that exists locally, and follows that
# file's verdict - so "Part 1.5.eng.srt" follows "Part 1.5.mkv", never a confirmed "Part 1.mkv". Only
# when the owner is already gone locally does any prefix naming a confirmed media leaf count.
function Test-LeafInCovers {
  param([Parameter(Mandatory)][string]$Name, [string[]]$Covers = @(), [string[]]$Siblings = @())
  if (-not @($Covers).Count) { return $true }
  $media = @('.mkv', '.mp4', '.avi', '.m4v')
  $isCovered = { param($leaf) @($Covers | Where-Object { $leaf -match $_ }).Count -gt 0 }
  if ($media -contains [IO.Path]::GetExtension($Name).ToLowerInvariant()) { return (& $isCovered $Name) }
  $stems = @()
  $i = $Name.LastIndexOf('.')
  while ($i -gt 0) { $stems += $Name.Substring(0, $i); $i = $Name.LastIndexOf('.', $i - 1) }
  foreach ($s in $stems) {
    $owners = @($media | ForEach-Object { $s + $_ } | Where-Object { $Siblings -contains $_ })
    if ($owners.Count) { return (@($owners | Where-Object { & $isCovered $_ }).Count -gt 0) }
  }
  foreach ($s in $stems) { if (@($media | Where-Object { & $isCovered ($s + $_) }).Count) { return $true } }
  return $false
}
