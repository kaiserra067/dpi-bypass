<#
  lib.ps1 - install / uninstall / health-check / select-strategy / diagnose betiklerinin ortak parcalari.
  Yukleme:  . (Join-Path $PSScriptRoot 'lib.ps1')
#>

$Cfg        = Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
$InstallDir = Join-Path $env:ProgramFiles 'dpi-bypass'
$DataDir    = Join-Path $env:ProgramData 'dpi-bypass'
$StateDir   = Join-Path $DataDir 'state'
$LogDir     = Join-Path $DataDir 'logs'
$BackupPath = Join-Path $StateDir 'backup.json'
$StrategyPath  = Join-Path $StateDir 'strategy.json'
$ExclusionMark = Join-Path $StateDir 'defender-exclusion'
$Curl       = Join-Path $env:SystemRoot 'System32\curl.exe'
$DnsServers = @($Cfg.DnsV4) + @($Cfg.DnsV6)

# bin\ altindaki dosyalar ve SHA256 degerleri (zapret-win-bundle 6eb463a; WinDivert 2.2 Cloudveil imzali).
$BinFiles = [ordered]@{
    'winws.exe'                                       = '2DA71E80878DC270AC83F5893ECBB841F9752A57F1DA8FF9325636B4346BC632'
    'cygwin1.dll'                                     = '103104A52E5293CE418944725DF19E2BF81AD9269B9A120D71D39028E821499B'
    'WinDivert.dll'                                   = '6110BFA44667405179C3E15E12AF1B62037E447ED59B054B19042032995E6C7E'
    'WinDivert64.sys'                                 = 'E69B5BA3F0CD6CFB2983E442636E7F0B342B61B15264B0328317D4559C82CF50'
    'files\quic_initial_www_google_com.bin'           = 'F4589C57749F956BB30538197A521D7005F8B0A8723B4707E72405E51DDAC50A'
    'windivert.filter\windivert_part.discord_media.txt' = '2F2DEAF49ED68EB684258497134181753188F2B475161DEB244488A53872B7C5'
}

# Denenecek stratejiler, sirayla. Ilk olarak tum Discord testlerini gecen secilir.
$FakeTls = '--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com'
$Strategies = [ordered]@{
    'multisplit-seqovl'          = @('--dpi-desync=multisplit', '--dpi-desync-split-pos=2,midsld', '--dpi-desync-split-seqovl=1')
    'fake-md5sig'                = @('--dpi-desync=fake', '--dpi-desync-fooling=md5sig', '--dpi-desync-repeats=6', $FakeTls)
    'fake-autottl'               = @('--dpi-desync=fake', '--dpi-desync-autottl=2', '--dpi-desync-repeats=6', $FakeTls)
    'fake-multisplit-autottl'    = @('--dpi-desync=fake,multisplit', '--dpi-desync-split-pos=1,midsld', '--dpi-desync-autottl=2', '--dpi-desync-repeats=6', $FakeTls)
    'fake-multidisorder-autottl' = @('--dpi-desync=fake,multidisorder', '--dpi-desync-split-pos=1,midsld', '--dpi-desync-autottl=2', '--dpi-desync-repeats=6', $FakeTls)
    'fake-badseq'                = @('--dpi-desync=fake', '--dpi-desync-fooling=badseq', '--dpi-desync-repeats=6', $FakeTls)
    'fake-ts'                    = @('--dpi-desync=fake', '--dpi-desync-fooling=ts', '--dpi-desync-repeats=6', $FakeTls)
    'fakedsplit-md5sig'          = @('--dpi-desync=fakedsplit', '--dpi-desync-split-pos=1,midsld', '--dpi-desync-fooling=md5sig')
    'hostfakesplit-md5sig'       = @('--dpi-desync=hostfakesplit', '--dpi-desync-fooling=md5sig')
    'multidisorder'              = @('--dpi-desync=multidisorder', '--dpi-desync-split-pos=1,midsld')
    'multisplit'                 = @('--dpi-desync=multisplit', '--dpi-desync-split-pos=1,midsld')
}

# Her hizmet icin strateji ayri secilir: Discord (Cloudflare) ile Roblox (kendi sunuculari + Akamai) farkli DPI
# yontemlerine farkli tepki verebilir. Her grubun tum adresleri gecmeli.
$Checks = [ordered]@{
    # Discord guncelleyicisi TLS 1.2 kullanir; ikisi de gecmeli.
    Discord = @(
        @{ Url = 'https://discord.com/';         Tls12 = $false }
        @{ Url = 'https://gateway.discord.gg/';  Tls12 = $false }
        @{ Url = 'https://updates.discord.com/'; Tls12 = $true }
        @{ Url = 'https://discord.com/';         Tls12 = $true }
        @{ Url = 'https://cdn.discordapp.com/';  Tls12 = $false }
    )
    # rbxcdn.com (Akamai) oyun dosyalarini (c0-c7), gorselleri (t0-t7, tr) ve sitenin js/css'ini tasir.
    # Engellenirse uygulama acilir ama oyuna girilemez, site de yuklenmez.
    Roblox = @(
        @{ Url = 'https://www.roblox.com/';      Tls12 = $false }
        @{ Url = 'https://gamejoin.roblox.com/'; Tls12 = $false }
        @{ Url = 'https://c0.rbxcdn.com/';       Tls12 = $false }
        @{ Url = 'https://tr.rbxcdn.com/';       Tls12 = $false }
        @{ Url = 'https://js.rbxcdn.com/';       Tls12 = $false }
        @{ Url = 'https://setup.rbxcdn.com/';    Tls12 = $true }
    )
}
$HostLists = [ordered]@{ Discord = 'hostlist.txt'; Roblox = 'hostlist-roblox.txt' }

# Roblox oyun sunuculari (AS22697). Oyun trafigi bu adreslere 49152-65535 UDP portlarindan gider;
# baglantinin ilk paketlerinden once sahte paket gonderilir.
$RobloxGameNets  = @('128.116.0.0/17', '103.140.28.0/23', '141.193.3.0/24', '205.201.62.0/24', '2620:2b:e000::/48', '2620:135:6000::/40')
$RobloxGameFilter = Join-Path $InstallDir 'windivert_part.roblox_game.txt'

# Ayni anda WinDivert kullanan diger DPI araclari (calisirlarsa birbirini bozar).
$ConflictPattern = '(?i)\\(winws|goodbyedpi)\.exe'

# --- Log ------------------------------------------------------------------------
$script:LogFile = $null
function Start-Log([string]$Name) {
    New-Item -ItemType Directory -Force -Path $LogDir, $StateDir | Out-Null
    $script:LogFile = Join-Path $LogDir ('{0}-{1}.log' -f $Name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
function Log([string]$m) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Write-Host $line
    if ($script:LogFile) { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 }
}

function Assert-Admin {
    $id = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $id.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Yonetici olarak calistirilmali.' }
}

# --- Dosyalar -------------------------------------------------------------------
function Test-BinFiles([string]$Dir) {
    $problems = @()
    foreach ($f in $BinFiles.Keys) {
        $p = Join-Path $Dir "bin\$f"
        if (-not (Test-Path $p)) { $problems += "$f (yok)"; continue }
        if ((Get-FileHash $p -Algorithm SHA256).Hash -ne $BinFiles[$f]) { $problems += "$f (hash uyusmuyor)" }
    }
    $problems
}

# --- HTTPS testleri (curl.exe: Windows 10 1803+ ile gelir) -------------------------
# Sertifika iptal listesine ulasilamamasi Discord engeli sanilmasin. Eski curl (< 7.70) bu secenegi bilmez.
$CurlBaseArgs = @('-s', '-o', 'NUL')
try {
    $curlVer = [version](((& $Curl --version 2>$null) | Select-Object -First 1) -split ' ')[1]
    if ($curlVer -ge [version]'7.70') { $CurlBaseArgs += '--ssl-revoke-best-effort' }
} catch { }

function Test-Url([string]$Url, [switch]$Tls12, [int]$TimeoutSec = 6) {
    $ErrorActionPreference = 'Continue'
    $a = $CurlBaseArgs + @('--connect-timeout', "$TimeoutSec", '--max-time', "$TimeoutSec")
    if ($Tls12) { $a += @('--tls-max', '1.2') }
    & $Curl @a $Url 2>$null | Out-Null
    $LASTEXITCODE -eq 0
}

function Test-Group([string]$Group, [switch]$StopOnFail) {
    $passed = 0; $failed = @()
    foreach ($c in $Checks[$Group]) {
        $ok = Test-Url $c.Url -Tls12:$c.Tls12
        if (-not $ok) { Start-Sleep -Milliseconds 800; $ok = Test-Url $c.Url -Tls12:$c.Tls12 }
        $label = $c.Url + $(if ($c.Tls12) { ' [TLS1.2]' } else { '' })
        if ($ok) { $passed++ } else { $failed += $label; if ($StopOnFail) { break } }
    }
    [pscustomobject]@{ Group = $Group; Passed = $passed; Total = @($Checks[$Group]).Count; Failed = $failed }
}
function Test-AllGroups { foreach ($g in $Checks.Keys) { Test-Group $g } }
function Format-GroupResult($r) {
    '{0} {1}/{2}{3}' -f $r.Group, $r.Passed, $r.Total, $(if ($r.Failed) { " (basarisiz: $($r.Failed -join ', '))" } else { '' })
}

# Sistem DNS'inin discord.com icin verdigi adresleri Cloudflare DoH'un verdikleriyle karsilastirir.
function Test-DnsPoison([string]$Name = 'discord.com') {
    $sys = @(Resolve-DnsName -Name $Name -Type A -DnsOnly -QuickTimeout -ErrorAction SilentlyContinue |
        Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress })
    $doh = @()
    try {
        $ErrorActionPreference = 'Continue'
        $j = (& $Curl -s --max-time 6 -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=$Name&type=A") | ConvertFrom-Json
        $doh = @($j.Answer | Where-Object { $_.type -eq 1 } | ForEach-Object { $_.data })
    } catch { }
    $prefix = { param($ip) ($ip -split '\.')[0..1] -join '.' }
    $dohNets = @($doh | ForEach-Object { & $prefix $_ })
    $poisoned = $null
    if ($sys.Count -and $doh.Count) { $poisoned = -not ($sys | Where-Object { $dohNets -contains (& $prefix $_) }) }
    [pscustomobject]@{ System = $sys; Doh = $doh; Poisoned = $poisoned }
}

# --- winws ----------------------------------------------------------------------
# CIDR -> WinDivert filtresi icin ilk ve son adres.
function Get-CidrRange([string]$Cidr) {
    $ip, $len = $Cidr -split '/'
    $lo = ([Net.IPAddress]::Parse($ip)).GetAddressBytes(); $hi = [byte[]]$lo.Clone()
    for ($i = 0; $i -lt $lo.Length; $i++) {
        $bits = [Math]::Max(0, [Math]::Min(8, [int]$len - 8 * $i))
        $mask = (0xFF -shl (8 - $bits)) -band 0xFF
        $lo[$i] = $lo[$i] -band $mask
        $hi[$i] = $lo[$i] -bor (0xFF -bxor $mask)
    }
    [Net.IPAddress]::new($lo).ToString(), [Net.IPAddress]::new($hi).ToString()
}

# Yalnizca Roblox oyun sunucularina giden UDP paketleri winws'e yonlendirilir (tum yuksek portlari
# yakalamak diger oyunlari ve torrent'i yavaslatir). Kurulum klasorune yazilir; YONETICI gerekir.
function Write-RobloxGameFilter {
    $nets = foreach ($n in $RobloxGameNets) {
        $lo, $hi = Get-CidrRange $n
        $f = if ($n -match ':') { 'ipv6' } else { 'ip' }
        "    $f.DstAddr>=$lo and $f.DstAddr<=$hi"
    }
    @('  outbound and udp.DstPort>=49152 and', '  (', ($nets -join " or`n"), '  )') |
        Set-Content -Path $RobloxGameFilter -Encoding ASCII
}

function Get-WinwsArgString([string[]]$DiscordArgs, [string[]]$RobloxArgs) {
    $bin = Join-Path $InstallDir 'bin'
    $hl  = '"' + (Join-Path $InstallDir $HostLists.Discord) + '"'
    $rhl = '"' + (Join-Path $InstallDir $HostLists.Roblox) + '"'
    $a = @('--wf-tcp=80,443', '--wf-udp=443',
           ('--wf-raw-part=@"' + (Join-Path $bin 'windivert.filter\windivert_part.discord_media.txt') + '"'))
    if ($Cfg.RobloxGameUdp) { $a += '--wf-raw-part=@"' + $RobloxGameFilter + '"' }
    $a += @('--filter-tcp=80,443', "--hostlist=$rhl") + $RobloxArgs +
          @('--new', '--filter-tcp=80,443', "--hostlist=$hl") + $DiscordArgs +
          @('--new', '--filter-udp=443', "--hostlist=$hl", "--hostlist=$rhl", '--dpi-desync=fake', '--dpi-desync-repeats=6',
            ('--dpi-desync-fake-quic="' + (Join-Path $bin 'files\quic_initial_www_google_com.bin') + '"'),
            '--new', '--filter-l7=discord', '--dpi-desync=fake', '--dpi-desync-repeats=6')
    # Roblox oyun trafigi (RakNet, UDP). cutoff: yalnizca baglantinin ilk paketlerinden once sahte paket.
    if ($Cfg.RobloxGameUdp) {
        $a += @('--new', '--filter-udp=49152-65535', "--ipset-ip=$($RobloxGameNets -join ',')", '--dpi-desync=fake',
                '--dpi-desync-any-protocol=1', '--dpi-desync-fake-unknown-udp=0x00', '--dpi-desync-repeats=10', '--dpi-desync-cutoff=n2')
    }
    $a -join ' '
}

# Doner: @{ Discord = <strateji>; Roblox = <strateji> } (bilinmeyenler $null). Eski (tek stratejili) kayitta Name = Discord.
function Get-SavedStrategy {
    $s = [ordered]@{}; foreach ($g in $Checks.Keys) { $s[$g] = $null }
    if (Test-Path $StrategyPath) {
        try {
            $j = Get-Content $StrategyPath -Raw | ConvertFrom-Json
            foreach ($g in $Checks.Keys) { if ($j.$g -and $Strategies.Contains([string]$j.$g)) { $s[$g] = [string]$j.$g } }
            if (-not $s.Discord -and $j.Name -and $Strategies.Contains([string]$j.Name)) { $s.Discord = [string]$j.Name }
        } catch { }
    }
    $s
}
function Format-Strategy($s) { (@($s.Keys) | ForEach-Object { '{0}={1}' -f $_, $(if ($s[$_]) { $s[$_] } else { '-' }) }) -join ' ' }
function Save-Strategy($s) {
    $o = [ordered]@{}; foreach ($g in $Checks.Keys) { $o[$g] = $s[$g] }
    $o.Selected = (Get-Date).ToString('s')
    $o | ConvertTo-Json | Set-Content -Path $StrategyPath -Encoding UTF8
}

function Stop-WinDivertDriver {
    $svc = Get-Service -Name WinDivert -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        & sc.exe stop WinDivert | Out-Null
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 250
            $svc = Get-Service -Name WinDivert -ErrorAction SilentlyContinue
            if (-not $svc -or $svc.Status -eq 'Stopped') { break }
        }
    }
}

function Get-ConflictServices {
    @(Get-CimInstance Win32_Service | Where-Object { $_.Name -ne $Cfg.ServiceName -and $_.PathName -match $ConflictPattern })
}
function Get-ConflictProcesses {
    $ourPid = (Get-CimInstance Win32_Service -Filter "Name='$($Cfg.ServiceName)'" -ErrorAction SilentlyContinue).ProcessId
    @(Get-Process -Name winws, goodbyedpi -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -ne $ourPid -and -not ($_.Path -and $_.Path.StartsWith($InstallDir, [StringComparison]::OrdinalIgnoreCase)) })
}

# Stratejileri winws'i gecici olarak calistirip dener. Kurulu hizmet ve diger DPI araclari DURMUS olmali.
# Her grup (Discord, Roblox) icin ayri secim yapilir; her strateji bir kez calistirilip henuz bulunamayan gruplar test edilir.
# Doner: grup basina tum testleri gecen ilk strateji; yoksa en cok testi gecen; hic yoksa $null.
function Find-Strategy {
    $winws = Join-Path $InstallDir 'bin\winws.exe'
    $saved = Get-SavedStrategy
    $first = @($saved.Values | Where-Object { $_ } | Select-Object -Unique)
    $names = @($first) + @($Strategies.Keys | Where-Object { $first -notcontains $_ })
    $found = [ordered]@{}; $best = @{}
    foreach ($g in $Checks.Keys) { $found[$g] = $null; $best[$g] = @{ Name = $null; Score = 0 } }
    if ($Cfg.RobloxGameUdp) { Write-RobloxGameFilter }
    foreach ($n in $names) {
        $todo = @($Checks.Keys | Where-Object { -not $found[$_] })
        if (-not $todo) { break }
        $out = Join-Path $LogDir "winws-test-$n.log"
        $p = Start-Process -FilePath $winws -ArgumentList (Get-WinwsArgString $Strategies[$n] $Strategies[$n]) -WorkingDirectory (Split-Path $winws) `
            -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError "$out.err"
        Start-Sleep -Seconds 2
        if ($p.HasExited) {
            $err = (Get-Content "$out.err", $out -ErrorAction SilentlyContinue | Select-Object -Last 3) -join ' | '
            Log ("  {0,-28} winws hemen kapandi (kod {1}) {2}" -f $n, $p.ExitCode, $err)
            continue
        }
        $results = foreach ($g in $todo) { Test-Group $g -StopOnFail }
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        [void]$p.WaitForExit(5000)
        Log ("  {0,-28} {1}" -f $n, (@($results | ForEach-Object { Format-GroupResult $_ }) -join '  '))
        foreach ($r in $results) {
            if ($r.Passed -eq $r.Total) { $found[$r.Group] = $n }
            elseif ($r.Passed -gt $best[$r.Group].Score) { $best[$r.Group] = @{ Name = $n; Score = $r.Passed } }
        }
    }
    foreach ($g in $Checks.Keys) {
        if ($found[$g]) { continue }
        $found[$g] = $best[$g].Name
        if ($found[$g]) { Log "UYARI: $g icin hicbir strateji tum testleri gecemedi. En iyi sonuc: $($found[$g]) ($($best[$g].Score)/$(@($Checks[$g]).Count))." }
    }
    $found
}

# Hizmeti verilen stratejilerle (Get-SavedStrategy bicimi) kurar ya da komut satirini gunceller (baslatmaz).
# Bilinmeyen grup icin ilk strateji kullanilir.
function Set-WinwsService($Strategy) {
    $default = @($Strategies.Keys)[0]
    $d = if ($Strategy.Discord) { $Strategy.Discord } else { $default }
    $r = if ($Strategy.Roblox) { $Strategy.Roblox } else { $default }
    if ($Cfg.RobloxGameUdp) { Write-RobloxGameFilter }
    $image = '"' + (Join-Path $InstallDir 'bin\winws.exe') + '" ' + (Get-WinwsArgString $Strategies[$d] $Strategies[$r])
    $name = $Cfg.ServiceName
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.Status -ne 'Stopped') { Stop-Service -Name $name -Force }
        Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$name" -Name ImagePath -Value $image
    } else {
        New-Service -Name $name -BinaryPathName $image -DisplayName 'DPI Bypass (zapret winws)' `
            -Description "Discord ve Roblox icin DPI bypass. Kaldirmak icin: $InstallDir\uninstall.cmd" -StartupType Automatic | Out-Null
        & sc.exe failure $name reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null
        & sc.exe failureflag $name 1 | Out-Null
    }
    Log "Hizmet komutu: $image"
}

function Start-WinwsService {
    Start-Service -Name $Cfg.ServiceName
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 500
        if ((Get-Service -Name $Cfg.ServiceName).Status -eq 'Running' -and (Get-Process -Name winws -ErrorAction SilentlyContinue)) { return $true }
    }
    $false
}

# --- DNS ------------------------------------------------------------------------
function Get-PhysicalAdapters { @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue) }

function Test-AdapterDns($Adapter) {
    $v4 = @((Get-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
    ($v4 -join ',') -eq (@($Cfg.DnsV4) -join ',')
}

function Set-AdapterDns($Adapter) {
    $inDnsClient = [bool](Get-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ErrorAction SilentlyContinue)
    if ($inDnsClient) {
        try { Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses $DnsServers; return 'v4+v6' }
        catch { Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses @($Cfg.DnsV4); return 'v4 (IPv6 kapali)' }
    }
    # Bagli olmayan adaptor: ayar kayit defterine yazilir, baglaninca gecerli olur.
    $guid = $Adapter.InterfaceGuid
    $k4 = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$guid"
    $k6 = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces\$guid"
    $done = @()
    if (Test-Path $k4) { Set-ItemProperty $k4 -Name NameServer -Value (@($Cfg.DnsV4) -join ','); $done += 'v4' }
    if (Test-Path $k6) { Set-ItemProperty $k6 -Name NameServer -Value (@($Cfg.DnsV6) -join ','); $done += 'v6' }
    if ($done) { 'kayit defteri ' + ($done -join '+') } else { 'atlandi' }
}

function Set-Doh {
    if (-not (Get-Command Add-DnsClientDohServerAddress -ErrorAction SilentlyContinue)) { return $false }
    foreach ($s in $DnsServers) {
        if (Get-DnsClientDohServerAddress -ServerAddress $s -ErrorAction SilentlyContinue) {
            Set-DnsClientDohServerAddress -ServerAddress $s -DohTemplate $Cfg.DohTemplate -AutoUpgrade $true -AllowFallbackToUdp $false | Out-Null
        } else {
            Add-DnsClientDohServerAddress -ServerAddress $s -DohTemplate $Cfg.DohTemplate -AutoUpgrade $true -AllowFallbackToUdp $false | Out-Null
        }
    }
    $true
}

# --- Defender ---------------------------------------------------------------------
function Test-DefenderActive {
    try { [bool](Get-MpComputerStatus -ErrorAction Stop).RealTimeProtectionEnabled } catch { $false }
}
