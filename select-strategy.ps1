<#
  select-strategy.ps1 - Bu agda Discord'u acan stratejiyi yeniden bulur ve kurulu hizmete uygular (YONETICI gerekir).
  Ag ya da internet saglayicisi degistiginde saglik kontrolu bunu kendiliginden calistirir;
  elle calistirmak icin select-strategy.cmd'ye cift tiklayin.
  Internet yoksa hicbir sey degistirmez.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
Assert-Admin
Start-Log 'select-strategy'

if (-not (Get-Service -Name $Cfg.ServiceName -ErrorAction SilentlyContinue)) { throw "Kurulu degil. Once install.cmd calistirin." }
$old = Get-SavedStrategy
Log "=== Strateji secimi. Mevcut: $old"

$healthPaused = $false
try {
    if (Get-ScheduledTask -TaskName $Cfg.TaskName -ErrorAction SilentlyContinue) {
        Disable-ScheduledTask -TaskName $Cfg.TaskName | Out-Null
        $healthPaused = $true
    }
    Stop-Service -Name $Cfg.ServiceName -Force
    foreach ($p in Get-ConflictProcesses) { Log "Calisan DPI araci kapatiliyor: $($p.Name) (PID $($p.Id))"; Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    Get-Process -Name winws -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Stop-WinDivertDriver
    Clear-DnsClientCache

    if (-not (Test-Url $Cfg.ControlTarget)) {
        Log "Internet yok ($($Cfg.ControlTarget) acilmiyor); strateji degistirilmedi."
    } else {
        $dns = Test-DnsPoison
        if ($dns.Poisoned) { Log "UYARI: discord.com DNS cevabi hatali gorunuyor ($($dns.System -join ',')). diagnose.cmd calistirin." }
        $base = Test-Discord
        Log "DPI araci olmadan Discord: $($base.Passed)/$($base.Total)"
        $new = Find-Strategy
        if ($new) {
            Save-Strategy $new
            if ($new -ne $old) { Set-WinwsService $new }
            Log "Secilen strateji: $new"
        } else {
            Log "Hicbir strateji ise yaramadi; mevcut strateji ($old) korunuyor."
        }
    }
} finally {
    Get-Process -Name winws -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$InstallDir*" } | Stop-Process -Force -ErrorAction SilentlyContinue
    if (Start-WinwsService) { Log 'winws hizmeti calisiyor.' } else { Log '!! winws hizmeti baslamadi.' }
    if ($healthPaused) { Enable-ScheduledTask -TaskName $Cfg.TaskName | Out-Null }
}
$final = Test-Discord
Log "Son kontrol: Discord $($final.Passed)/$($final.Total)$(if ($final.Failed) { '  basarisiz: ' + ($final.Failed -join ', ') })"
