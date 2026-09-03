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
