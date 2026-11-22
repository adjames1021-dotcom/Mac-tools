# MacTools Lite - Windows diagnostic toolkit. Read-only: changes nothing on the PC.
# Runs on the PowerShell 5.1 built into Windows 10/11. Started by "Windows Tools.bat" on the stick.
#   powershell -ExecutionPolicy Bypass -File WinTools.ps1 [-Report]   (-Report: save the full report and exit)
param([switch]$Report)

$ErrorActionPreference = 'SilentlyContinue'
$Stick = Split-Path -Parent $PSScriptRoot
$Reports = Join-Path $Stick 'Reports'
if (-not (New-Item -ItemType Directory -Force -Path $Reports)) { $Reports = [Environment]::GetFolderPath('Desktop') }
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

function Section($title) { "`r`n==================== $title ====================" }
function GB($bytes) { if ($bytes) { '{0:N1} GB' -f ($bytes / 1GB) } else { '?' } }

function Get-SystemInfo {
    Section 'Computer & Windows'
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    [pscustomobject]@{
        'Computer'     = $env:COMPUTERNAME
        'User'         = "$env:USERDOMAIN\$env:USERNAME"
        'Windows'      = "$($os.Caption) $($os.Version) (build $($os.BuildNumber)) $($os.OSArchitecture)"
        'Installed'    = $os.InstallDate
        'Last boot'    = $os.LastBootUpTime
        'Uptime'       = ((Get-Date) - $os.LastBootUpTime).ToString('d\.hh\:mm') + ' (days.hh:mm)'
        'Maker/Model'  = "$($cs.Manufacturer) $($cs.Model)"
        'Serial'       = $bios.SerialNumber
        'BIOS'         = "$($bios.Manufacturer) $($bios.SMBIOSBIOSVersion) ($($bios.ReleaseDate))"
        'CPU'          = "$($cpu.Name.Trim()) - $($cpu.NumberOfCores) cores / $($cpu.NumberOfLogicalProcessors) threads"
        'CPU load'     = "$($cpu.LoadPercentage)%"
        'RAM'          = "$(GB $cs.TotalPhysicalMemory) total, $(GB ($os.FreePhysicalMemory * 1KB)) free"
    } | Format-List | Out-String -Width 200
    'Memory sticks:'
    Get-CimInstance Win32_PhysicalMemory |
        Select-Object BankLabel, DeviceLocator, @{n='Size';e={GB $_.Capacity}}, Speed, Manufacturer, PartNumber |
        Format-Table -AutoSize | Out-String -Width 200
    'Graphics:'
    Get-CimInstance Win32_VideoController |
        Select-Object Name, DriverVersion, @{n='Resolution';e={"$($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)"}} |
        Format-Table -AutoSize | Out-String -Width 200
}

function Get-DiskHealth {
    Section 'Disks & health'
    if (-not $IsAdmin) { '(Run as administrator for SMART wear and error counters.)' }
    Get-PhysicalDisk | ForEach-Object {
        $r = $_ | Get-StorageReliabilityCounter
        [pscustomobject]@{
            Disk = $_.FriendlyName; Type = $_.MediaType; Bus = $_.BusType; Size = GB $_.Size
            Health = $_.HealthStatus; Status = ($_.OperationalStatus -join ',')
            'Wear%' = $r.Wear; 'Temp C' = $r.Temperature; 'Read errors' = $r.ReadErrorsUncorrected
            'Power-on hrs' = $r.PowerOnHours
        }
    } | Format-Table -AutoSize | Out-String -Width 200
    'Drive failure prediction (SMART):'
    Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus |
        Select-Object InstanceName, PredictFailure | Format-Table -AutoSize | Out-String -Width 200
    'Volumes:'
    Get-Volume | Where-Object DriveLetter |
        Select-Object DriveLetter, FileSystemLabel, FileSystem, HealthStatus,
            @{n='Size';e={GB $_.Size}}, @{n='Free';e={GB $_.SizeRemaining}},
            @{n='Free%';e={if ($_.Size) { [int](100 * $_.SizeRemaining / $_.Size) }}} |
        Format-Table -AutoSize | Out-String -Width 200
}

function Get-BatteryInfo {
    Section 'Battery'
    $b = Get-CimInstance Win32_Battery
    if (-not $b) { return 'No battery (desktop PC).' }
    $full = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity).FullChargedCapacity | Select-Object -First 1
    $design = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData).DesignedCapacity | Select-Object -First 1
    $cycles = (Get-CimInstance -Namespace root\wmi -ClassName BatteryCycleCount).CycleCount | Select-Object -First 1
    "Charge: $($b.EstimatedChargeRemaining)%   Status code: $($b.BatteryStatus)   Cycles: $cycles"
    if ($full -and $design) { "Health: {0}% of design capacity ({1} / {2} mWh)" -f [int](100 * $full / $design), $full, $design }
}

function Get-StartupItems {
    Section 'Startup items'
    Get-CimInstance Win32_StartupCommand | Select-Object Name, Command, Location |
        Format-Table -AutoSize -Wrap | Out-String -Width 250
    'Auto-start services that are not running:'
    Get-CimInstance Win32_Service -Filter "StartMode='Auto' AND State<>'Running'" |
        Select-Object Name, DisplayName, State | Format-Table -AutoSize | Out-String -Width 200
    'Non-Microsoft scheduled tasks:'
    Get-ScheduledTask | Where-Object { $_.State -ne 'Disabled' -and $_.TaskPath -notlike '\Microsoft\*' } |
        Select-Object TaskName, TaskPath, State | Format-Table -AutoSize | Out-String -Width 200
}

function Get-TopProcesses {
    Section 'Top processes'
    'By CPU time:'
    Get-Process | Sort-Object CPU -Descending | Select-Object -First 15 Name, Id,
        @{n='CPU s';e={[int]$_.CPU}}, @{n='RAM MB';e={[int]($_.WorkingSet64 / 1MB)}} | Format-Table -AutoSize | Out-String
    'By memory:'
    Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 15 Name, Id,
        @{n='RAM MB';e={[int]($_.WorkingSet64 / 1MB)}} | Format-Table -AutoSize | Out-String
}

function Get-NetworkInfo {
    Section 'Network'
    Get-NetIPConfiguration | Where-Object { $_.NetAdapter.Status -eq 'Up' } | ForEach-Object {
        [pscustomobject]@{
            Adapter = $_.InterfaceAlias; Description = $_.InterfaceDescription
            IPv4 = ($_.IPv4Address.IPAddress -join ', '); Gateway = ($_.IPv4DefaultGateway.NextHop -join ', ')
            DNS = ($_.DNSServer | Where-Object AddressFamily -eq 2 | ForEach-Object { $_.ServerAddresses }) -join ', '
            Speed = (Get-NetAdapter -InterfaceIndex $_.InterfaceIndex).LinkSpeed
        }
    } | Format-List | Out-String -Width 200
    (netsh wlan show interfaces) -match '^\s+(SSID|Signal|Radio type|Receive rate|Transmit rate)\s' | Out-String
    'Connectivity:'
    $gw = (Get-NetIPConfiguration | Where-Object IPv4DefaultGateway | Select-Object -First 1).IPv4DefaultGateway.NextHop
    foreach ($target in @($gw, '1.1.1.1') | Where-Object { $_ }) {
        $ping = Test-Connection -ComputerName $target -Count 3
        if ($ping) { "Ping {0}: ok, avg {1} ms" -f $target, [int]($ping | Measure-Object ResponseTime -Average).Average }
        else { "Ping ${target}: FAILED" }
    }
    $dns = Resolve-DnsName microsoft.com -Type A | Where-Object IPAddress | Select-Object -First 1
    "DNS microsoft.com: $(if ($dns) { $dns.IPAddress } else { 'FAILED' })"
    "HTTPS www.microsoft.com:443: $(if (Test-NetConnection www.microsoft.com -Port 443 -InformationLevel Quiet) { 'ok' } else { 'FAILED' })"
}

function Get-RecentErrors {
    Section 'Errors in the event log (last 7 days)'
    $since = (Get-Date).AddDays(-7)
    'Unexpected shutdowns, crashes and disk errors:'
    Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $since; Id = 41, 6008, 1001, 7, 51, 153 } -MaxEvents 30 |
        Select-Object TimeCreated, Id, ProviderName, @{n='Message';e={($_.Message -split "`n")[0]}} |
        Format-Table -AutoSize -Wrap | Out-String -Width 250
    'Most frequent errors:'
    Get-WinEvent -FilterHashtable @{ LogName = 'System', 'Application'; Level = 1, 2; StartTime = $since } -MaxEvents 500 |
        Group-Object ProviderName, Id | Sort-Object Count -Descending | Select-Object -First 15 Count, Name |
        Format-Table -AutoSize | Out-String -Width 200
}

function Get-Security {
    Section 'Security'
    $av = Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntivirusProduct
    "Antivirus: $(($av.displayName | Sort-Object -Unique) -join ', ')"
    $mp = Get-MpComputerStatus
    if ($mp) { "Defender: real-time $($mp.RealTimeProtectionEnabled), signatures $($mp.AntivirusSignatureLastUpdated)" }
    "Firewall: " + ((Get-NetFirewallProfile | ForEach-Object { "$($_.Name)=$($_.Enabled)" }) -join ' ')
    $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive
    "BitLocker ($env:SystemDrive): $(if ($bl) { $bl.ProtectionStatus } else { 'unknown (needs admin)' })"
    "Secure Boot: $(try { Confirm-SecureBootUEFI -ErrorAction Stop } catch { 'unknown / legacy BIOS' })"
    'Last 5 updates:'
    Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 5 HotFixID, Description, InstalledOn |
        Format-Table -AutoSize | Out-String
}

$Checks = [ordered]@{
    '1' = @('System & hardware info', { Get-SystemInfo })
    '2' = @('Disk health', { Get-DiskHealth })
    '3' = @('Battery', { Get-BatteryInfo })
    '4' = @('Startup items', { Get-StartupItems })
    '5' = @('Top processes', { Get-TopProcesses })
    '6' = @('Network test', { Get-NetworkInfo })
    '7' = @('Recent errors (event log)', { Get-RecentErrors })
    '8' = @('Security status', { Get-Security })
}

function Save-FullReport {
    $file = Join-Path $Reports ("Windows-{0}-{1:yyyy-MM-dd_HHmm}.txt" -f $env:COMPUTERNAME, (Get-Date))
    Write-Host 'Building the full report (about a minute)...'
    & {
        "MacTools Lite diagnostic report`r`nComputer: $env:COMPUTERNAME`r`nCreated:  $(Get-Date)`r`nAdmin:    $IsAdmin"
        foreach ($c in $Checks.Values) { Write-Host "  $($c[0])"; & $c[1] }
    } | Out-File -FilePath $file -Encoding utf8 -Width 250
    if ($IsAdmin -and (Get-CimInstance Win32_Battery)) {
        powercfg /batteryreport /output (Join-Path $Reports "Battery-$env:COMPUTERNAME.html") | Out-Null
    }
    Write-Host "Saved: $file" -ForegroundColor Green
    $file
}

if ($Report) { Save-FullReport | Out-Null; exit 0 }

while ($true) {
    Clear-Host
    Write-Host 'MacTools Lite - Windows diagnostics' -ForegroundColor Cyan
    Write-Host "Computer: $env:COMPUTERNAME   Admin: $IsAdmin   Reports: $Reports`n"
    Write-Host '  R  Save full report to the stick'
    foreach ($k in $Checks.Keys) { Write-Host "  $k  $($Checks[$k][0])" }
    Write-Host '  B  Battery report (HTML, powercfg)'
    Write-Host '  W  Windows tools: S=System Info  M=Resource Monitor  E=Event Viewer  D=Device Manager  K=Memory test'
    Write-Host '  Q  Quit'
    $choice = (Read-Host "`nChoose").Trim().ToUpper()
    switch ($choice) {
        'Q' { exit 0 }
        'R' { $f = Save-FullReport; Start-Process notepad.exe $f }
        'B' {
            $f = Join-Path $Reports "Battery-$env:COMPUTERNAME.html"
            powercfg /batteryreport /output $f | Out-Null
            if (Test-Path $f) { Start-Process $f } else { Write-Host 'No battery report (no battery, or try Run as administrator).' }
        }
        'S' { Start-Process msinfo32.exe }
        'M' { Start-Process resmon.exe }
        'E' { Start-Process eventvwr.msc }
        'D' { Start-Process devmgmt.msc }
        'K' { Start-Process mdsched.exe }
        default {
            if ($Checks.Contains($choice)) { & $Checks[$choice][1] | Out-Host }
            elseif ($choice -ne 'W') { Write-Host 'Unknown choice.' }
        }
    }
    Read-Host "`nPress Enter for the menu" | Out-Null
}
