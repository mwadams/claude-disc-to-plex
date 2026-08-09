<#
  register-makemkv.ps1 — set MakeMKV's registration key (the free beta key rotates ~every 2
  months). The CLI (makemkvcon) reads the same key the GUI uses, stored in settings.conf.

  Usage:
    pwsh -File register-makemkv.ps1 -Key "T-....."     # paste a key
    pwsh -File register-makemkv.ps1 -Fetch             # pull the current beta key from the forum

  The community-maintained current beta key lives at:
    https://forum.makemkv.com/forum/viewtopic.php?t=20579

  NOTE: this overwrites app_Key. If you own a PURCHASED MakeMKV license, do NOT run this —
  it would replace your permanent key with the rotating beta key.
#>
param([string]$Key, [switch]$Fetch)
$ErrorActionPreference = 'Stop'
$thread = "https://forum.makemkv.com/forum/viewtopic.php?t=20579"

if($Fetch -and -not $Key){
  try { $html = (Invoke-WebRequest -Uri $thread -UseBasicParsing -TimeoutSec 30).Content } catch { throw "Couldn't fetch $thread : $($_.Exception.Message)" }
  # Beta keys look like  T-  followed by a long base64url-ish string.
  $m = [regex]::Matches($html, 'T-[A-Za-z0-9@_%+\-/=]{40,}')
  if($m.Count -gt 0){ $Key = $m[0].Value } else { throw "No key pattern found on the page — the forum format may have changed; copy the key manually and pass -Key." }
  Write-Host ("Fetched key: {0}… ({1} chars)" -f $Key.Substring(0,[Math]::Min(10,$Key.Length)), $Key.Length)
}
if(-not $Key){ throw "Provide -Key '<beta key>' (from $thread) or use -Fetch." }

$conf = Join-Path $env:APPDATA "MakeMKV\settings.conf"
New-Item -ItemType Directory -Force (Split-Path $conf) | Out-Null
$lines = if(Test-Path $conf){ @(Get-Content $conf | Where-Object { $_ -notmatch '^\s*app_Key\s*=' }) } else { @() }
$lines += ('app_Key = "{0}"' -f $Key)
Set-Content $conf $lines -Encoding UTF8
Write-Host "Wrote app_Key to $conf" -ForegroundColor Green

# Verify — a registration problem shows up as a MSG line when makemkvcon starts.
$mk = @("C:\Program Files (x86)\MakeMKV\makemkvcon64.exe","C:\Program Files\MakeMKV\makemkvcon64.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if($mk){
  $out = & $mk -r --cache=1 info disc:9999 2>&1
  if($out -match 'registration|expired|shareware|evaluation'){ Write-Warning "Still reporting a registration problem: $($out | Select-String 'registration|expired|shareware|evaluation' | Select-Object -First 1)" }
  else { Write-Host "Registration looks OK." -ForegroundColor Green }
}
