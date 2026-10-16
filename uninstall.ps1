<#
  uninstall.ps1 - install.ps1'in yaptigi her seyi geri alir (YONETICI gerekir).
  En kolay yol: uninstall.cmd'ye cift tiklayin.

    1. Zamanlanmis gorevleri ve winws hizmetini siler, WinDivert surucusunu durdurur.
    2. Adaptor DNS ayarlarini ve DoH listesini yedekten geri yukler.
       Kurulumdan sonra eklenen adaptorler otomatik DNS'e dondurulur.
    3. Kurulumun devre disi biraktigi DPI araclarini (GoodbyeDPI vb.) eski hallerine dondurur.
    4. Defender istisnasini kaldirir ve C:\Program Files\dpi-bypass klasorunu siler.
  Loglar C:\ProgramData\dpi-bypass\logs altinda kalir.

  Kullanim (yonetici PowerShell):  powershell -ExecutionPolicy Bypass -File uninstall.ps1 [-Yes]
#>
param([switch]$Yes)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
Assert-Admin
Start-Log 'uninstall'

$backup = $null
if (Test-Path $BackupPath) { $backup = Get-Content $BackupPath -Raw | ConvertFrom-Json }
# Eski surum yedeginde DPI araci olarak yalnizca GoodbyeDPI tutuluyordu.
$restoreSvcs = @()
if ($backup) {
    if ($backup.ConflictServices) { $restoreSvcs = @($backup.ConflictServices) }
    elseif ($backup.GoodbyeDPI.Exists) {
        $restoreSvcs = @([pscustomobject]@{ Name = 'GoodbyeDPI'; Start = $backup.GoodbyeDPI.Start; DelayedAutostart = $backup.GoodbyeDPI.DelayedAutostart; State = $backup.GoodbyeDPI.Status })
    }
}

# --- Hedefleri goster ---------------------------------------------------------
$tasks = @($Cfg.TaskName, $Cfg.ReselectTaskName) | Where-Object { Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue }
$svc = Get-Service -Name $Cfg.ServiceName -ErrorAction SilentlyContinue
Write-Host ''
Write-Host 'Kaldirilacak / geri alinacaklar:'
Write-Host ("  Gorevler          : {0}" -f $(if ($tasks) { $tasks -join ', ' } else { '(yok)' }))
Write-Host ("  Hizmet            : {0}" -f $(if ($svc) { "$($Cfg.ServiceName) ($($svc.Status))" } else { '(yok)' }))
Write-Host ("  Klasor (silinecek): {0}" -f $(if (Test-Path $InstallDir) { $InstallDir } else { '(yok)' }))
if ($backup) {
    foreach ($a in $backup.Adapters) { Write-Host ("  DNS geri yukleme  : {0} -> v4='{1}' v6='{2}' (bos = otomatik)" -f $a.Name, $a.V4NameServer, $a.V6NameServer) }
    foreach ($s in $restoreSvcs) { Write-Host ("  Hizmet geri yukle : {0} (Start={1}, onceki durum {2})" -f $s.Name, $s.Start, $s.State) }
} else {
    Write-Host '  Yedek             : yok. Cloudflare DNS ayarli adaptorler otomatik DNS''e dondurulecek.'
}
Write-Host ''
if (-not $Yes) {
    $ans = Read-Host 'Devam edilsin mi? (E/H)'
    if ($ans -notmatch '^[EeYy]') { Write-Host 'Iptal edildi.'; return }
}
Log '=== Kaldirma basladi'

# --- 1. Gorevler, hizmet, surucu -------------------------------------------------
foreach ($t in $tasks) { Unregister-ScheduledTask -TaskName $t -Confirm:$false; Log "Gorev silindi: $t" }
if ($svc) {
    if ($svc.Status -ne 'Stopped') { Stop-Service -Name $Cfg.ServiceName -Force -ErrorAction SilentlyContinue }
    & sc.exe delete $Cfg.ServiceName | Out-Null
    Log "Hizmet silindi: $($Cfg.ServiceName)"
}
Get-Process -Name winws -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$InstallDir*" } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
Stop-WinDivertDriver

# --- 2. DNS / DoH -------------------------------------------------------------
$known = @()
if ($backup) { $known = @($backup.Adapters | ForEach-Object { $_.Guid }) }
foreach ($cur in Get-PhysicalAdapters) {
    $a = $null
    if ($backup) { $a = $backup.Adapters | Where-Object { $_.Guid -eq $cur.InterfaceGuid } | Select-Object -First 1 }
    $inDnsClient = [bool](Get-DnsClientServerAddress -InterfaceIndex $cur.ifIndex -ErrorAction SilentlyContinue)
    try {
        if ($a) {
            $servers = @(([string]$a.V4NameServer) -split '[ ,]' | Where-Object { $_ }) + @(([string]$a.V6NameServer) -split '[ ,]' | Where-Object { $_ })
            if ($inDnsClient) {
                Set-DnsClientServerAddress -InterfaceIndex $cur.ifIndex -ResetServerAddresses
                if ($servers.Count) { Set-DnsClientServerAddress -InterfaceIndex $cur.ifIndex -ServerAddresses $servers }
            } else {
                Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($a.Guid)" -Name NameServer -Value ([string]$a.V4NameServer) -ErrorAction SilentlyContinue
                Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces\$($a.Guid)" -Name NameServer -Value ([string]$a.V6NameServer) -ErrorAction SilentlyContinue
            }
            Log ("DNS geri yuklendi: {0} -> v4='{1}' v6='{2}'" -f $cur.Name, $a.V4NameServer, $a.V6NameServer)
        } elseif ($known -notcontains $cur.InterfaceGuid -and (Test-AdapterDns $cur)) {
            Set-DnsClientServerAddress -InterfaceIndex $cur.ifIndex -ResetServerAddresses
            Log "DNS otomatige donduruldu (yedekte olmayan adaptor): $($cur.Name)"
        }
    } catch { Log "!! DNS geri yuklenemedi ($($cur.Name)): $($_.Exception.Message)" }
}

if (Get-Command Get-DnsClientDohServerAddress -ErrorAction SilentlyContinue) {
    foreach ($s in $DnsServers) {
        $old = $null
        if ($backup) { $old = $backup.Doh | Where-Object { $_.ServerAddress -eq $s } | Select-Object -First 1 }
        try {
            if ($old) {
                Set-DnsClientDohServerAddress -ServerAddress $s -DohTemplate $old.DohTemplate -AutoUpgrade ([bool]$old.AutoUpgrade) -AllowFallbackToUdp ([bool]$old.AllowFallbackToUdp) | Out-Null
                Log "DoH geri yuklendi: $s"
            } elseif (Get-DnsClientDohServerAddress -ServerAddress $s -ErrorAction SilentlyContinue) {
                # Yedek yoksa Windows varsayilanina (otomatik yukseltme kapali) don.
                Set-DnsClientDohServerAddress -ServerAddress $s -AutoUpgrade $false -AllowFallbackToUdp $true | Out-Null
                Log "DoH otomatik yukseltme kapatildi: $s"
            }
        } catch { Log "!! DoH geri yuklenemedi ($s): $($_.Exception.Message)" }
    }
}
Clear-DnsClientCache

# --- 3. Diger DPI araclari ------------------------------------------------------
foreach ($s in $restoreSvcs) {
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.Name)"
    if (-not (Test-Path $key)) { continue }
    try {
        Set-ItemProperty $key -Name Start -Value ([int]$s.Start)
        if ($null -ne $s.DelayedAutostart) { Set-ItemProperty $key -Name DelayedAutostart -Value ([int]$s.DelayedAutostart) }
        Log "Hizmet baslangic turu geri yuklendi: $($s.Name) Start=$($s.Start)"
        if ($s.State -eq 'Running') { Start-Service -Name $s.Name; Log "Hizmet baslatildi: $($s.Name)" }
    } catch { Log "!! $($s.Name) geri yuklenemedi: $($_.Exception.Message)" }
}
if ($backup) {
    $done = Join-Path $StateDir ('backup-restored-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Move-Item $BackupPath $done
    Log "Yedek arsivlendi: $done"
}
Remove-Item $StrategyPath -ErrorAction SilentlyContinue

# --- 4. Defender ve dosyalar -------------------------------------------------------
if (Test-Path $ExclusionMark) {
    try { Remove-MpPreference -ExclusionPath $InstallDir; Log "Defender istisnasi kaldirildi: $InstallDir" }
    catch { Log "!! Defender istisnasi kaldirilamadi: $($_.Exception.Message)" }
    Remove-Item $ExclusionMark -ErrorAction SilentlyContinue
}
if (Test-Path $InstallDir) {
    Log "Siliniyor: $InstallDir"
    Remove-Item -Recurse -Force $InstallDir
}
Log "=== Kaldirma tamamlandi. Loglar: $LogDir"
