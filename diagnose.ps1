<#
  diagnose.ps1 - Discord / Roblox neden acilmiyor? Durumu kontrol edip bir rapor yazar (YONETICI gerekir).
  En kolay yol: diagnose.cmd'ye cift tiklayin. Hicbir ayari degistirmez.
  Rapor: C:\ProgramData\dpi-bypass\logs\diagnose-*.txt
#>
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib.ps1')
Assert-Admin
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$report = Join-Path $LogDir ('diagnose-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$out = New-Object System.Collections.ArrayList
function W([string]$s = '') { [void]$out.Add($s); Write-Host $s }
function Section([string]$t) { W ''; W "=== $t" }
$problems = New-Object System.Collections.ArrayList
function Problem([string]$s) { [void]$problems.Add($s) }

$os = Get-CimInstance Win32_OperatingSystem
W "dpi-bypass teshis raporu  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
W "$($os.Caption) build $($os.BuildNumber), 64 bit: $([Environment]::Is64BitOperatingSystem)"

Section 'Kurulum'
$svc = Get-Service -Name $Cfg.ServiceName -ErrorAction SilentlyContinue
W "Klasor       : $(if (Test-Path $InstallDir) { $InstallDir } else { 'YOK' })"
W "Hizmet       : $(if ($svc) { "$($svc.Status) / $($svc.StartType)" } else { 'YOK' })"
W "winws        : $(@(Get-Process -Name winws -ErrorAction SilentlyContinue | ForEach-Object { "PID $($_.Id) $($_.Path)" }) -join '; ')"
W "WinDivert    : $(Get-Service -Name WinDivert -ErrorAction SilentlyContinue | ForEach-Object { $_.Status })"
W "Strateji     : $(Format-Strategy (Get-SavedStrategy))"
W "Roblox oyun  : $(if ($Cfg.RobloxGameUdp) { 'UDP acik' } else { 'UDP kapali (config.json: RobloxGameUdp)' })"
foreach ($t in $Cfg.TaskName, $Cfg.ReselectTaskName) {
    $task = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
    W ("Gorev        : {0} {1}" -f $t, $(if ($task) { $task.State } else { 'YOK' }))
}
if (-not $svc) { Problem 'Kurulu degil ya da kurulum hata verip geri alinmis. install.cmd calistirip ekrandaki hatayi okuyun.' }
elseif ($svc.Status -ne 'Running') { Problem 'winws hizmeti calismiyor. Asagidaki surucu / antivirus bolumlerine bakin.' }
if (Test-Path $InstallDir) {
    $bad = Test-BinFiles $InstallDir
    W "Dosyalar     : $(if ($bad) { 'SORUNLU: ' + ($bad -join ', ') } else { 'tam' })"
    if ($bad) { Problem "Program dosyalari eksik/bozuk ($($bad -join ', ')). Antivirus silmis olabilir; istisna ekleyip yeniden kurun." }
    $missing = @($HostLists.Values | Where-Object { -not (Test-Path (Join-Path $InstallDir $_)) })
    if ($Cfg.RobloxGameUdp -and -not (Test-Path $RobloxGameFilter)) { $missing += Split-Path $RobloxGameFilter -Leaf }
    W "Listeler     : $(if ($missing) { 'EKSIK: ' + ($missing -join ', ') } else { 'tam' })"
    if ($missing) { Problem "Kurulum eksik ($($missing -join ', ')); eski surumden kalmis olabilir. install.cmd'yi yeniden calistirin." }
}

Section 'Catisan DPI araclari'
$cs = Get-ConflictServices; $cp = Get-ConflictProcesses
foreach ($s in $cs) { W "Hizmet: $($s.Name) $($s.State) $($s.StartMode)  $($s.PathName)" }
foreach ($p in $cp) { W "Islem : $($p.Name) PID $($p.Id) $($p.Path)" }
if (-not ($cs -or $cp)) { W '(yok)' }
if (@($cs | Where-Object { $_.State -eq 'Running' }).Count -or $cp) { Problem 'Baska bir DPI araci (GoodbyeDPI / baska winws) calisiyor; ikisi birlikte calismaz. install.cmd''yi yeniden calistirin.' }

Section 'Antivirus ve surucu'
W "Defender gercek zamanli koruma: $(Test-DefenderActive)"
W "Defender istisnasi (bu kurulum): $(Test-Path $ExclusionMark)"
try {
    $det = @(Get-MpThreatDetection -ErrorAction Stop | Where-Object { ($_.Resources -join ' ') -match '(?i)winws|windivert|cygwin1|dpi-bypass' })
    foreach ($d in $det) { W "Defender tespiti: $($d.InitialDetectionTime)  $($d.Resources -join ', ')" }
    if ($det) { Problem 'Windows Defender program dosyalarini tehdit olarak isaretlemis. Koruma gecmisinden izin verip istisnaya izin vererek yeniden kurun.' }
} catch { W "Defender tespitleri okunamadi: $($_.Exception.Message)" }
$av = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue | ForEach-Object { $_.displayName })
W "Yuklu antivirusler: $($av -join ', ')"
if (@($av | Where-Object { $_ -notmatch 'Defender' }).Count) { Problem "Defender disinda antivirus var ($($av -join ', ')). WinDivert/winws'i engelliyorsa '$InstallDir' klasorunu o programda istisnaya ekleyin." }
$hvci = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -ErrorAction SilentlyContinue).Enabled
W "Bellek butunlugu (HVCI): $(if ($hvci -eq 1) { 'acik' } else { 'kapali' })"
$ci = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-CodeIntegrity/Operational'; StartTime = (Get-Date).AddDays(-7) } -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match '(?i)windivert' } | Select-Object -First 3)
foreach ($e in $ci) { W "CodeIntegrity $($e.Id): $(($e.Message -split "`n")[0])" }
if ($ci) { Problem 'Windows, WinDivert surucusunu yuklemeyi engellemis (CodeIntegrity). Bellek butunlugu aciksa kapatmayi deneyin.' }

Section 'DNS'
foreach ($a in Get-PhysicalAdapters) {
    $v4 = @((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses) -join ','
    $v6 = @((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue).ServerAddresses) -join ','
    $ip6 = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue | Where-Object { $_.PrefixOrigin -ne 'WellKnown' -and $_.IPAddress -notlike 'fe80*' }).Count -gt 0
    W ("{0,-22} {1,-12} v4=[{2}] v6=[{3}] IPv6 adres: {4}" -f $a.Name, $a.Status, $v4, $v6, $ip6)
    if ($a.Status -eq 'Up' -and -not (Test-AdapterDns $a)) { Problem "$($a.Name) adaptorunun DNS'i Cloudflare degil. Saglik kontrolu bir dakika icinde duzeltmeli; duzelmiyorsa yeniden kurun." }
}
if (Get-Command Get-DnsClientDohServerAddress -ErrorAction SilentlyContinue) {
    foreach ($s in $DnsServers) {
        $d = Get-DnsClientDohServerAddress -ServerAddress $s -ErrorAction SilentlyContinue
        W ("DoH {0,-24} {1}" -f $s, $(if ($d) { "AutoUpgrade=$($d.AutoUpgrade) Fallback=$($d.AllowFallbackToUdp)" } else { 'tanimli degil' }))
    }
} else { W 'DoH: bu Windows surumunde yok (DNS sifrelenmiyor).' }
foreach ($n in 'discord.com', 'roblox.com') {
    $dns = Test-DnsPoison $n
    W ("{0,-12} sistem DNS : {1}" -f $n, ($dns.System -join ', '))
    W ("{0,-12} Cloudflare : {1}" -f $n, ($dns.Doh -join ', '))
    if ($dns.Poisoned) { Problem "$n icin DNS yanlis adres donduruyor (engelli DNS). Tarayicida ya da VPN/proxy programlarinda ayri DNS ayari olabilir; DNS bolumune bakin." }
    if (-not $dns.System) { Problem "$n DNS ile cozulemiyor. DoH sunucusuna ulasilamiyor olabilir (otel/okul agi, captive portal)." }
}

Section 'Baglanti testleri (winws acik haliyle)'
W "Kontrol ($($Cfg.ControlTarget)): $(if (Test-Url $Cfg.ControlTarget) { 'OK' } else { 'HATA' })"
foreach ($g in $Checks.Keys) {
    $fails = 0
    foreach ($c in $Checks[$g]) {
        $ok = Test-Url $c.Url -Tls12:$c.Tls12
        if (-not $ok) { $fails++ }
        W ("{0,-8} {1,-32} {2,-10} {3}" -f $g, $c.Url, $(if ($c.Tls12) { 'TLS1.2' } else { 'varsayilan' }), $(if ($ok) { 'OK' } else { 'HATA' }))
    }
    if ($fails -and $svc -and $svc.Status -eq 'Running') { Problem "winws calisiyor ama $g testleri basarisiz. select-strategy.cmd ile bu ag icin strateji yeniden secilebilir." }
}

Section 'Proxy / VPN'
$proxy = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
W "Sistem proxy: $(if ($proxy.ProxyEnable -eq 1) { $proxy.ProxyServer } else { 'kapali' })"
W "VPN/sanal adaptorler: $(@(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { -not $_.HardwareInterface -and $_.Status -eq 'Up' } | ForEach-Object { $_.Name }) -join ', ')"

Section 'Son saglik kontrolu kayitlari'
$hl = Get-ChildItem $LogDir -Filter 'health-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
if ($hl) { Get-Content $hl.FullName -Tail 10 | ForEach-Object { W $_ } } else { W '(yok)' }
Section 'Son kurulum logu'
$il = Get-ChildItem $LogDir -Filter 'install-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
if ($il) { Get-Content $il.FullName -Tail 25 | ForEach-Object { W $_ } } else { W '(yok)' }

Section 'SONUC'
if ($problems.Count) { foreach ($p in $problems) { W "- $p" } } else { W 'Belirgin bir sorun bulunamadi. Discord''u sistem tepsisinden, Roblox''u da tamamen kapatip yeniden acin. Tarayicida "Guvenli DNS" ayari varsa kapatin ya da Cloudflare yapin.' }
$out | Set-Content -Path $report -Encoding UTF8
Write-Host ''
Write-Host "Rapor: $report"
