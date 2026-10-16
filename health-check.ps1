<#
  health-check.ps1 - Dakikada bir SYSTEM olarak calisir (zamanlanmis gorev: dpi-bypass-health).

  Her calismada:
    - winws hizmeti calismiyorsa baslatir.
    - Bagli fiziksel adaptorlerde DNS Cloudflare degilse ayarlar (yeni Wi-Fi karti, USB modem vb.).
    - DNS, kontrol sitesi (hostlist DISI) ve Discord test edilir.
  Kademeli onarim:
    - Genel sorun (DNS veya kontrol sitesi calismiyor): 1. dakika DNS onbellegi temizlenir,
      2. dakika DNS adaptorlere yeniden uygulanir.
    - Yalnizca Discord acilmiyor: WinwsRestartAfterMinutes dakika sonra winws yeniden baslatilir.
      Bu ReselectAfterRestarts kez ise yaramazsa strateji yeniden secilir (ag degismis olabilir).
  Log: C:\ProgramData\dpi-bypass\logs\health-YYYYMMDD.log (her calisma bir satir)
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
New-Item -ItemType Directory -Force -Path $LogDir, $StateDir | Out-Null
$logFile   = Join-Path $LogDir ('health-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
$statePath = Join-Path $StateDir 'health.json'

$st = [ordered]@{ GeneralFails = 0; HostFails = 0; FailedRestarts = 0; LastWinwsRestart = $null; LastReselect = $null }
if (Test-Path $statePath) {
    try {
        $j = Get-Content $statePath -Raw | ConvertFrom-Json
        foreach ($k in @($st.Keys)) { if ($null -ne $j.$k) { $st[$k] = $j.$k } }
    } catch { }
}
$actions = New-Object System.Collections.ArrayList
function Since([object]$ts) { if (-not $ts) { return [double]::MaxValue }; ((Get-Date) - [datetime]$ts).TotalMinutes }
function Restart-Winws {
    try {
        Restart-Service -Name $Cfg.ServiceName -Force
        [void]$actions.Add('winws-restart')
        $st.LastWinwsRestart = (Get-Date).ToString('s')
        Start-Sleep -Seconds 2
    } catch { [void]$actions.Add("winws-restart-HATA:$($_.Exception.Message)") }
}

# Yeniden secim gorevi calisiyorsa (hizmeti kendisi durdurup baslatir) karisma.
$reselect = Get-ScheduledTask -TaskName $Cfg.ReselectTaskName -ErrorAction SilentlyContinue
if ($reselect -and $reselect.State -eq 'Running') {
    Add-Content -Path $logFile -Value ('{0} strateji yeniden seciliyor, atlandi' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding UTF8
    return
}

# --- Hizmet -------------------------------------------------------------------
$svcState = 'yok'
$svc = Get-Service -Name $Cfg.ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    $svcState = [string]$svc.Status
    if ($svc.Status -ne 'Running' -or -not (Get-Process -Name winws -ErrorAction SilentlyContinue)) {
        try {
            if ($svc.Status -eq 'Running') { Restart-Service -Name $Cfg.ServiceName -Force } else { Start-Service -Name $Cfg.ServiceName }
            [void]$actions.Add('winws-start')
            $st.LastWinwsRestart = (Get-Date).ToString('s')
            Start-Sleep -Seconds 2
        } catch { [void]$actions.Add("winws-start-HATA:$($_.Exception.Message)") }
    }
}

# --- Adaptor DNS ----------------------------------------------------------------
foreach ($a in Get-PhysicalAdapters | Where-Object { $_.Status -eq 'Up' }) {
    if (-not (Test-AdapterDns $a)) {
        try { [void]$actions.Add("dns-set($($a.Name):$(Set-AdapterDns $a))"); Clear-DnsClientCache }
        catch { [void]$actions.Add("dns-set-HATA($($a.Name)):$($_.Exception.Message)") }
    }
}

# --- Testler ------------------------------------------------------------------
$dnsOk = $true; $dnsErr = ''
try {
    $nx = 'nx' + [guid]::NewGuid().ToString('N').Substring(0, 12) + '.google.com'
    Resolve-DnsName -Name $nx -Type A -DnsOnly -QuickTimeout -ErrorAction Stop | Out-Null
} catch {
    $id = ($_.FullyQualifiedErrorId -split ',')[0]
    if ($id -ne 'DNS_ERROR_RCODE_NAME_ERROR') { $dnsOk = $false; $dnsErr = $id }
}
$ctrlOk = Test-Url $Cfg.ControlTarget -TimeoutSec 5
$ok = @{}
foreach ($u in $Cfg.CheckTargets) { $ok[$u] = Test-Url $u -TimeoutSec 5 }
$hostOk = @($Cfg.CheckTargets | Where-Object { $ok[$_] }).Count -eq @($Cfg.CheckTargets).Count

# --- Karar --------------------------------------------------------------------
if (-not $dnsOk -or -not $ctrlOk) {
    $st.GeneralFails = [int]$st.GeneralFails + 1
    $st.HostFails = 0
    if ($st.GeneralFails -eq 1) {
        Clear-DnsClientCache; [void]$actions.Add('dns-flush')
    } elseif ($st.GeneralFails -eq 2) {
        foreach ($a in Get-PhysicalAdapters | Where-Object { $_.Status -eq 'Up' }) {
            try { [void]$actions.Add("dns-reapply($($a.Name):$(Set-AdapterDns $a))") }
            catch { [void]$actions.Add("dns-reapply-HATA:$($_.Exception.Message)") }
        }
        Clear-DnsClientCache
    }
} elseif (-not $hostOk) {
    $st.GeneralFails = 0
    $st.HostFails = [int]$st.HostFails + 1
    if ($st.HostFails -ge [int]$Cfg.WinwsRestartAfterMinutes -and $svc) {
        if ([int]$st.FailedRestarts -ge [int]$Cfg.ReselectAfterRestarts -and (Since $st.LastReselect) -ge [double]$Cfg.ReselectCooldownMinutes -and $reselect) {
            try {
                Start-ScheduledTask -TaskName $Cfg.ReselectTaskName
                [void]$actions.Add('strateji-yeniden-secim')
                $st.LastReselect = (Get-Date).ToString('s')
                $st.FailedRestarts = 0; $st.HostFails = 0
            } catch { [void]$actions.Add("strateji-yeniden-secim-HATA:$($_.Exception.Message)") }
        } elseif ((Since $st.LastWinwsRestart) -ge [double]$Cfg.WinwsRestartCooldownMinutes) {
            Restart-Winws
            $st.FailedRestarts = [int]$st.FailedRestarts + 1
            $st.HostFails = 0
        } else { [void]$actions.Add('winws-restart-bekleme') }
    }
} else {
    $st.GeneralFails = 0; $st.HostFails = 0; $st.FailedRestarts = 0
}

# --- Log ----------------------------------------------------------------------
$hostStr = ($Cfg.CheckTargets | ForEach-Object { '{0}={1}' -f ([Uri]$_).Host, $(if ($ok[$_]) { 'OK' } else { 'FAIL' }) }) -join ' '
$line = '{0} svc={1} dns={2}{3} ctrl={4} {5} strateji={6} genFail={7} hostFail={8} restarts={9}{10}' -f `
    (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $svcState, $(if ($dnsOk) { 'OK' } else { 'FAIL' }), $(if ($dnsErr) { "($dnsErr)" } else { '' }),
    $(if ($ctrlOk) { 'OK' } else { 'FAIL' }), $hostStr, (Get-SavedStrategy), $st.GeneralFails, $st.HostFails, $st.FailedRestarts,
    $(if ($actions.Count) { ' ACTION=' + ($actions -join ',') } else { '' })
Add-Content -Path $logFile -Value $line -Encoding UTF8
$st | ConvertTo-Json | Set-Content -Path $statePath -Encoding UTF8

Get-ChildItem $LogDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-[int]$Cfg.LogRetentionDays) } |
    Remove-Item -Force -ErrorAction SilentlyContinue
