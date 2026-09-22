<#
.SYNOPSIS
    Tray icon for Multi Claude Desktop.

.DESCRIPTION
    A thin front end over mcd.ps1: launch a profile, and tick which profiles
    share their Claude Code session list. The script dot-sources mcd.ps1, so
    there is exactly one implementation of the sharing logic.

    Launching goes through the hidden runner as a separate process, because
    mcd.ps1 polls for up to 45 seconds while it stamps the taskbar identity and
    that would freeze the menu. Share toggles are cheap and run in-process.

    All messages are ASCII on purpose, same as mcd.ps1.

.EXAMPLE
    .\mcd.ps1 tray
    powershell -NoProfile -ExecutionPolicy Bypass -File .\mcd-tray.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$TrayRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $TrayRoot 'mcd.ps1')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ------------------------------------------------------------------ icon ---

function Get-TrayIcon {
    # This tool's own mark, not Claude's - the tray icon stands for Multi
    # Claude Desktop itself and has to be distinguishable from the app.
    try {
        $mine = Initialize-TrayIcon
        if ($mine -and (Test-Path -LiteralPath $mine)) {
            return New-Object System.Drawing.Icon $mine
        }
    } catch { }

    $ico = Join-Path $IconDir 'claude.ico'
    if (-not (Test-Path -LiteralPath $ico)) {
        try { Initialize-Icon -ExePath (Resolve-ClaudeExe) | Out-Null } catch { }
    }
    if (Test-Path -LiteralPath $ico) {
        try { return New-Object System.Drawing.Icon $ico } catch { }
    }
    try {
        return [System.Drawing.Icon]::ExtractAssociatedIcon((Resolve-ClaudeExe))
    } catch {
        return [System.Drawing.SystemIcons]::Application
    }
}

# --------------------------------------------------------------- actions ---

$script:Notify = $null

function Show-Tip {
    param([string]$Title, [string]$Text, [switch]$Warning)
    if (-not $script:Notify) { return }
    $script:Notify.BalloonTipTitle = $Title
    $script:Notify.BalloonTipText  = $Text
    $script:Notify.BalloonTipIcon  = if ($Warning) {
        [System.Windows.Forms.ToolTipIcon]::Warning
    } else {
        [System.Windows.Forms.ToolTipIcon]::Info
    }
    $script:Notify.ShowBalloonTip(4000)
}

function Start-ProfileDetached {
    # Same code path as '.\mcd.ps1 launch <name>', just off the UI thread.
    param([string]$ProfileName)
    Initialize-HiddenRunner
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') `
                  -ArgumentList "`"$HiddenRunner`"", "`"$(Join-Path $TrayRoot 'mcd.ps1')`"",
                                'launch', $ProfileName
}

function Switch-ProfileSharing {
    # Toggle one profile's opt-in. Copying entries in is safe at any time, so
    # unlike the old junction scheme this does not care whether the app is up.
    param([string]$ProfileName)

    $cfg = Read-Config
    $p = Find-Profile -Config $cfg -ProfileName $ProfileName
    if (-not $p) { return }

    $ids = Resolve-SessionIdentity -Prof $p -Quiet
    if ($ids -and (Test-JunctionPath -Path $ids.path)) {
        Show-Tip -Warning -Title 'Old junction in the way' `
                 -Text "Close Claude Desktop and run 'mcd.ps1 unshare $($p.name)' once."
        return
    }

    if (Test-ShareEnabled -Prof $p) {
        Set-ProfileProp -Prof $p -PropName 'shareSessions' -Value $false
        Write-Config $cfg
        Show-Tip -Title 'Sessions no longer synced' `
                 -Text "$($p.label) keeps the entries it already has."
    } else {
        Set-ProfileProp -Prof $p -PropName 'shareSessions' -Value $true
        Write-Config $cfg
        $n = 0
        try { $n = New-SessionIndexSync -Config $cfg -Quiet } catch { }
        Show-Tip -Title 'Sessions synced' `
                 -Text "$($p.label) shares its session list. Copied $n entr$(if ($n -eq 1) { 'y' } else { 'ies' })."
    }
}

# ----------------------------------------------------------------- watch ---

# Stamping is per window, so it does not survive the app creating a new one -
# and Claude Desktop does that on its own (reload, new window, sign-in). A
# one-shot 'stamp' therefore looks like it "did not apply" a minute later.
# The tray is already resident, so it re-stamps whatever it finds unstamped.

$script:PidToProfile = @{}      # claude.exe pid -> profile
$script:LastPidSet   = ''
$script:LastCfgStamp = ''
$script:WindowState  = @{}      # hwnd -> "<aumid>|<icon>" already applied
$script:Cfg          = $null    # last profiles.json read, reused by the sync

function Get-ConfigStamp {
    if (-not (Test-Path -LiteralPath $ProfilesPath)) { return '' }
    return [string](Get-Item -LiteralPath $ProfilesPath).LastWriteTimeUtc.Ticks
}

function Update-PidToProfile {
    $cfg = Read-Config
    $script:Cfg = $cfg
    $running = Get-RunningProfiles
    $map = @{}
    foreach ($p in $cfg.profiles) {
        # Keep the AUMID registration in step - the taskbar button's icon and
        # name come from it, not from the window. Cheap: it rewrites the .lnk
        # only when something actually changed.
        try { Register-ProfileAumid -Prof $p | Out-Null } catch { }
        $key = ([string]$p.dataDir).TrimEnd('\').ToLowerInvariant()
        if (-not $running.ContainsKey($key)) { continue }
        foreach ($id in $running[$key]) { $map[[int]$id] = $p }
    }
    $script:PidToProfile = $map
}

function Invoke-WindowWatch {
    # Cheap path first: Get-Process is fast, Win32_Process is not. Only rebuild
    # the pid -> profile map when the set of processes or profiles.json moved.
    $ids = @(Get-Process -Name claude -ErrorAction SilentlyContinue |
             Select-Object -ExpandProperty Id | Sort-Object)
    $pidSet = $ids -join ','
    $cfgStamp = Get-ConfigStamp
    if ($pidSet -ne $script:LastPidSet -or $cfgStamp -ne $script:LastCfgStamp) {
        # An edited profiles.json may mean a new icon for windows we already
        # did, so forget what we applied and let the pass below redo them.
        if ($cfgStamp -ne $script:LastCfgStamp) { $script:WindowState = @{} }
        $script:LastPidSet = $pidSet
        $script:LastCfgStamp = $cfgStamp
        Update-PidToProfile
    }

    # Keep the shared session lists in step. A pass with nothing to do costs
    # one directory listing per participating profile - no file is opened.
    if ($script:Cfg) {
        try { New-SessionIndexSync -Config $script:Cfg -Quiet | Out-Null } catch { }
    }

    if ($script:PidToProfile.Count -eq 0) { return }

    Initialize-Native
    $live = @{}
    foreach ($entry in @($script:PidToProfile.GetEnumerator())) {
        $procId = $entry.Key
        $prof = $entry.Value
        if (-not (Get-Process -Id $procId -ErrorAction SilentlyContinue)) { continue }

        $icon = Get-ProfileIconPath -Prof $prof -CustomOnly -Quiet
        $aumid = if ($prof.stock) { '' } else { Get-ProfileAumid -Prof $prof }
        # The overlay slot is only reachable from a live process, which is
        # exactly why this belongs in the tray and not in a one-shot command.
        $overlay = ''
        if ((Get-ProfileIconStyle -Prof $prof) -eq 'overlay') {
            $o = Get-ProfileOverlayIcon -Prof $prof -Quiet
            if ($o) { $overlay = $o }
        }
        if (-not $icon -and -not $aumid -and -not $overlay) { continue }
        $want = "$aumid|$icon|$overlay"

        foreach ($h in @([McdWin]::AppWindows([uint32]$procId))) {
            $key = [string][int64]$h
            $live[$key] = $true
            if ($script:WindowState[$key] -eq $want) { continue }

            if ($aumid) {
                # Only a profile's own icon, never the generic fallback - see
                # Set-ProfileWindowIdentity.
                $iconRes = $null
                if ($icon) { $iconRes = "$icon,0" }
                [McdWin]::StampWindow($h, $aumid, (Get-RelaunchCommand -Prof $prof),
                                      $prof.label, $iconRes) | Out-Null
            }
            if ($icon) { [McdWin]::SetWindowIcon($h, $icon) | Out-Null }
            # Passing '' clears an overlay left over from a style change.
            [McdWin]::SetTaskbarOverlay($h, $overlay, [string]$prof.label) | Out-Null
            $script:WindowState[$key] = $want
        }
    }

    # Forget windows that are gone, so the table cannot grow without bound.
    foreach ($k in @($script:WindowState.Keys)) {
        if (-not $live.ContainsKey($k)) { $script:WindowState.Remove($k) }
    }
}

# ------------------------------------------------------------------ menu ---

function New-MenuItem {
    param([string]$Text, [scriptblock]$OnClick, [bool]$Checked = $false, [bool]$Enabled = $true,
          [string]$IconPath)
    $item = New-Object System.Windows.Forms.ToolStripMenuItem
    $item.Text = $Text
    $item.Checked = $Checked
    $item.Enabled = $Enabled
    if ($IconPath -and (Test-Path -LiteralPath $IconPath)) {
        # 16x16 is the menu strip's image size; anything else gets squashed.
        try {
            $ico = New-Object System.Drawing.Icon($IconPath, 16, 16)
            $item.Image = $ico.ToBitmap()
            $ico.Dispose()
        } catch { }
    }
    if ($OnClick) { $item.add_Click($OnClick) }
    return $item
}

function Build-Menu {
    param($Menu)
    $Menu.Items.Clear()

    $cfg = Read-Config
    $running = Get-RunningProfiles

    foreach ($p in $cfg.profiles) {
        $pname = [string]$p.name
        $isUp = Test-ProfileRunning -Prof $p -Running $running
        $share = Get-ShareState -Config $cfg -Prof $p
        $suffix = @()
        if ($isUp) { $suffix += 'running' }
        if ($share -ne '-') { $suffix += $share }
        $text = [string]$p.label
        if ($suffix.Count) { $text += '   (' + ($suffix -join ', ') + ')' }

        $Menu.Items.Add((New-MenuItem -Text $text -IconPath (Get-ProfileMenuIcon -Prof $p -Quiet) -OnClick {
            Start-ProfileDetached -ProfileName $this.Tag
        })) | Out-Null
        $Menu.Items[$Menu.Items.Count - 1].Tag = $pname
    }

    $Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $shareRoot = New-Object System.Windows.Forms.ToolStripMenuItem
    $shareRoot.Text = 'Share Claude Code sessions'
    foreach ($p in $cfg.profiles) {
        $pname = [string]$p.name
        $state = Get-ShareState -Config $cfg -Prof $p
        $label = [string]$p.label
        if ($state -eq 'pending')    { $label += '   (waiting for first sign-in)' }
        if ($state -eq 'stray link') { $label += '   (linked outside mcd)' }
        $sub = New-MenuItem -Text $label -Checked (Test-ShareEnabled -Prof $p) -OnClick {
            Switch-ProfileSharing -ProfileName $this.Tag
        }
        $sub.Tag = $pname
        $shareRoot.DropDownItems.Add($sub) | Out-Null
    }
    $shareRoot.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
    $shareRoot.DropDownItems.Add((New-MenuItem -Text 'Sync session lists now' -OnClick {
        $n = 0
        try { $n = New-SessionIndexSync -Config (Read-Config) -Quiet } catch { }
        Show-Tip -Title 'Session lists' -Text "Copied $n entr$(if ($n -eq 1) { 'y' } else { 'ies' })."
    })) | Out-Null
    $Menu.Items.Add($shareRoot) | Out-Null

    $openRoot = New-Object System.Windows.Forms.ToolStripMenuItem
    $openRoot.Text = 'Open data folder'
    foreach ($p in $cfg.profiles) {
        $sub = New-MenuItem -Text ([string]$p.label) -Enabled (Test-Path -LiteralPath $p.dataDir) -OnClick {
            Start-Process explorer.exe $this.Tag
        }
        $sub.Tag = [string]$p.dataDir
        $openRoot.DropDownItems.Add($sub) | Out-Null
    }
    $Menu.Items.Add($openRoot) | Out-Null

    $Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
    $Menu.Items.Add((New-MenuItem -Text 'Re-apply icons and taskbar names' -OnClick {
        $script:WindowState = @{}
        $script:LastCfgStamp = ''
        Invoke-WindowWatch
        Show-Tip -Title 'Multi Claude Desktop' -Text 'Re-applied to every open window.'
    })) | Out-Null
    $Menu.Items.Add((New-MenuItem -Text 'Start with Windows' -Checked (Test-Autostart) -OnClick {
        $script:Name = if (Test-Autostart) { 'off' } else { 'on' }
        Invoke-Autostart
        Show-Tip -Title 'Multi Claude Desktop' -Text $(if (Test-Autostart) {
            'The tray icon will start at sign-in.'
        } else {
            'The tray icon no longer starts at sign-in.'
        })
    })) | Out-Null
    $Menu.Items.Add((New-MenuItem -Text 'Edit profiles.json' -OnClick {
        Start-Process notepad.exe $ProfilesPath
    })) | Out-Null
    $Menu.Items.Add((New-MenuItem -Text 'Exit' -OnClick {
        $script:Notify.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    })) | Out-Null
}

# ------------------------------------------------------------------- run ---

# One tray icon per user. A second copy would show a duplicate icon and race
# the first on profiles.json.
$mutex = New-Object System.Threading.Mutex($false, 'Local\MultiClaudeDesktopTray')
try {
    $owned = $mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    # The previous tray was killed rather than closed. The wait still succeeded
    # and we now own the mutex; without this the next start would just die.
    $owned = $true
}
if (-not $owned) { return }

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.add_Opening({ Build-Menu -Menu $menu })

$script:Notify = New-Object System.Windows.Forms.NotifyIcon
$script:Notify.Icon = Get-TrayIcon
$script:Notify.Text = 'Multi Claude Desktop'
$script:Notify.ContextMenuStrip = $menu
$script:Notify.Visible = $true

# Re-stamp windows the app opened after the fact. Runs on the UI thread, so it
# cannot race the menu; each pass is an EnumWindows plus a property read per
# window, and does nothing at all once everything carries the right values.
$watch = New-Object System.Windows.Forms.Timer
$watch.Interval = 3000
$watch.add_Tick({
    try { Invoke-WindowWatch } catch { }
})
$watch.Start()
try { Invoke-WindowWatch } catch { }

try {
    [System.Windows.Forms.Application]::Run()
} finally {
    $watch.Stop()
    $watch.Dispose()
    $script:Notify.Visible = $false
    $script:Notify.Dispose()
    $mutex.ReleaseMutex()
}
