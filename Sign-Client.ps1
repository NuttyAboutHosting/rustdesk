#requires -Version 7.0
<#
.SYNOPSIS
    On-demand Authenticode signing of the NAH Support client self-extractors
    (NahSupport.exe / NahSupportTechnician.exe) via Azure Trusted Signing.

.DESCRIPTION
    DELIBERATE RELEASE ACTION - never part of a build. It signs the OUTER
    self-extracting packer(s) you point it at: the file a customer downloads.
    That outer signature is what clears the Windows SmartScreen "unknown
    publisher" warning (publisher shows as the cert subject instead).

    The INNER rustdesk.exe is packed inside and is signed at build time by the
    CI signing job (.github/workflows/nah-build.yml, dispatched with sign=true).
    This script is the local/manual path for signing the outer wrapper of a
    build you already have on disk (e.g. a CI artifact you downloaded).

    Auth is DefaultAzureCredential - NO keys are stored. First:
        az login
        az account set --subscription <your signing subscription>

    Trusted Signing coordinates come from parameters, defaulting to environment
    variables, so no infrastructure name is committed to this public repo:
        NAH_SIGN_ENDPOINT   e.g. https://<region>.codesigning.azure.net/
        NAH_SIGN_ACCOUNT    Trusted Signing account name
        NAH_SIGN_PROFILE    certificate profile name

.PARAMETER Path
    Files, or a folder to expand to NahSupport*.exe. Default: current directory.

.PARAMETER Verify
    After signing, verify the chain ends at -ExpectedSubject.

.EXAMPLE
    $env:NAH_SIGN_ENDPOINT = 'https://<region>.codesigning.azure.net/'
    $env:NAH_SIGN_ACCOUNT  = '<account>'
    $env:NAH_SIGN_PROFILE  = '<profile>'
    az login
    pwsh .\Sign-Client.ps1 -Path C:\Users\me\Downloads\NahSupport-release -Verify
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Path,
    [string]$Endpoint        = $env:NAH_SIGN_ENDPOINT,
    [string]$Account         = $env:NAH_SIGN_ACCOUNT,
    [string]$CertProfile     = $env:NAH_SIGN_PROFILE,
    [string]$ExpectedSubject = 'NUTTY ABOUT HOSTING LTD',
    [string[]]$Include       = @('NahSupport*.exe'),
    [switch]$Verify,
    [string]$DlibVersion     = '1.0.95'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$TimestampUrl = 'http://timestamp.acs.microsoft.com'
$CacheDir     = Join-Path $PSScriptRoot '.trusted-signing-cache'

if (-not $Endpoint)    { throw "Missing endpoint. Pass -Endpoint or set `$env:NAH_SIGN_ENDPOINT." }
if (-not $Account)     { throw "Missing account. Pass -Account or set `$env:NAH_SIGN_ACCOUNT." }
if (-not $CertProfile) { throw "Missing profile. Pass -CertProfile or set `$env:NAH_SIGN_PROFILE." }
if (-not $Path -or $Path.Count -eq 0) { $Path = @('.') }

function Write-Step([string]$m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

function Find-SignTool {
    $roots = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'),
        (Join-Path $env:ProgramFiles         'Windows Kits\10\bin')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    if (-not $roots) { throw 'Windows SDK bin folder not found - install the Windows 10/11 SDK.' }
    $best = Get-ChildItem -Path $roots -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } |
        Sort-Object @{ Expression = { try { [version]$_.Directory.Parent.Name } catch { [version]'0.0' } } } -Descending |
        Select-Object -First 1
    if (-not $best) { throw 'x64 signtool.exe not found under the Windows SDK.' }
    Write-Host "signtool : $($best.FullName)"
    return $best.FullName
}

function Resolve-Dlib {
    $find = {
        Get-ChildItem -Path $CacheDir -Recurse -Filter 'Azure.CodeSigning.Dlib.dll' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\bin\\x64\\' } | Select-Object -First 1
    }
    $found = & $find
    if ($found) { Write-Host "dlib     : $($found.FullName) (cached)"; return $found.FullName }
    [System.IO.Directory]::CreateDirectory($CacheDir) | Out-Null
    $nuget = Join-Path $CacheDir 'nuget.exe'
    if (-not (Test-Path -LiteralPath $nuget)) {
        Write-Host 'Bootstrapping nuget.exe into cache...'
        Invoke-WebRequest -Uri 'https://dist.nuget.org/win-x86-commandline/latest/nuget.exe' -OutFile $nuget
    }
    $nugetArgs = @('install', 'Microsoft.Trusted.Signing.Client')
    if ($DlibVersion) { $nugetArgs += @('-Version', $DlibVersion) }
    $nugetArgs += @('-OutputDirectory', $CacheDir, '-DirectDownload', '-NonInteractive',
        '-Source', 'https://api.nuget.org/v3/index.json')
    Write-Host "Restoring Microsoft.Trusted.Signing.Client $DlibVersion ..."
    & $nuget @nugetArgs 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "nuget restore failed (exit $LASTEXITCODE)." }
    $found = & $find
    if (-not $found) { throw 'Azure.CodeSigning.Dlib.dll (bin\x64) not found after restore.' }
    Write-Host "dlib     : $($found.FullName)"
    return $found.FullName
}

# --- resolve files -----------------------------------------------------------
$files = [System.Collections.Generic.List[string]]::new()
foreach ($p in $Path) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Path not found: $p" }
    $item = Get-Item -LiteralPath $p
    if ($item.PSIsContainer) {
        Get-ChildItem -Path (Join-Path $item.FullName '*') -Include $Include -File -ErrorAction SilentlyContinue |
            ForEach-Object { $files.Add($_.FullName) }
    }
    else { $files.Add($item.FullName) }
}
$files = @($files | Sort-Object -Unique)
if ($files.Count -eq 0) { throw "No client exe found under: $($Path -join ', ')  (looking for: $($Include -join ', '))" }

Write-Step "Azure Trusted Signing - $($files.Count) file(s)"
$files | ForEach-Object { Write-Host "  $_" }

$signtool = Find-SignTool
$dlib     = Resolve-Dlib

# Runtime metadata json (nothing infrastructure-specific is committed).
$meta = [ordered]@{ Endpoint = $Endpoint; CodeSigningAccountName = $Account; CertificateProfileName = $CertProfile }
$metaPath = Join-Path ([System.IO.Path]::GetTempPath()) "nah-trusted-signing-$PID.json"
($meta | ConvertTo-Json) | Set-Content -LiteralPath $metaPath -Encoding utf8

try {
    $signArgs = @(
        'sign', '/v', '/fd', 'SHA256',
        '/tr', $TimestampUrl, '/td', 'SHA256',
        '/dlib', $dlib, '/dmdf', $metaPath
    ) + $files

    if ($PSCmdlet.ShouldProcess("$($files.Count) file(s)", 'Authenticode sign (Trusted Signing)')) {
        Write-Step 'Signing'
        for ($attempt = 1; ; $attempt++) {
            $out = & $signtool @signArgs 2>&1
            $out | ForEach-Object { Write-Host $_ }
            if ($LASTEXITCODE -eq 0) { break }
            $auth = ($out -join "`n") -match '(?i)\b403\b|forbidden|authorizationfailed|AADSTS|DefaultAzureCredential|not have authorization'
            if ($attempt -lt 2 -and $auth) {
                Write-Warning 'Auth error - likely role propagation. Waiting 30s and retrying once...'
                Start-Sleep -Seconds 30
                continue
            }
            throw "signtool sign failed (exit $LASTEXITCODE) after $attempt attempt(s)."
        }
        Write-Host "Signed $($files.Count) file(s)." -ForegroundColor Green

        if ($Verify) {
            Write-Step 'Verifying'
            foreach ($f in $files) {
                $v = & $signtool verify /pa /v $f 2>&1
                if ($LASTEXITCODE -ne 0) { $v | ForEach-Object { Write-Host $_ }; throw "Verification FAILED: $f" }
                if (($v -join "`n") -notmatch [regex]::Escape($ExpectedSubject)) {
                    $v | ForEach-Object { Write-Host $_ }
                    throw "Signed, but chain does not end at '$ExpectedSubject': $f"
                }
                Write-Host "  OK  $([IO.Path]::GetFileName($f))  ->  $ExpectedSubject" -ForegroundColor Green
            }
        }
        Write-Host "`nDone." -ForegroundColor Green
    }
    else {
        Write-Host "`n[WhatIf] signtool $($signArgs -join ' ')" -ForegroundColor Yellow
    }
}
finally {
    Remove-Item -LiteralPath $metaPath -Force -ErrorAction SilentlyContinue
}
