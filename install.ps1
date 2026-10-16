<#
  install.ps1 - Discord ve Roblox icin zapret/winws tabanli DPI bypass kurulumu (YONETICI gerekir).
  En kolay yol: install.cmd'ye cift tiklayin.

  Yaptiklari (log: C:\ProgramData\dpi-bypass\logs\install-*.log):
    1. Dosyalarin eksiksiz oldugunu dogrular (antivirus silmis olabilir).
    2. Mevcut DNS / DoH ayarlarini ve diger DPI araclarinin (GoodbyeDPI, baska winws) durumunu yedekler.
    3. Diger DPI araclarini durdurup devre disi birakir (ayni anda calisirlarsa birbirini bozar).
    4. Istenirse kurulum klasorunu Windows Defender taramasindan haric tutar.
    5. Dosyalari C:\Program Files\dpi-bypass altina kopyalar.
    6. Tum fiziksel adaptorlerde DNS'i Cloudflare yapar (IPv4 + IPv6), Windows 11'de DoH'u zorunlu kilar.
    7. Bu agda Discord'u ve Roblox'u acan stratejileri (her biri icin ayri) deneyerek bulur.
    8. winws'i Windows hizmeti, saglik kontrolunu dakikalik gorev olarak kurar.
  Bir adim hata verirse uninstall.ps1 ile her sey geri alinir. Tekrar calistirmak guncelleme yapar.

  Kullanim (yonetici PowerShell):  powershell -ExecutionPolicy Bypass -File install.ps1 [-Yes]
#>
param([switch]$Yes)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
Assert-Admin
Start-Log 'install'
$src = $PSScriptRoot

$os = Get-CimInstance Win32_OperatingSystem
Log "=== Kurulum basladi. $($os.Caption) (build $($os.BuildNumber))"
if (-not [Environment]::Is64BitOperatingSystem) { throw '64 bit Windows gerekir.' }
if (-not (Test-Path $Curl)) { throw 'curl.exe bulunamadi. Windows 10 1803 veya daha yenisi gerekir.' }

# Internetten indirilen zip'in dosyalari "engelli" isaretlenir; kaldir.
Get-ChildItem $src -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

$bad = Test-BinFiles $src
if ($bad) {
    throw ("Eksik veya bozuk dosya: {0}. Antivirus (Windows Defender) bunlari silmis olabilir. " +
        "Windows Guvenligi > Virus ve tehdit korumasi > Koruma gecmisi'nden geri yukleyin ya da zip'i yeniden indirip acin.") -f ($bad -join ', ')
}

$addExclusion = $false
if (Test-DefenderActive) {
    if ($Yes) { $addExclusion = $true }
    else {
        Write-Host ''
        Write-Host 'Windows Defender, WinDivert ve winws dosyalarini "HackTool" diye silebilir; bu durumda program calismaz.'
        $ans = Read-Host "Kurulum klasoru ($InstallDir) Defender taramasindan haric tutulsun mu? (E/h)"
        $addExclusion = ($ans -notmatch '^[HhNn]')
    }
}

try {
    # --- 1. Yedek ---------------------------------------------------------------
    $conflicts = Get-ConflictServices
    if (Test-Path $BackupPath) {
        Log "Onceki kurulumun yedegi korunuyor: $BackupPath"
    } else {
        $adapters = foreach ($a in Get-PhysicalAdapters) {
            [ordered]@{
                Name         = $a.Name
                Guid         = $a.InterfaceGuid
                V4NameServer = [string](Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($a.InterfaceGuid)" -ErrorAction SilentlyContinue).NameServer
                V6NameServer = [string](Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces\$($a.InterfaceGuid)" -ErrorAction SilentlyContinue).NameServer
            }
        }
        $doh = @()
        if (Get-Command Get-DnsClientDohServerAddress -ErrorAction SilentlyContinue) {
            $doh = Get-DnsClientDohServerAddress | ForEach-Object {
                [ordered]@{ ServerAddress = $_.ServerAddress; DohTemplate = $_.DohTemplate; AutoUpgrade = $_.AutoUpgrade; AllowFallbackToUdp = $_.AllowFallbackToUdp }
            }
        }
        $svcBackup = foreach ($s in $conflicts) {
            $k = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.Name)"
            [ordered]@{ Name = $s.Name; Start = $k.Start; DelayedAutostart = $k.DelayedAutostart; State = [string]$s.State }
        }
        [ordered]@{
            Created          = (Get-Date).ToString('s')
            Adapters         = @($adapters)
            Doh              = @($doh)
            ConflictServices = @($svcBackup)
        } | ConvertTo-Json -Depth 6 | Set-Content -Path $BackupPath -Encoding UTF8
        Log "Yedek alindi: $BackupPath"
        foreach ($a in $adapters) { Log ("  {0}: v4='{1}' v6='{2}' (bos = otomatik)" -f $a.Name, $a.V4NameServer, $a.V6NameServer) }
    }

    # --- 2. Calisan DPI araclarini durdur ------------------------------------------
    # Guncellemede saglik kontrolu, strateji denenirken durdurulan hizmeti yeniden baslatip testleri bozmasin.
    # Gorev 7. adimda yeniden kaydedilince tekrar etkin olur.
    foreach ($t in $Cfg.TaskName, $Cfg.ReselectTaskName) {
        $task = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
        if ($task) {
            if ($task.State -eq 'Running') { Stop-ScheduledTask -TaskName $t }
            Disable-ScheduledTask -TaskName $t | Out-Null
        }
    }
    $ours = Get-Service -Name $Cfg.ServiceName -ErrorAction SilentlyContinue
    if ($ours -and $ours.Status -ne 'Stopped') { Stop-Service -Name $Cfg.ServiceName -Force; Log 'Eski dpi-bypass hizmeti durduruldu (guncelleme).' }
    foreach ($s in $conflicts) {
        Log "Catisan hizmet devre disi birakiliyor: $($s.Name) ($($s.PathName))"
        if ($s.State -ne 'Stopped') { Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue }
        Set-Service -Name $s.Name -StartupType Disabled
    }
    foreach ($p in Get-ConflictProcesses) {
        Log "Calisan DPI araci kapatiliyor: $($p.Name) (PID $($p.Id)) $($p.Path)"
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
    Get-Process -Name winws -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Stop-WinDivertDriver

    # --- 3. Defender istisnasi ----------------------------------------------------
    if ($addExclusion) {
        Add-MpPreference -ExclusionPath $InstallDir
        New-Item -ItemType File -Force -Path $ExclusionMark | Out-Null
        Log "Defender istisnasi eklendi: $InstallDir"
    }

    # --- 4. Dosyalar ------------------------------------------------------------
    New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'bin') | Out-Null
    Copy-Item -Recurse -Force (Join-Path $src 'bin\*') (Join-Path $InstallDir 'bin')
    foreach ($f in 'lib.ps1', 'config.json', 'health-check.ps1', 'select-strategy.ps1', 'uninstall.ps1', 'diagnose.ps1',
                   'uninstall.cmd', 'diagnose.cmd', 'select-strategy.cmd', 'README.md', 'THIRD-PARTY.md', 'LICENSE') {
        Copy-Item -Force (Join-Path $src $f) $InstallDir
    }
    # hostlist'ler: kullanicinin ekledigi alan adlari korunur, yeni varsayilanlar eklenir.
    foreach ($hl in $HostLists.Values) {
        $hlDst = Join-Path $InstallDir $hl
        $lines = @(Get-Content (Join-Path $src $hl))
        if (Test-Path $hlDst) { $lines = @(Get-Content $hlDst) + $lines }
        $lines | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique | Set-Content -Path $hlDst -Encoding ASCII
    }
    Start-Sleep -Seconds 2
    $bad = Test-BinFiles $InstallDir
    if ($bad) { throw "Kopyalanan dosyalar silindi/bozuldu: $($bad -join ', '). Antivirus engelliyor olabilir; Defender istisnasina izin vererek tekrar kurun." }
    Log "Dosyalar kopyalandi: $InstallDir"

    # --- 5. DNS / DoH -------------------------------------------------------------
    foreach ($a in Get-PhysicalAdapters) { Log ("DNS: {0} -> {1}" -f $a.Name, (Set-AdapterDns $a)) }
    if (Set-Doh) { Log "DoH: $($DnsServers -join ', ') -> $($Cfg.DohTemplate) (yalnizca sifreli)" }
    else { Log 'UYARI: Bu Windows surumunde DoH yok (Windows 10). DNS sifrelenmeden Cloudflare''e gider.' }
    Clear-DnsClientCache

    # --- 6. Strateji ------------------------------------------------------------
    if (-not (Test-Url $Cfg.ControlTarget)) {
        Start-Sleep -Seconds 3
        if (-not (Test-Url $Cfg.ControlTarget)) { throw "Internet baglantisi yok ($($Cfg.ControlTarget) acilmiyor). Baglantiyi kontrol edip tekrar deneyin." }
    }
    $dns = Test-DnsPoison
    if ($dns.Poisoned) { Log "UYARI: discord.com DNS cevabi hatali gorunuyor ($($dns.System -join ',')); DoH sonrasi beklenen: $($dns.Doh -join ',')" }
    foreach ($r in Test-AllGroups) { Log "DPI araci olmadan: $(Format-GroupResult $r)" }
    Log 'Stratejiler deneniyor (1-4 dakika surebilir)...'
    $strategy = Find-Strategy
    foreach ($g in @($strategy.Keys)) {
        if (-not $strategy[$g]) { $strategy[$g] = @($Strategies.Keys)[0]; Log "UYARI: $g icin hicbir strateji ise yaramadi; varsayilan kuruluyor: $($strategy[$g]). Saglik kontrolu daha sonra yeniden deneyecek." }
    }
    Save-Strategy $strategy
    Log "Secilen strateji: $(Format-Strategy $strategy)"

    # --- 7. Hizmet ve gorevler ------------------------------------------------------
    Set-WinwsService $strategy
    if (-not (Start-WinwsService)) {
        throw 'winws hizmeti baslamadi. WinDivert surucusu engelleniyor olabilir (antivirus veya Bellek butunlugu). diagnose.cmd ile ayrintiya bakin.'
    }
    Log 'winws hizmeti calisiyor.'

    $ps = 'powershell.exe'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $hcAction = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$InstallDir\health-check.ps1`""
    $hcTriggers = @((New-ScheduledTaskTrigger -AtStartup),
                    (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)))
    $hcSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
    Register-ScheduledTask -TaskName $Cfg.TaskName -Action $hcAction -Trigger $hcTriggers -Principal $principal -Settings $hcSettings -Force | Out-Null
    $rsAction = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$InstallDir\select-strategy.ps1`""
    $rsSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
    Register-ScheduledTask -TaskName $Cfg.ReselectTaskName -Action $rsAction -Principal $principal -Settings $rsSettings -Force | Out-Null
    Log "Gorevler kuruldu: $($Cfg.TaskName) (dakikada bir), $($Cfg.ReselectTaskName) (gerektiginde)"

    # --- 8. Dogrulama -----------------------------------------------------------
    Start-Sleep -Seconds 2
    $final = @(Test-AllGroups)
    foreach ($r in $final) { Log "Son kontrol: $(Format-GroupResult $r)" }
    Log '=== Kurulum tamamlandi.'
    Write-Host ''
    foreach ($r in $final) {
        if ($r.Passed -eq $r.Total) {
            Write-Host "$($r.Group) erisilebilir durumda." -ForegroundColor Green
        } else {
            Write-Host "$($r.Group) testleri tam gecmedi ($($r.Passed)/$($r.Total)). diagnose.cmd calistirip cikan raporu inceleyin." -ForegroundColor Yellow
        }
    }
    Write-Host 'Discord veya Roblox aciksa tamamen kapatip yeniden acin (Discord: sistem tepsisinden cikis). Tarayicida Roblox sekmesini yenileyin.'
    Write-Host "Log: $script:LogFile"
} catch {
    Log "!! KURULUM HATASI: $($_.Exception.Message)"
    Log '!! Geri alma baslatiliyor'
    Get-Process -Name winws -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    & (Join-Path $src 'uninstall.ps1') -Yes
    throw
}
