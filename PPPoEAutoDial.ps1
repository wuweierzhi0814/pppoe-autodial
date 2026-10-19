<#
    PPPoEAutoDial.ps1
    Bounded, self-limiting PPPoE auto-dial helper for Windows 10 / 11.

    Configured entirely by settings.json sitting next to this file:
        ConnectionName   - the name of the PPPoE entry (see the installer)

    ------------------------------------------------------------------
    HARD RULES - do not weaken these without updating the design doc
    ------------------------------------------------------------------
      1. ONE instance at a time        named mutex, second instance exits
      2. Bounded lifetime              MaxRunSeconds, then exit unconditionally
      3. Bounded attempts              MaxAttemptsPerRun per run
      4. GLOBAL minimum interval       MinSecondsBetweenAttempts, enforced through
                                       state.json so it also holds ACROSS runs
      5. TIME-BASED self-lock          LockAfterFailingSeconds of CONTINUOUS failing
                                       (not a failure COUNT) -> locked; then it refuses
                                       to dial at all until someone runs -Reset.
                                       Fatal RAS codes 651/756 lock immediately.
      6. Never dial while the PPP session is already up (this is what caused the
         756/651 cascade on 2026-10-10)
      7. Every action is written to a log

    ------------------------------------------------------------------
    WHY THE LOCK IS TIME-BASED AND NOT COUNT-BASED (measured 2026-10-14)
    ------------------------------------------------------------------
    On the 07:25:41 boot the worker started 07:26:39, got RAS 628 three times in
    40 s, and locked itself.  The connection only became possible at 07:30:47 --
    a ~3.5 minute "ghost session" window that the carrier controls.  A count of
    three failures therefore fired long before the hardware could possibly have
    succeeded, and left the user offline.  Time is the honest criterion.

    ------------------------------------------------------------------
    WHY THIS FILE IS ASCII-ONLY
    ------------------------------------------------------------------
    Windows PowerShell 5.1 decodes .ps1 files that lack a UTF-8 BOM as GBK,
    which corrupts non-ASCII string literals and breaks parsing. Keeping this
    file pure ASCII removes that entire failure class. Chinese documentation
    lives in the .md files next to it.

    Usage:
      powershell -NoProfile -ExecutionPolicy Bypass -File PPPoEAutoDial.ps1
      ... -DryRun     log what it WOULD do; never calls rasdial
      ... -Status     print state and exit
      ... -Reset      clear the lock and counters (required after a lock)
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Status,
    [switch]$Reset,
    [int]$RunLimitSecondsOverride = 0,  # self-test only; the scheduled task never passes this
    [switch]$SimulateSessionDown        # self-test only; ONLY honoured together with -DryRun
)

$ErrorActionPreference = 'Continue'

$BaseDir = $PSScriptRoot
if (-not $BaseDir) { $BaseDir = (Get-Location).Path }

$StatePath    = Join-Path $BaseDir 'state.json'
$LogPath      = Join-Path $BaseDir 'autodial.log'
$LogOldPath   = Join-Path $BaseDir 'autodial.log.old'
$StopFlag     = Join-Path $BaseDir 'stop.flag'
$SettingsPath = Join-Path $BaseDir 'settings.json'
$FallbackLog  = Join-Path $env:TEMP 'PPPoEAutoDial-fallback.log'
$HeartbeatPath = Join-Path $BaseDir 'autodial.heartbeat'
$MutexName    = 'Local\PPPoEAutoDial'

# ==================== MAXIMUM THRESHOLDS ====================
$Cfg = @{
    ConnectionName            = ''          # PPPoE entry name; the installer fills this in

    # --- timing of the very first dial (task starts at logon) ---
    FirstAttemptDelaySeconds  = 20         # -> first dial ~20 s after logon

    # --- per-run bounds ---
    MaxRunSeconds             = 1500       # 25 min - process hard lifetime
    RetryWindowSeconds        = 480        # 8 min  - how long one run keeps trying
    MaxAttemptsPerRun         = 10         # with the backoff below this fills the window

    # --- pacing (never faster than the floor, never slower than the ceiling) ---
    MinSecondsBetweenAttempts = 20         # global floor, held across runs via state.json
    MaxSecondsBetweenAttempts = 60         # backoff ceiling

    # The gap AFTER A FIRST FAILURE gets one long, hands-off pause instead of the usual
    # short escalation.  Measured on 2026-10-14/15: every early attempt returned RAS 628
    # (the remote terminated the connection during authentication) while the link came
    # back by itself 19-96 s later, and the user's successful manual click landed 24-31 s
    # BEFORE our next scheduled attempt -- twice.  A carrier needs roughly 1.5-3 minutes
    # to release the previous session after an abrupt drop, so if repeated early attempts
    # are what keeps the port hot, this pause is what breaks the cycle.
    # Attempt 1 still fires at FirstAttemptDelaySeconds, so the original requirement
    # ("connect ~20 s after logon") is untouched; only the gap after a failure changes.
    # Resulting cadence: 20 s -> (fail) -> 180 s -> 40 s -> 60 s -> 60 s ...
    AfterFirstFailureWaitSeconds = 180

    # --- success criterion ---
    StableSeconds             = 600        # 10 min up = healthy, run finishes

    # --- lock (fatal conditions) ---
    LockAfterFailingSeconds   = 1800       # 30 min of CONTINUOUS failing -> lock
    LockOnErrorCodes          = @(651, 756) # 651 = port wedged, 756 = concurrent dial

    # --- policy: never fight another working internet path ---
    # 1 = if this machine already reaches the internet by any other means (phone USB
    #     tethering, wifi, ...) then do NOT dial.  This is what keeps the tool from
    #     yanking the user back onto PPPoE when they deliberately switched away.
    DialOnlyWhenNoInternet    = 1
    OtherPathRecheckSeconds   = 30

    # --- probes ---
    ProbeTimeoutMs            = 2000
    ProbeIntervalSeconds      = 5
    # Empty = detect the broadband account name from the RasMan event log and hand it to
    # rasdial as an explicit account argument. Set it to force a specific name.
    DialWithAccountName       = ''
    DialTimeoutMs             = 90000
    LogRotateBytes            = 524288
    ProbeEndpoints            = @('223.5.5.5:53', '119.29.29.29:53', '180.76.76.76:53')
}
# ============================================================

if (Test-Path $SettingsPath) {
    try {
        $ov = Get-Content $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in @($Cfg.Keys)) {
            if ($ov.PSObject.Properties.Name -contains $k) { $Cfg[$k] = $ov.$k }
        }
    } catch { }
}
if ($RunLimitSecondsOverride -gt 0) { $Cfg.MaxRunSeconds = $RunLimitSecondsOverride }

# ---------------- resolve the connection name ----------------
# settings.json normally carries it (the installer writes it). If it is missing, fall
# back to whatever PPP interface currently exists so the script still works. If the
# name cannot be resolved the worker reports it instead of guessing.
if (-not $Cfg.ConnectionName) {
    try {
        foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($ni.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Ppp) {
                $Cfg.ConnectionName = $ni.Name
                break
            }
        }
    } catch { }
}

# ==================== native helpers (compiled once per run) ====================
# WHY THIS EXISTS
#   NetworkInterface.GetAllNetworkInterfaces() has to ask NDIS about every adapter and
#   is known to block for a long time on some machines. A blocked call cannot be
#   interrupted, so the whole worker freezes with it. From the outside that is
#   invisible: the log simply stops mid-run, no [END] is ever written, and the only
#   thing that ends the run is the task's 30-minute OS hard kill. Observed four times
#   on 2026-10-14.
#   RasEnumConnections talks to the RAS subsystem only. It is faster, it cannot get
#   stuck behind a network driver, and it is the AUTHORITATIVE answer to "is the
#   session up" -- it is the same state the Windows dial-up dialog shows.
#   If this type fails to compile we fall back to the enumeration, so nothing breaks.
$NativeSrc = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class RasHelper
{
    // sizeof(RASCONN) on Windows 7+ is 1388 bytes.  The API also still accepts 1360
    // and 1372, which are the older versions of the structure, so a wrong value here
    // gets rejected with RAS error 632 ("the structure size is incorrect").
    private const int ConnSize   = 1388;
    // Pack=4 layout: dwSize (4 bytes) then hrasconn (8 bytes) -> the entry name starts
    // at offset 12.  Verified against a live connection on 2026-10-14.
    private const int NameOffset = 12;
    private const int NameChars  = 257;

    // Marshalling an array of structures containing ByValTStr silently produces the
    // wrong stride, so this deliberately passes a raw byte buffer and parses it here.
    [DllImport("rasapi32.dll", CharSet = CharSet.Unicode)]
    private static extern int RasEnumConnections([In, Out] byte[] buf, ref int cb, ref int n);

    // Gives the REAL session state, not merely "an entry exists". Without this a
    // connection that is still negotiating looks exactly like a finished one, which is
    // how the worker could stand down while somebody else's dial was still in flight.
    [DllImport("rasapi32.dll", CharSet = CharSet.Unicode)]
    private static extern int RasGetConnectStatus(IntPtr hrasconn, [In, Out] byte[] status);

    // sizeof(RASCONNSTATUS) on Windows 7+ - found by bisection on 2026-10-16.
    private const int StatusSize = 304;
    // RASCONNSTATE: the enum is 0..23, then 0x1000..0x1003, then these two.
    public const int StateConnected    = 0x2000;   // RASCS_Connected
    public const int StateDisconnected = 0x2001;   // RASCS_Disconnected

    // Entry name plus the matching RASCONNSTATE for every active RAS connection.
    // Returns null when the RAS subsystem cannot be queried at all.
    public static string[] Status(out int[] states)
    {
        states = new int[0];
        const int max = 16;
        byte[] buf = new byte[ConnSize * max];
        BitConverter.GetBytes(ConnSize).CopyTo(buf, 0);
        int cb = buf.Length;
        int n  = 0;
        if (RasEnumConnections(buf, ref cb, ref n) != 0) { return null; }
        if (n <= 0) { return new string[0]; }
        if (n > max) { n = max; }

        string[] res = new string[n];
        states = new int[n];
        byte[] st = new byte[512];
        for (int i = 0; i < n; i++)
        {
            int baseOff = i * ConnSize;
            int off = baseOff + NameOffset;
            int len = 0;
            while (len < NameChars && BitConverter.ToChar(buf, off + (len * 2)) != '\0') { len++; }
            res[i] = Encoding.Unicode.GetString(buf, off, len * 2);

            // Assume the worst if the status call fails, so a stuck entry can never be
            // mistaken for a healthy connection.
            states[i] = StateDisconnected;
            try
            {
                IntPtr h = (IntPtr)BitConverter.ToInt64(buf, baseOff + 4);
                BitConverter.GetBytes(StatusSize).CopyTo(st, 0);
                if (RasGetConnectStatus(h, st) == 0) { states[i] = BitConverter.ToInt32(st, 4); }
            }
            catch { }
        }
        return res;
    }

    // A heartbeat from a real background thread. It keeps writing even when the main
    // loop is wedged inside a blocking call, which is the only way to tell "frozen but
    // alive" apart from "dead" using nothing but files on disk.
    public static void StartHeartbeat(string path, int seconds)
    {
        Thread t = new Thread(delegate()
        {
            while (true)
            {
                try
                {
                    File.AppendAllText(path,
                        DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " alive" + Environment.NewLine);
                }
                catch { }
                Thread.Sleep(seconds * 1000);
            }
        });
        t.IsBackground = true;
        t.Start();
    }
}
'@
$NativeOk = $false
try {
    if (-not ('RasHelper' -as [type])) {
        Add-Type -TypeDefinition $NativeSrc -Language CSharp -ErrorAction Stop
    }
    $NativeOk = $true
} catch { }

function Get-RasStatus {
    # Every active RAS connection as @(@{ Name = ...; State = ... }), or $null when the
    # native helper is unavailable (in which case callers fall back to enumeration).
    if (-not $NativeOk) { return $null }
    try {
        $states = $null
        $names = [RasHelper]::Status([ref]$states)
        if ($null -eq $names) { return $null }
        $out = @()
        for ($i = 0; $i -lt @($names).Count; $i++) {
            $out += [pscustomobject]@{ Name = [string]$names[$i]; State = [int]$states[$i] }
        }
        return ,$out
    } catch { return $null }
}

function Resolve-DialAccount {
    # The broadband account name, for the "rasdial <entry> <account>" form.
    # It is NOT hardcoded: Windows itself records it in the RasMan 20267 message
    # ("The user <account> successfully established a connection to <entry>"), so the
    # worker can read back the account of the last connection that ever worked.
    param([string]$Configured = '')
    if ($Configured) { return $Configured }
    try {
        $ev = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='RasMan'; Id=20267} -MaxEvents 5 -ErrorAction Stop
        foreach ($e in $ev) {
            if ($e.Message -match 'The user\s+(\S+)\s+successfully established') { return $Matches[1] }
        }
    } catch { }
    return ''
}

# ---------------- logging ----------------
if ((Test-Path $LogPath) -and ((Get-Item $LogPath).Length -gt $Cfg.LogRotateBytes)) {
    Move-Item -LiteralPath $LogPath -Destination $LogOldPath -Force -ErrorAction SilentlyContinue
}

$script:LogWriteFailures = 0
function Write-Log {
    param([string]$Level, [string]$Message)
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Never lose the record silently. If every write to the main log failed, the run
        # would look EXACTLY like a run that was killed: both just stop mid-way and never
        # write [END]. A shadow copy in %TEMP% separates those two cases.
        $script:LogWriteFailures++
        try { Add-Content -LiteralPath $FallbackLog -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
    }
    Write-Host $line
}

# ---------------- state ----------------
function New-DefaultState {
    [pscustomobject]@{
        locked              = $false
        lockReason          = ''
        consecutiveFailures = 0
        failingSinceUtc     = ''      # start of the current CONTINUOUS failing streak
        lastAttemptUtc      = ''
        totalAttempts       = 0
        lastRunUtc          = ''
    }
}

function Get-State {
    if (Test-Path $StatePath) {
        try {
            $s = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $d = New-DefaultState
            foreach ($p in @($d.PSObject.Properties.Name)) {
                if (-not ($s.PSObject.Properties.Name -contains $p)) {
                    $s | Add-Member -NotePropertyName $p -NotePropertyValue $d.$p
                }
            }
            return $s
        } catch { }
    }
    return (New-DefaultState)
}

function Save-State($s) {
    $s.lastRunUtc = (Get-Date).ToUniversalTime().ToString('o')
    try { $s | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StatePath -Encoding UTF8 } catch { }
}

function Get-FailingSeconds($s) {
    if (-not $s.failingSinceUtc) { return 0 }
    try { return [int]((Get-Date).ToUniversalTime() - [datetime]::Parse($s.failingSinceUtc).ToUniversalTime()).TotalSeconds }
    catch { return 0 }
}

# ---------------- checks ----------------
function Test-SessionUp {
    # Test hook: only ever takes effect together with -DryRun, so it is structurally
    # incapable of causing a real dial. It exists so the gating logic can be tested.
    if ($DryRun -and $SimulateSessionDown) { return $false }

    # 1) authoritative source: ask the RAS subsystem for the REAL state. Cheap, and it
    #    cannot get stuck behind a network driver the way the adapter enumeration can.
    #    Only RASCS_Connected counts as up. A connection that is still negotiating is
    #    NOT up, and treating it as up is how the worker used to stand down while
    #    somebody else's dial was still in flight.
    $rs = Get-RasStatus
    if ($null -ne $rs) {
        foreach ($r in $rs) {
            if ($r.Name -eq $Cfg.ConnectionName -and [int]$r.State -eq [RasHelper]::StateConnected) { return $true }
        }
        return $false
    }

    # 2) fallback, only when the native helper is unavailable
    try {
        foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($ni.Name -ne $Cfg.ConnectionName) { continue }
            if ($ni.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { return $false }
            $v4 = @($ni.GetIPProperties().UnicastAddresses | Where-Object {
                $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork })
            return ($v4.Count -gt 0)
        }
    } catch { }
    return $false
}

function Test-DialInProgress {
    # True when this entry is present in RAS but NOT in the Connected state - i.e. a dial
    # is under way right now, started by the worker, by Windows' own auto-redial (the
    # profile has RedialOnLinkFailure = 1), or by the user clicking Connect.
    # Dialing into that window is what returns RAS 628, and two concurrent dials are what
    # once wedged the port into 651 - so waiting is strictly better than colliding.
    $rs = Get-RasStatus
    if ($null -eq $rs) { return $false }
    foreach ($r in $rs) {
        if ($r.Name -ne $Cfg.ConnectionName) { continue }
        $s = [int]$r.State
        if ($s -ne [RasHelper]::StateConnected -and $s -ne [RasHelper]::StateDisconnected) { return $true }
    }
    return $false
}

function Test-Internet {
    foreach ($ep in $Cfg.ProbeEndpoints) {
        $parts = "$ep".Split(':')
        if ($parts.Count -ne 2) { continue }
        $sock = New-Object System.Net.Sockets.Socket('InterNetwork', 'Stream', 'Tcp')
        try {
            $ar = $sock.BeginConnect($parts[0], [int]$parts[1], $null, $null)
            if ($ar.AsyncWaitHandle.WaitOne($Cfg.ProbeTimeoutMs)) {
                try { $sock.EndConnect($ar); return $true } catch { }
            }
        } catch { } finally { try { $sock.Close() } catch { } }
    }
    return $false
}

# ---------------- does the machine already have internet elsewhere? ----------------
function Test-NcsiInternet {
    # Windows' own verdict, the same one behind the taskbar network icon.
    # Backed by NCSI, so it understands captive portals and cannot be fooled by a
    # transparent proxy that merely accepts TCP port 53.
    try {
        $clsid = [Guid]'DCB00C01-570F-4A9B-8D69-199FDBA5723B'   # Network List Manager
        $nlm = [Activator]::CreateInstance([Type]::GetTypeFromCLSID($clsid))
        return [bool]$nlm.IsConnectedToInternet
    } catch { return $false }
}

function Test-OtherInternet {
    # Policy gate for DialOnlyWhenNoInternet. BOTH signals must agree, so that either
    # a stuck NCSI or an intercepted DNS port on its own can never silently stop us
    # from dialing. Anything uncertain falls through to "dial".
    if (-not (Test-NcsiInternet)) { return $false }
    return (Test-Internet)
}

# ---------------- dial ----------------
# Three ways to bring the link up, tried in order. They are not equivalent, and which
# one works is exactly the question this ladder answers on the next real drop:
#
#   rasdial            rasdial <entry>                - no account name supplied
#   rasdial-account    rasdial <entry> <account>      - account supplied, stored password
#   rasphone           rasphone -d <entry>            - the same UI path as clicking
#                                                       Connect in Windows Settings
#
# Measured history: plain "rasdial <entry>" failed with RAS 628 on 17 out of 17 attempts
# across five days, in every condition we could rule out - after a fresh drop, after 20 s,
# after 60 s, after a 3-minute pause, with the port provably idle (zero [BUSY] events),
# and one time only 34 seconds before the user's manual click succeeded. So the row that
# matters is whichever of the other two actually establishes the session.
function Invoke-DialOnce {
    param(
        [string]$Form = 'rasdial',
        [string]$Account = ''
    )

    $exeName = 'rasdial.exe'
    $argLine = '"{0}"' -f $Cfg.ConnectionName
    switch ($Form) {
        'rasdial-account' {
            if (-not $Account) { return @{ ok = $false; code = -4; text = 'no account name available for this form' } }
            $exeName = 'rasdial.exe'
            $argLine = '"{0}" "{1}"' -f $Cfg.ConnectionName, $Account
        }
        'rasphone' {
            $exeName = 'rasphone.exe'
            $argLine = '-d "{0}"' -f $Cfg.ConnectionName
        }
        default { }
    }

    $exe = Join-Path (Join-Path $env:SystemRoot 'System32') $exeName
    if (-not (Test-Path $exe)) { return @{ ok = $false; code = -1; text = "$exeName not found" } }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $exe
    $psi.Arguments              = $argLine
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    # Best effort at keeping the rasphone dialog off the screen. A GUI program draws its
    # own window and may simply ignore this, but where it is honoured the window never
    # appears at all - which is the whole complaint this line exists to fix.
    $psi.WindowStyle            = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true

    $proc = $null
    $confirmed = $false
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()

        # rasphone -d opens the classic dial dialog and then WAITS for someone to press
        # Connect. That dialog is the only form that has ever produced a working
        # connection: 2026-10-19 09:59:26, right after the user clicked it. Connect is the
        # dialog's default button, so focusing that exact window and pressing Enter is
        # the same action.
        #
        # The keystroke is sent ONLY when AppActivate confirms our own window is in front.
        # If it is not, the Enter would land wherever focus happens to be - which could
        # type into whatever the user is doing at that moment. Better to leave the dialog
        # alone and let the timeout kill it.
        if ($Form -eq 'rasphone') {
            Start-Sleep -Seconds 3
            try {
                $wsh = New-Object -ComObject WScript.Shell
                if ($wsh.AppActivate($proc.Id)) {
                    Start-Sleep -Milliseconds 500
                    $wsh.SendKeys('{ENTER}')
                    $confirmed = $true
                }
            } catch { }
        }

        # 12 seconds, not 45. Measured 2026-10-19: when the port is READY rasphone dials
        # and exits in about 4 seconds (13:07:03 and 13:09:03, both with no click at all).
        # When the port is NOT ready it parks a dialog on screen and waits - and that
        # dialog can never succeed, it just burns the leash. Killing the process does not
        # abort a dial that is genuinely in progress (the kill at 09:59:14 and the
        # connection coming up at 09:59:26 were independent), so a short leash is safe.
        $timeoutMs = $Cfg.DialTimeoutMs
        if ($Form -eq 'rasphone') { $timeoutMs = 12000 }

        if (-not $proc.WaitForExit($timeoutMs)) {
            try { $proc.Kill() } catch { }
            return @{ ok = $false; code = -2; text = ("$exeName timed out after {0}s and was killed" -f ($timeoutMs / 1000)) }
        }
        $raw = ''
        try { $raw = ($outTask.Result + ' ' + $errTask.Result) } catch { }
        $raw = ($raw -replace '\s+', ' ').Trim()
        if ($raw.Length -gt 300) { $raw = $raw.Substring(0, 300) }

        $note = ''
        if ($confirmed) { $note = '[connect button auto-pressed] ' }
        $code = $proc.ExitCode
        if ($code -eq 0) { return @{ ok = $true; code = 0; text = ($note + $raw) } }
        return @{ ok = $false; code = $code; text = ($note + $raw) }
    } catch {
        return @{ ok = $false; code = -3; text = $_.Exception.Message }
    } finally {
        if ($proc) { try { $proc.Dispose() } catch { } }
    }
}

# ==================== modes that do not dial ====================
if ($Status) {
    $st = Get-State
    Write-Host ('locked              : {0}' -f $st.locked)
    Write-Host ('lockReason          : {0}' -f $st.lockReason)
    Write-Host ('failingForSeconds   : {0}  (locks at {1})' -f (Get-FailingSeconds $st), $Cfg.LockAfterFailingSeconds)
    Write-Host ('consecutiveFailures : {0}' -f $st.consecutiveFailures)
    Write-Host ('totalAttempts       : {0}' -f $st.totalAttempts)
    Write-Host ('lastAttemptUtc      : {0}' -f $st.lastAttemptUtc)
    Write-Host ('connectionName      : {0}' -f $Cfg.ConnectionName)
    Write-Host ('sessionCheck        : {0}' -f $(if ($NativeOk) { 'RasEnumConnections (native, cannot block on NDIS)' } else { 'adapter enumeration (fallback - can block)' }))
    Write-Host ('sessionUp           : {0}' -f (Test-SessionUp))
    Write-Host ('dialInProgress      : {0}' -f (Test-DialInProgress))
    Write-Host ('internetReachable   : {0}' -f (Test-Internet))
    Write-Host ('ncsiInternet        : {0}' -f (Test-NcsiInternet))
    Write-Host ('otherPathHasInternet: {0}  (policy: DialOnlyWhenNoInternet={1})' -f (Test-OtherInternet), $Cfg.DialOnlyWhenNoInternet)
    Write-Host ('stopFlagPresent     : {0}' -f (Test-Path $StopFlag))
    Write-Host ('thresholds          : firstDial={0}s run<={1}s retryWindow={2}s attempts<={3} gap={4}-{5}s stable={6}s lockAfterFailing={7}s' -f `
        $Cfg.FirstAttemptDelaySeconds, $Cfg.MaxRunSeconds, $Cfg.RetryWindowSeconds, $Cfg.MaxAttemptsPerRun, `
        $Cfg.MinSecondsBetweenAttempts, $Cfg.MaxSecondsBetweenAttempts, $Cfg.StableSeconds, $Cfg.LockAfterFailingSeconds)
    exit 0
}

if ($Reset) {
    Save-State (New-DefaultState)
    Write-Host 'state reset: locked=false, counters cleared'
    exit 0
}

# ==================== single-instance guard ====================
$mutex = New-Object System.Threading.Mutex($false, $MutexName)
$hasLock = $false
$exitCode = 0

try {
    $hasLock = $mutex.WaitOne(0)
    if (-not $hasLock) {
        Write-Log 'SKIP' 'another instance is already running; exiting'
        exit 3
    }

    if (-not $Cfg.ConnectionName) {
        Write-Log 'FATAL' 'no connection name configured; set ConnectionName in settings.json'
        exit 9
    }

    # A trail of breadcrumbs that is independent of the main loop. If the log stops but
    # this file keeps growing, the process is alive and stuck; if it stops too, the
    # process is gone. Without it both cases look identical from the outside.
    if ($NativeOk) {
        try { [RasHelper]::StartHeartbeat($HeartbeatPath, 30) } catch { }
        Write-Log 'INFO' ('native session check: available; heartbeat every 30s -> {0}' -f $HeartbeatPath)
    } else {
        Write-Log 'WARN' 'native session check unavailable; falling back to adapter enumeration (can block)'
    }

    $started     = Get-Date
    $runLimit    = [int]$Cfg.MaxRunSeconds
    $attempts    = 0
    $stableAt    = $null
    $tryingSince = $null
    $simLast     = $null   # DryRun-only simulated last-attempt timestamp
    $delayLogged = $false
    $otherLogged = $false
    $waitLoggedFor = 0
    $everUp = $false
    $busyLogged = $false
    $DialAccount = $null
    $preferredForm = $null

    Write-Log 'START' ('run begin (DryRun={0}) limits: firstDial={1}s run<={2}s retryWindow={3}s attempts<={4} gap={5}-{6}s afterFirstFail={9}s stable={7}s lockAfterFailing={8}s' -f `
        [bool]$DryRun, $Cfg.FirstAttemptDelaySeconds, $runLimit, $Cfg.RetryWindowSeconds, $Cfg.MaxAttemptsPerRun, `
        $Cfg.MinSecondsBetweenAttempts, $Cfg.MaxSecondsBetweenAttempts, $Cfg.StableSeconds, $Cfg.LockAfterFailingSeconds, `
        $Cfg.AfterFirstFailureWaitSeconds)

    if (Test-Path $StopFlag) {
        Write-Log 'STOP' 'stop.flag present at start; exiting without dialing'
        exit 0
    }

    while ($true) {
        # ---- hard lifetime bound ----
        if (((Get-Date) - $started).TotalSeconds -ge $runLimit) {
            Write-Log 'STOP' ('run limit {0}s reached; exiting' -f $runLimit)
            break
        }
        # ---- manual kill switch ----
        if (Test-Path $StopFlag) {
            Write-Log 'STOP' 'stop.flag detected; exiting'
            break
        }
        # ---- deliberate hold before the very first attempt ----
        $elapsed = ((Get-Date) - $started).TotalSeconds
        if ($elapsed -lt [int]$Cfg.FirstAttemptDelaySeconds) {
            if (-not $delayLogged) {
                Write-Log 'INFO' ('holding {0}s before the first connection attempt' -f $Cfg.FirstAttemptDelaySeconds)
                $delayLogged = $true
            }
            $nap = [int]([math]::Min([int]$Cfg.ProbeIntervalSeconds, [int]$Cfg.FirstAttemptDelaySeconds - $elapsed))
            if ($nap -lt 1) { $nap = 1 }
            Start-Sleep -Seconds $nap
            continue
        }

        if (Test-SessionUp) {
            $tryingSince = $null
            $everUp = $true
            if (-not $stableAt) {
                $stableAt = Get-Date
                Write-Log 'INFO' 'session is UP; watching for stability'

                # The link is healthy again, so "failing continuously" ends here.
                # Without this the failure clock ran straight through a healthy period:
                # on 2026-10-14 failingSinceUtc stayed frozen at 23:35:10 while the link
                # was in fact up from 23:39, so a single later failure could have tripped
                # the 30-minute self-lock even though the link had been fine throughout.
                $stUp = Get-State
                if ([int]$stUp.consecutiveFailures -ne 0 -or $stUp.failingSinceUtc) {
                    Write-Log 'INFO' ('link is back; clearing the failure clock (it had been failing for {0}s)' -f (Get-FailingSeconds $stUp))
                    $stUp.consecutiveFailures = 0
                    $stUp.failingSinceUtc     = ''
                    Save-State $stUp
                }
            }
            $upFor = [int]((Get-Date) - $stableAt).TotalSeconds
            if ($upFor -ge $Cfg.StableSeconds) {
                Write-Log 'OK' ('session stable for {0}s; run complete' -f $Cfg.StableSeconds)
                break
            }
            Start-Sleep -Seconds $Cfg.ProbeIntervalSeconds
            continue
        }

        if ($stableAt) {
            Write-Log 'WARN' 'session went DOWN again'
            $stableAt = $null
        }

        # ---- never dial into a dial that is already in progress ----
        if (Test-DialInProgress) {
            $tryingSince = $null
            if (-not $busyLogged) {
                Write-Log 'BUSY' ('"{0}" is already being dialed (by us, by Windows, or by you); waiting instead of colliding' -f $Cfg.ConnectionName)
                $busyLogged = $true
            }
            Start-Sleep -Seconds $Cfg.ProbeIntervalSeconds
            continue
        }
        if ($busyLogged) {
            Write-Log 'INFO' 'the other dial attempt is over; resuming normal handling'
            $busyLogged = $false
        }

        $st = Get-State

        # ---- lock ----
        if ($st.locked) {
            Write-Log 'LOCK' ('locked ({0}); refusing to dial. reset with -Reset' -f $st.lockReason)
            $exitCode = 4
            break
        }

        # ---- policy: leave another working internet path alone ----
        if ([int]$Cfg.DialOnlyWhenNoInternet -eq 1) {
            if (Test-OtherInternet) {
                $tryingSince = $null
                if (-not $otherLogged) {
                    Write-Log 'HOLD' 'session is DOWN but this machine already reaches the internet by another path; not dialing'
                    $otherLogged = $true
                }
                Start-Sleep -Seconds ([int]$Cfg.OtherPathRecheckSeconds)
                continue
            }
            if ($otherLogged) {
                Write-Log 'INFO' 'the other internet path is gone; resuming normal dialing'
                $otherLogged = $false
            }
        }

        # ---- retry window (TIME based, per run) ----
        if (-not $tryingSince) {
            $tryingSince = Get-Date
            Write-Log 'INFO' 'session is DOWN; entering retry window'
        }
        $triedFor = [int]((Get-Date) - $tryingSince).TotalSeconds
        if ($triedFor -ge [int]$Cfg.RetryWindowSeconds) {
            Write-Log 'STOP' ('retry window {0}s exhausted without a session; exiting WITHOUT locking' -f $Cfg.RetryWindowSeconds)
            $exitCode = 8
            break
        }

        # ---- attempt cap (per run) ----
        if ($attempts -ge [int]$Cfg.MaxAttemptsPerRun) {
            Write-Log 'STOP' ('attempt cap {0} reached; exiting without further dialing' -f $Cfg.MaxAttemptsPerRun)
            $exitCode = 5
            break
        }

        # ---- pacing: global floor + in-run backoff ----
        $lastUtc = $st.lastAttemptUtc
        if ($DryRun -and $simLast) { $lastUtc = $simLast }
        $sinceLast = 999999.0
        if ($lastUtc) {
            try { $sinceLast = ((Get-Date).ToUniversalTime() - [datetime]::Parse($lastUtc).ToUniversalTime()).TotalSeconds } catch { }
        }
        if ($attempts -le 1 -and -not $everUp) {
            # One long hands-off pause - but ONLY for the very first failure of a run, and
            # only while the session has not been up even once yet.
            # Why the second condition: 2026-10-16 produced a flapping start (established
            # 07:47:49, dead 07:48:16, established 07:49:03, dead 07:49:42, established
            # 07:49:43, dead 07:49:44) that only settled after the run kept re-dialing
            # promptly. Delaying those repeats by three minutes would have turned a
            # 4-minute recovery into a 12-minute one. The long pause is a boot-time
            # probe, not a policy for a link that is already coming up.
            $wantGap = [int]$Cfg.AfterFirstFailureWaitSeconds
        } else {
            $wantGap = [int]$Cfg.MinSecondsBetweenAttempts * [math]::Max(1, $attempts)
            if ($wantGap -gt [int]$Cfg.MaxSecondsBetweenAttempts) { $wantGap = [int]$Cfg.MaxSecondsBetweenAttempts }
        }
        if ($wantGap -lt [int]$Cfg.MinSecondsBetweenAttempts) { $wantGap = [int]$Cfg.MinSecondsBetweenAttempts }
        $wait = [int]($wantGap - $sinceLast)
        if ($wait -gt 0) {
            # Log the wait ONCE per gap, not once per sleep slice. The old form wrote
            # 12 near-identical lines for a 60 s gap and buried everything that mattered
            # (40 of the 90 lines on 2026-10-14 were this one message).
            if ($waitLoggedFor -ne $wantGap) {
                Write-Log 'WAIT' ('backoff: {0}s of the {1}s gap still to go' -f $wait, $wantGap)
                $waitLoggedFor = $wantGap
            }
            $nap = [math]::Min($wait, [int]$Cfg.ProbeIntervalSeconds)
            Start-Sleep -Seconds $nap
            continue
        }
        $waitLoggedFor = 0

        # ---- time to dial ----
        if ($DryRun) {
            $attempts++
            $simLast = (Get-Date).ToUniversalTime().ToString('o')
            Write-Log 'DRYRUN' ('session DOWN and every gate passed -> WOULD dial (attempt {0}/{1}); nothing was done' -f $attempts, $Cfg.MaxAttemptsPerRun)
            Start-Sleep -Seconds 1
            continue
        }

        $attempts++
        $st.lastAttemptUtc = (Get-Date).ToUniversalTime().ToString('o')
        $st.totalAttempts  = [int]$st.totalAttempts + 1
        Save-State $st

        if ($null -eq $DialAccount) {
            $DialAccount = Resolve-DialAccount $Cfg.DialWithAccountName
            if ($DialAccount) {
                Write-Log 'INFO' ('account name resolved for the rasdial-account form: {0} characters (the value itself is not logged)' -f $DialAccount.Length)
            } else {
                Write-Log 'INFO' 'no account name available (the RasMan event log could not be read), so the rasdial-account form is skipped'
            }
        }

        # ---- which form to dial with ----
        # SILENCE FIRST. "rasdial <entry> <account>" puts no window on screen at all, so if
        # it works the user never sees anything. It has never been observed working on this
        # line - but it has also never been tried WITH the account supplied, because that
        # test never ran. So it gets attempt 1, and the proven rasphone dialog is the
        # immediate fallback for everything after that.
        # Whatever wins is pinned for the rest of the run, so a silent success keeps the
        # whole run silent instead of falling back to the window on the next drop.
        if ($preferredForm) {
            $form = $preferredForm
        } elseif ($attempts -le 1 -and $DialAccount) {
            $form = 'rasdial-account'
        } else {
            $form = 'rasphone'
        }

        Write-Log 'DIAL' ('dialing "{0}" via {1} (attempt {2}/{3} this run, {4}s into the retry window)' -f $Cfg.ConnectionName, $form, $attempts, $Cfg.MaxAttemptsPerRun, $triedFor)
        $r = Invoke-DialOnce -Form $form -Account $DialAccount

        if ($r.ok) {
            $took = [int]((Get-Date) - $started).TotalSeconds
            Write-Log 'OK' ('{0} reported success after {1}s from process start' -f $form, $took)
            $preferredForm = $form
            $st.consecutiveFailures = 0
            $st.failingSinceUtc     = ''
            Save-State $st
            $tryingSince = $null
            $stableAt = Get-Date
            continue
        }

        $st.consecutiveFailures = [int]$st.consecutiveFailures + 1
        if (-not $st.failingSinceUtc) { $st.failingSinceUtc = (Get-Date).ToUniversalTime().ToString('o') }
        $failingFor = Get-FailingSeconds $st
        Write-Log 'FAIL' ('{0} failed: code={1} out="{2}" (this run #{3}, failing continuously for {4}s)' -f $form, $r.code, $r.text, $attempts, $failingFor)

        # ---- fatal RAS codes lock immediately ----
        if (@($Cfg.LockOnErrorCodes) -contains [int]$r.code) {
            $st.locked = $true
            $st.lockReason = ('fatal RAS code {0} at {1}' -f $r.code, (Get-Date).ToString('s'))
            Save-State $st
            Write-Log 'LOCK' ('FATAL code {0} -> LOCKED. No further dialing until -Reset.' -f $r.code)
            $exitCode = 6
            break
        }

        # ---- TIME based lock ----
        if ($failingFor -ge [int]$Cfg.LockAfterFailingSeconds) {
            $st.locked = $true
            $st.lockReason = ('failing continuously for {0}s (limit {1}s) at {2}' -f $failingFor, $Cfg.LockAfterFailingSeconds, (Get-Date).ToString('s'))
            Save-State $st
            Write-Log 'LOCK' ('failing for {0}s >= limit {1}s -> LOCKED. No further dialing until -Reset.' -f $failingFor, $Cfg.LockAfterFailingSeconds)
            $exitCode = 7
            break
        }

        Save-State $st
    }

    if ($script:LogWriteFailures -gt 0) {
        Write-Log 'WARN' ('{0} write(s) to the main log failed and went to {1} instead' -f $script:LogWriteFailures, $FallbackLog)
    }
    Write-Log 'END' ('run finished, exit code {0}' -f $exitCode)
    exit $exitCode
} catch {
    # An unhandled exception used to end a run with NO trace at all: the task window is
    # hidden, stderr is discarded, and the log just stopped mid-way -- the only evidence
    # was a missing [END], which is indistinguishable from a killed process. This was
    # observed four times on 2026-10-14. Record it before the process dies.
    $exitCode = 70
    try {
        Write-Log 'FATAL' ('unhandled exception {0}: {1} (at script line {2})' -f `
            $_.Exception.GetType().Name, $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber)
        if ($_.ScriptStackTrace) {
            Write-Log 'FATAL' ('stack: ' + ($_.ScriptStackTrace -replace "`r?`n", ' <- '))
        }
        Write-Log 'END' ('run aborted by an unhandled exception, exit code {0}' -f $exitCode)
    } catch { }
    exit $exitCode
} finally {
    if ($hasLock) { try { $mutex.ReleaseMutex() } catch { } }
    try { $mutex.Dispose() } catch { }
}
