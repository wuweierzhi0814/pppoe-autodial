<#
    Manage-PPPoEAutoDial.ps1
    One-click install / uninstall / emergency-stop for the PPPoE auto-dial task.

    ASCII-only on purpose: Windows PowerShell 5.1 decodes .ps1 files that lack a
    UTF-8 BOM as the system ANSI codepage, which corrupts non-ASCII literals and
    breaks parsing. Keeping this file pure ASCII removes that failure class.

    Normally you do NOT call this directly - double-click install.bat / uninstall.bat.

    Usage (elevated PowerShell is required for -Install and -Uninstall):

      -TaskStatus              show task state + worker state (changes nothing)
      -Install                 detect the PPPoE connection, copy the files to
                               %ProgramData%\PPPoEAutoDial, write settings.json and
                               register the scheduled task
      -Install -StartNow       ... and run it once straight away
      -Install -ConnectionName "Broadband Connection"
                               ... skip auto-detection
      -Panic                   emergency stop: kill instance + stop.flag + disable task
      -Reset                   clear the worker lock/counters (needed after a self-lock)
      -Uninstall               remove the scheduled task
      -Uninstall -Purge        ... and delete %ProgramData%\PPPoEAutoDial as well

    Design choices that exist purely for controllability:
      * ExecutionTimeLimit = PT30M   -> the OS itself kills the run after 30 min,
                                        even if the worker script hangs.
      * MultipleInstancesPolicy = IgnoreNew -> the OS refuses to start a second copy.
      * No RestartOnFailure          -> retrying is the worker's job, and it is bounded;
                                        an OS-level retry loop is how you get a
                                        22-minute hammering incident.
      * RunLevel defaults to LeastPrivilege -> dialing needs no administrator rights.
#>

[CmdletBinding()]
param(
    [switch]$TaskStatus,
    [switch]$Install,
    [switch]$StartNow,
    [switch]$Panic,
    [switch]$Reset,
    [switch]$Uninstall,
    [switch]$Purge,
    [switch]$RunLevelHighest,
    [switch]$WithResumeTrigger,
    [switch]$WithDropTrigger,
    [string]$ConnectionName = '',
    [string]$TaskName       = 'PPPoEAutoDial',
    [string]$InstallDir     = ''
)

$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }
if (-not $InstallDir) { $InstallDir = Join-Path $env:ProgramData 'PPPoEAutoDial' }

$WorkerName      = 'PPPoEAutoDial.ps1'
$Worker          = Join-Path $ScriptDir $WorkerName
$InstalledWorker = Join-Path $InstallDir $WorkerName
$SettingsFile    = Join-Path $InstallDir 'settings.json'
$StopFlag        = Join-Path $InstallDir 'stop.flag'

function Get-WorkerPath {
    # Prefer the installed copy; fall back to the one next to this script.
    if (Test-Path $InstalledWorker) { return $InstalledWorker }
    if (Test-Path $Worker) { return $Worker }
    return $null
}

function Show-WorkerState {
    $w = Get-WorkerPath
    if (-not $w) { Write-Host 'worker script not found (neither installed nor local)'; return }
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $w -Status
}

function Test-TaskFile {
    # Fallback for contexts where Get-ScheduledTask is unavailable or denied
    # (restricted token, some sandboxes). The task definition file under
    # System32\Tasks is plain XML and readable without elevation, so the tool can
    # still tell "installed" from "not installed" instead of guessing wrong.
    return (Test-Path (Join-Path $env:WINDIR ('System32\Tasks\' + $TaskName)))
}

function Get-TaskInfo {
    try { return Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop } catch { return $null }
}

function Test-TaskPresent {
    return ((Get-TaskInfo) -ne $null) -or (Test-TaskFile)
}

# ---------------------------------------------------------------- connection discovery
function Read-PbkText {
    param([string]$Path)
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
        }
        # UTF-16 without BOM shows up as a high proportion of zero bytes
        $scan = [math]::Min(200, $bytes.Length)
        $zeros = 0
        for ($i = 0; $i -lt $scan; $i++) { if ($bytes[$i] -eq 0) { $zeros++ } }
        if ($scan -gt 0 -and ($zeros * 3) -gt $scan) {
            return [System.Text.Encoding]::Unicode.GetString($bytes)
        }
        return [System.Text.Encoding]::Default.GetString($bytes)
    } catch { return '' }
}

function Get-ConnectionCandidates {
    $found = New-Object System.Collections.ArrayList

    # PPP interfaces that exist right now
    try {
        foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($ni.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Ppp) {
                [void]$found.Add($ni.Name)
            }
        }
    } catch { }

    # entry names in the RAS phonebooks (per-user and all-users)
    $pbks = @(
        (Join-Path $env:APPDATA 'Microsoft\Network\Connections\Pbk\rasphone.pbk'),
        (Join-Path $env:ProgramData 'Microsoft\Network\Connections\Pbk\rasphone.pbk')
    )
    foreach ($p in $pbks) {
        if (-not (Test-Path $p)) { continue }
        foreach ($line in ((Read-PbkText -Path $p) -split "`r?`n")) {
            if ($line -match '^\s*\[(.+?)\]\s*$') { [void]$found.Add($Matches[1].Trim()) }
        }
    }

    return ($found | Where-Object { $_ } | Select-Object -Unique)
}

function Resolve-ConnectionName {
    if ($ConnectionName) { return $ConnectionName }

    $cands = @(Get-ConnectionCandidates)

    if ($cands.Count -eq 1) {
        Write-Host "  auto-detected connection : $($cands[0])"
        return $cands[0]
    }

    if ($cands.Count -gt 1) {
        Write-Host '  Several candidate connections were found:'
        for ($i = 0; $i -lt $cands.Count; $i++) {
            Write-Host ('    [{0}] {1}' -f ($i + 1), $cands[$i])
        }
        Write-Host '  (VPN entries may be listed too - pick your broadband / PPPoE one.)'
        $ans = Read-Host '  Number, or the exact name'
        if ($ans -match '^\d+$' -and [int]$ans -ge 1 -and [int]$ans -le $cands.Count) {
            return $cands[[int]$ans - 1]
        }
        return $ans
    }

    Write-Host '  No connection could be detected automatically.'
    Write-Host '  Create the broadband (PPPoE) connection in Windows first, then re-run.'
    return (Read-Host '  Connection name, exactly as it appears in the dial-up list')
}

# ---------------------------------------------------------------- status
if ($TaskStatus) {
    $t = Get-TaskInfo
    if ($t) {
        Write-Host "task name    : $TaskName"
        Write-Host "task state   : $($t.State)"
        foreach ($tr in $t.Triggers) {
            Write-Host "trigger      : $($tr.CimClass.CimClassName)"
            if ($tr.Subscription) { Write-Host "    subscribes: $($tr.Subscription)" }
        }
        Write-Host "run level    : $($t.Principal.RunLevel)"
        Write-Host "time limit   : $($t.Settings.ExecutionTimeLimit)"
        Write-Host "multi-inst   : $($t.Settings.MultipleInstances)"
        Write-Host "restart-on-fail: $($t.Settings.RestartCount)"
    } elseif (Test-TaskFile) {
        Write-Host "task name    : $TaskName"
        Write-Host 'task state   : installed (read from the task definition file;'
        Write-Host '               Get-ScheduledTask is unavailable in this context)'
    } else {
        Write-Host "task '$TaskName' : NOT INSTALLED"
    }
    Write-Host "install dir  : $InstallDir  (exists: $(Test-Path $InstallDir))"
    Write-Host "settings     : $SettingsFile  (exists: $(Test-Path $SettingsFile))"
    Write-Host "stop.flag    : $(Test-Path $StopFlag)"
    Write-Host '--- worker state ---'
    Show-WorkerState
    exit 0
}

# ---------------------------------------------------------------- reset
if ($Reset) {
    $w = Get-WorkerPath
    if (-not $w) { Write-Host 'worker script not found'; exit 1 }
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $w -Reset
    exit 0
}

# ---------------------------------------------------------------- panic
if ($Panic) {
    Write-Host '*** PANIC STOP ***'
    # 1. file-level kill switch first: even a running instance checks it every few seconds
    if (Test-Path $InstallDir) {
        Set-Content -LiteralPath $StopFlag -Value ('panic stop at {0}' -f (Get-Date).ToString('s')) -Encoding UTF8
        Write-Host "  stop.flag written: $StopFlag"
    }

    # 2. stop a running instance (Stop-ScheduledTask kills the task's process tree)
    $t = Get-TaskInfo
    if ($t -or (Test-TaskFile)) {
        try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop; Write-Host '  running instance stopped' }
        catch { Write-Host "  stop instance: $($_.Exception.Message)" }

        # 3. disable the task so it cannot start again by itself
        try {
            Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
            Write-Host '  task DISABLED'
        } catch {
            $r = & schtasks.exe /change /tn $TaskName /disable 2>&1
            Write-Host "  disable result: $r"
        }
    } else {
        Write-Host "  task '$TaskName' not installed - nothing to disable"
    }

    Write-Host '--- final state ---'
    Show-WorkerState
    exit 0
}

# ---------------------------------------------------------------- uninstall
if ($Uninstall) {
    $t = Get-TaskInfo
    if ($t -or (Test-TaskFile)) {
        try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch { }
        try {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
            Write-Host "task '$TaskName' removed"
        } catch {
            $r = & schtasks.exe /delete /tn $TaskName /f 2>&1
            Write-Host "delete result: $r"
        }
    } else {
        Write-Host "task '$TaskName' was not installed"
    }

    if ($Purge) {
        if (Test-Path $InstallDir) {
            Remove-Item -LiteralPath $InstallDir -Recurse -Force
            Write-Host "removed $InstallDir"
        }
    } else {
        Write-Host "kept (logs + settings): $InstallDir   -- add -Purge to delete it"
    }
    exit 0
}

# ---------------------------------------------------------------- install
if ($Install) {
    if (-not (Test-Path $Worker)) { throw "worker script not found next to this script: $Worker" }

    Write-Host '  -- choosing the connection --'
    $name = Resolve-ConnectionName
    if (-not $name) { throw 'no connection name was given; nothing to install' }

    # ---- copy the payload into a stable location -------------------
    if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
    Copy-Item -LiteralPath $Worker -Destination $InstalledWorker -Force
    $localManage = Join-Path $ScriptDir 'Manage-PPPoEAutoDial.ps1'
    if ((Test-Path $localManage) -and ($localManage -ne (Join-Path $InstallDir 'Manage-PPPoEAutoDial.ps1'))) {
        Copy-Item -LiteralPath $localManage -Destination $InstallDir -Force
    }
    # the task runs as the logged-on user without elevation, so that user must be able
    # to write logs / state.json / stop.flag in here
    & icacls.exe $InstallDir /grant 'BUILTIN\Users:(OI)(CI)(M)' | Out-Null

    # ---- settings ------------------------------------------------
    @{ ConnectionName = $name } | ConvertTo-Json |
        Set-Content -LiteralPath $SettingsFile -Encoding UTF8

    # ---- scheduled task ------------------------------------------
    $user      = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
    $runLevel  = if ($RunLevelHighest) { 'HighestAvailable' } else { 'LeastPrivilege' }
    $argsLine  = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $InstalledWorker

    $extraTriggers = ''
    if ($WithResumeTrigger) {
        $extraTriggers += @'
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and EventID=507]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
      <Delay>PT5S</Delay>
    </EventTrigger>
'@
    }
    if ($WithDropTrigger) {
        # RasMan 20268 = "the connection ... was disconnected".  This is the port's own
        # state transition reported by the OS, so the task wakes the instant the PPPoE
        # session drops - no polling, no traffic, zero latency.
        $extraTriggers += @'
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='RasMan'] and EventID=20268]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
      <Delay>PT5S</Delay>
    </EventTrigger>
'@
    }

    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>PPPoE AutoDial - bounded auto-dial: first dial 20 s after wake-up, 10 attempts max, 8 min retry window, 25 min run cap, 30 min OS hard kill, time-based self-lock (30 min of continuous failing) plus immediate lock on RAS 651/756.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$user</UserId>
      <Delay>PT0S</Delay>
    </LogonTrigger>
$extraTriggers
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$user</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>$runLevel</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT30M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>$argsLine</Arguments>
    </Exec>
  </Actions>
</Task>
"@

    Register-ScheduledTask -TaskName $TaskName -Xml $xml -Force | Out-Null
    if (-not (Test-TaskPresent)) { throw "the task was registered but '$TaskName' cannot be found afterwards" }

    Write-Host ''
    Write-Host '  -- installed --'
    Write-Host "  connection : $name"
    Write-Host "  task       : $TaskName  (run level $runLevel)"
    Write-Host "  payload    : $InstallDir"
    Write-Host "  triggers   : logon + resume$(if ($WithResumeTrigger) { ' (Kernel-Power 507)' } else { ' (none)' }) + drop$(if ($WithDropTrigger) { ' (RasMan 20268)' } else { ' (none)' })"
    Write-Host '  hard kill  : PT30M, enforced by Task Scheduler itself, not by the script'

    if ($StartNow) {
        Write-Host ''
        Write-Host '  starting once now...'
        Start-ScheduledTask -TaskName $TaskName
        Start-Sleep -Seconds 3
        Get-TaskInfo | Select-Object TaskName, State | Format-List
    } else {
        Write-Host ''
        Write-Host '  Not started. It will run by itself on the triggers listed above.'
    }
    exit 0
}

# ---------------------------------------------------------------- default
Write-Host 'nothing to do. Pick one of:'
Write-Host '  -TaskStatus  -Install [-StartNow] [-ConnectionName "name"]  -Panic  -Reset  -Uninstall [-Purge]'
Write-Host "worker(s): $InstalledWorker | $Worker"
exit 1
