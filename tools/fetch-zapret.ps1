<#
  fetch-zapret.ps1 - zapret-win-bundle'dan yalnizca gereken dosyalari, sabit bir commit'ten indirir.

  - Indirme yeni ve bos bir klasore yapilir (klasor doluysa durur).
  - Her dosyanin git blob SHA1 degeri GitHub'in o commit icin verdigi agac ile karsilastirilir
    (dosya yolda bozulmadi / degistirilmedi mi?).
  - Her dosyanin SHA256 degeri ve WinDivert64.sys Authenticode imzasi yazdirilir.
  - Hicbir dosya CALISTIRILMAZ.
#>
param(
    [string]$Commit = '6eb463a6758fb48cd101bc55dfd057e6e9d98af1',
    [string]$Dest = (Join-Path (Split-Path $PSScriptRoot -Parent) "_download\zapret-win-bundle-$($Commit.Substring(0,7))")
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$files = @(
    'zapret-winws/winws.exe',
    'zapret-winws/cygwin1.dll',
    'zapret-winws/WinDivert.dll',
    'zapret-winws/WinDivert64.sys',
    'zapret-winws/windivert.filter/windivert_part.discord_media.txt',
    'zapret-winws/windivert.filter/windivert_part.stun.txt',
    'zapret-winws/windivert.filter/windivert_part.quic_initial_ietf.txt',
    'zapret-winws/files/quic_initial_www_google_com.bin'
)

if ((Test-Path $Dest) -and (Get-ChildItem $Dest -Force | Select-Object -First 1)) {
    throw "Hedef klasor bos degil: $Dest"
}
New-Item -ItemType Directory -Force -Path $Dest | Out-Null

$h = @{ 'User-Agent' = 'dpi-bypass-setup' }
$tree = Invoke-RestMethod -Headers $h "https://api.github.com/repos/bol-van/zapret-win-bundle/git/trees/${Commit}?recursive=1"
$blobs = @{}
foreach ($e in $tree.tree) { $blobs[$e.path] = $e }

function Get-GitBlobSha1([string]$path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    $head = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
    $sha = [Security.Cryptography.SHA1]::Create()
    [void]$sha.TransformBlock($head, 0, $head.Length, $null, 0)
    [void]$sha.TransformFinalBlock($bytes, 0, $bytes.Length)
    -join ($sha.Hash | ForEach-Object { $_.ToString('x2') })
}

$report = @()
$allOk = $true
foreach ($f in $files) {
    $rel = $f.Substring('zapret-winws/'.Length) -replace '/', '\'
    $out = Join-Path $Dest $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null
    Invoke-WebRequest -UseBasicParsing -Headers $h -OutFile $out "https://raw.githubusercontent.com/bol-van/zapret-win-bundle/$Commit/$f"
    $git = Get-GitBlobSha1 $out
    $expected = $blobs[$f].sha
    $match = ($git -eq $expected)
    if (-not $match) { $allOk = $false }
    $report += [pscustomobject]@{
        Dosya   = $rel
        Boyut   = (Get-Item $out).Length
        GitSHA1 = $(if ($match) { 'ESLESTI' } else { "UYUSMUYOR ($git != $expected)" })
        SHA256  = (Get-FileHash $out -Algorithm SHA256).Hash
    }
}

$report | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
foreach ($n in 'WinDivert64.sys', 'WinDivert.dll', 'winws.exe') {
    $s = Get-AuthenticodeSignature (Join-Path $Dest $n)
    Write-Host ("Imza {0,-16}: {1}  {2}" -f $n, $s.Status, $(if ($s.SignerCertificate) { $s.SignerCertificate.Subject } else { '' }))
}
$report | ConvertTo-Json | Set-Content -Path (Join-Path $Dest '..\fetch-report.json') -Encoding UTF8
Write-Host "Commit: $Commit"
Write-Host "Klasor: $Dest"
if (-not $allOk) { throw 'En az bir dosyanin git hash degeri eslesmedi. Dosyalari KULLANMAYIN.' }
