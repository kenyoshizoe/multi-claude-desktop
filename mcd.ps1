<#
.SYNOPSIS
    Multi Claude Desktop - run several Claude Desktop accounts side by side.

.DESCRIPTION
    Claude Desktop is an Electron app, so its whole login state (cookies,
    local storage, session) lives in one --user-data-dir. Giving each account
    its own directory lets them coexist without logging out and back in.

    All messages are ASCII on purpose: Windows PowerShell 5.1 reads .ps1 as
    ANSI unless the file has a BOM, and ASCII survives either way.

.EXAMPLE
    .\mcd.ps1 list
    .\mcd.ps1 add work -Label "Claude (Work)"
    .\mcd.ps1 launch work
    .\mcd.ps1 tray
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('list', 'add', 'remove', 'launch', 'stamp', 'sync-config',
                 'share', 'unshare', 'sync-sessions', 'tray', 'autostart', 'icon',
                 'open', 'where', 'help')]
    [string]$Command = 'help',

    [Parameter(Position = 1)]
    [string]$Name,

    [Parameter(Position = 2)]
    [string]$Name2,

    [string]$Label,
    [string]$DataDir,
    [string]$AccountId,
    [string]$OrgId,
    [switch]$All,
    [switch]$Clear,
    [switch]$Full,
    [switch]$DeleteData,
    [switch]$NoStamp,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$Root         = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProfilesPath = Join-Path $Root 'profiles.json'
$IconDir      = Join-Path $Root 'icons'
$HiddenRunner = Join-Path $Root 'run-hidden.vbs'
$TrayScript   = Join-Path $Root 'mcd-tray.ps1'
$script:IconDefaults = @{}

# ---------------------------------------------------------------- helpers ---

function Write-Info  { param([string]$m) Write-Host $m }
function Write-Ok    { param([string]$m) Write-Host $m -ForegroundColor Green }
function Write-Warn2 { param([string]$m) Write-Host $m -ForegroundColor Yellow }
function Write-Err   { param([string]$m) Write-Host $m -ForegroundColor Red }

function Initialize-Native {
    # Taskbar grouping is keyed on the AppUserModelID (AUMID). Claude Desktop
    # ships as an MSIX package, so every instance inherits the package AUMID
    # 'Claude_pzs8sxrjxfjjc!Claude' and Windows merges them into one button.
    # Stamping a distinct AUMID onto each profile's window splits them apart.
    if ('McdWin' -as [type]) { return }
    Add-Type -Language CSharp @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class McdWin {
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr LoadImageW(IntPtr inst, string name, uint type, int cx, int cy, uint load);
    [DllImport("user32.dll")] static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int PrivateExtractIconsW(string file, int index, int cx, int cy,
        IntPtr[] icons, int[] ids, int count, uint flags);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);

    [DllImport("shell32.dll")]
    static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid,
        [MarshalAs(UnmanagedType.Interface)] out IPropertyStore pv);

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct PropertyKey { public Guid fmtid; public uint pid; }

    [StructLayout(LayoutKind.Sequential)]
    public struct PropVariant { public ushort vt; public ushort r1, r2, r3; public IntPtr p; public IntPtr p2; }

    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore {
        int GetCount(out uint c);
        int GetAt(uint i, out PropertyKey k);
        int GetValue(ref PropertyKey k, out PropVariant v);
        int SetValue(ref PropertyKey k, ref PropVariant v);
        int Commit();
    }

    [ComImport, Guid("0000010b-0000-0000-C000-000000000046"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPersistFile {
        void GetClassID(out Guid id);
        [PreserveSig] int IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string file, uint mode);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string file, [MarshalAs(UnmanagedType.Bool)] bool remember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string file);
        void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string file);
    }

    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    class ShellLink { }

    // The taskbar's overlay slot - the same corner badge used for unread
    // counts, and what Chrome puts its profile avatar in. Unlike a window
    // icon it leaves the app's real icon alone and just stamps a corner.
    [ComImport, Guid("56FDF344-FD6D-11d0-958A-006097C9A090")]
    class TaskbarInstance { }

    [ComImport, Guid("ea1afb91-9e28-4b86-90e9-9e9f8a5eefaf"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ITaskbarList3 {
        [PreserveSig] int HrInit();
        [PreserveSig] int AddTab(IntPtr h);
        [PreserveSig] int DeleteTab(IntPtr h);
        [PreserveSig] int ActivateTab(IntPtr h);
        [PreserveSig] int SetActiveAlt(IntPtr h);
        [PreserveSig] int MarkFullscreenWindow(IntPtr h, [MarshalAs(UnmanagedType.Bool)] bool full);
        [PreserveSig] int SetProgressValue(IntPtr h, ulong done, ulong total);
        [PreserveSig] int SetProgressState(IntPtr h, int flags);
        [PreserveSig] int RegisterTab(IntPtr h, IntPtr mdi);
        [PreserveSig] int UnregisterTab(IntPtr h);
        [PreserveSig] int SetTabOrder(IntPtr h, IntPtr before);
        [PreserveSig] int SetTabActive(IntPtr h, IntPtr mdi, uint flags);
        [PreserveSig] int ThumbBarAddButtons(IntPtr h, uint n, IntPtr p);
        [PreserveSig] int ThumbBarUpdateButtons(IntPtr h, uint n, IntPtr p);
        [PreserveSig] int ThumbBarSetImageList(IntPtr h, IntPtr himl);
        [PreserveSig] int SetOverlayIcon(IntPtr h, IntPtr icon, [MarshalAs(UnmanagedType.LPWStr)] string desc);
        [PreserveSig] int SetThumbnailTooltip(IntPtr h, [MarshalAs(UnmanagedType.LPWStr)] string tip);
        [PreserveSig] int SetThumbnailClip(IntPtr h, IntPtr rc);
    }

    static ITaskbarList3 _taskbar;
    static IntPtr _lastOverlay = IntPtr.Zero;

    // Pass an empty path to clear the overlay again.
    public static int SetTaskbarOverlay(IntPtr hwnd, string icoPath, string desc) {
        if (_taskbar == null) {
            _taskbar = (ITaskbarList3)(new TaskbarInstance());
            int init = _taskbar.HrInit();
            if (init != 0) { _taskbar = null; return init; }
        }
        IntPtr icon = IntPtr.Zero;
        if (!string.IsNullOrEmpty(icoPath)) {
            icon = LoadImageW(IntPtr.Zero, icoPath, 1 /*IMAGE_ICON*/, 16, 16, 0x0010 /*LR_LOADFROMFILE*/);
            if (icon == IntPtr.Zero) return -1;
        }
        int hr = _taskbar.SetOverlayIcon(hwnd, icon, desc);
        // The shell copies the bitmap, so the previous handle can go once the
        // new one has landed.
        if (_lastOverlay != IntPtr.Zero) { DestroyIcon(_lastOverlay); }
        _lastOverlay = icon;
        return hr;
    }

    static readonly Guid FMTID = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
    static PropertyKey Key(uint pid) { return new PropertyKey { fmtid = FMTID, pid = pid }; }
    // System.AppUserModel.* property ids.
    const uint PID_RELAUNCH_COMMAND = 2;
    const uint PID_RELAUNCH_ICON    = 3;
    const uint PID_RELAUNCH_NAME    = 4;
    const uint PID_ID               = 5;

    public static List<IntPtr> AppWindows(uint pid) {
        var list = new List<IntPtr>();
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p != pid) return true;
            var c = new StringBuilder(64); GetClassNameW(h, c, 64);
            // Electron's real app window; every other window of the process is
            // a hidden helper (IME, power-message, notify-icon host, ...).
            if (c.ToString() == "Chrome_WidgetWin_1") list.Add(h);
            return true;
        }, IntPtr.Zero);
        return list;
    }

    // Writing VT_EMPTY removes an override we (or an earlier run) had set.
    // Without this a property can only ever be changed, never taken back.
    static void ClearProp(IPropertyStore s, uint pid) {
        var k = Key(pid);
        var pv = new PropVariant();   // vt = 0 = VT_EMPTY
        s.SetValue(ref k, ref pv);
    }

    static void SetStr(IPropertyStore s, uint pid, string v) {
        var k = Key(pid);
        var pv = new PropVariant();
        pv.vt = 31; // VT_LPWSTR
        pv.p = Marshal.StringToCoTaskMemUni(v);
        try { s.SetValue(ref k, ref pv); }
        finally { Marshal.FreeCoTaskMem(pv.p); }
    }

    public static string GetWindowAppId(IntPtr hwnd) {
        var iid = typeof(IPropertyStore).GUID;
        IPropertyStore s;
        if (SHGetPropertyStoreForWindow(hwnd, ref iid, out s) != 0) return null;
        try {
            var k = Key(PID_ID);
            PropVariant pv;
            if (s.GetValue(ref k, out pv) != 0) return null;
            if (pv.vt == 31 && pv.p != IntPtr.Zero) return Marshal.PtrToStringUni(pv.p);
            return null;
        } finally { Marshal.ReleaseComObject(s); }
    }

    // Returns true if the window now reports the requested AUMID.
    public static bool StampWindow(IntPtr hwnd, string appId, string relaunchCmd, string displayName, string iconRes) {
        var iid = typeof(IPropertyStore).GUID;
        IPropertyStore s;
        if (SHGetPropertyStoreForWindow(hwnd, ref iid, out s) != 0) return false;
        try {
            SetStr(s, PID_ID, appId);
            if (!string.IsNullOrEmpty(relaunchCmd)) SetStr(s, PID_RELAUNCH_COMMAND, relaunchCmd);
            if (!string.IsNullOrEmpty(displayName)) SetStr(s, PID_RELAUNCH_NAME, displayName);
            if (!string.IsNullOrEmpty(iconRes))     SetStr(s, PID_RELAUNCH_ICON, iconRes);
            else                                    ClearProp(s, PID_RELAUNCH_ICON);
            // Commit() returns 0x8007007B on window stores and is not needed
            // there - the values take effect on SetValue. Ignore the failure.
            try { s.Commit(); } catch { }
        } finally { Marshal.ReleaseComObject(s); }
        return GetWindowAppId(hwnd) == appId;
    }

    // A window carrying a custom AUMID is only half the story: the taskbar
    // BUTTON resolves that AUMID to a Start Menu shortcut stamped with the
    // same id, and takes its icon and name from there. Without the shortcut
    // Windows falls back to the packaged app's own icon, which is why a
    // per-profile icon shows up in the hover thumbnail (that one does come
    // from WM_SETICON) but not on the button itself.
    public static void StampShortcut(string lnkPath, string appId) {
        var link = new ShellLink();
        try {
            var pf = (IPersistFile)link;
            pf.Load(lnkPath, 2 /* STGM_READWRITE */);
            var ps = (IPropertyStore)link;
            SetStr(ps, PID_ID, appId);
            ps.Commit();   // shortcuts DO require an explicit commit
            pf.Save(null, true);
        } finally { Marshal.ReleaseComObject(link); }
    }

    // The app's real icon, the one Windows itself draws for the packaged
    // app. The MSIX tile art is a different, older rendition of the logo, so
    // going through the exe is what matches an untouched instance.
    public static IntPtr ExtractIcon(string exePath, int size) {
        var h = new IntPtr[1];
        var id = new int[1];
        return PrivateExtractIconsW(exePath, 0, size, size, h, id, 1, 0) > 0 ? h[0] : IntPtr.Zero;
    }

    // Replace the icon Electron gave the window. This is what the taskbar
    // button and the Alt-Tab list of a RUNNING instance show, so it is the
    // only way to tell two live profiles apart at a glance. The AUMID's
    // RelaunchIconResource only covers the pinned shortcut.
    public static bool SetWindowIcon(IntPtr hwnd, string icoPath) {
        const uint IMAGE_ICON = 1, LR_LOADFROMFILE = 0x0010, WM_SETICON = 0x0080;
        IntPtr big   = LoadImageW(IntPtr.Zero, icoPath, IMAGE_ICON, 32, 32, LR_LOADFROMFILE);
        IntPtr small = LoadImageW(IntPtr.Zero, icoPath, IMAGE_ICON, 16, 16, LR_LOADFROMFILE);
        if (big == IntPtr.Zero && small == IntPtr.Zero) return false;
        if (big   != IntPtr.Zero) SendMessageW(hwnd, WM_SETICON, (IntPtr)1, big);
        if (small != IntPtr.Zero) SendMessageW(hwnd, WM_SETICON, (IntPtr)0, small);
        return true;
    }
}
'@
}

function Resolve-ClaudeExe {
    # The MSIX install path carries the version number, so it changes on every
    # update. Always resolve it fresh instead of baking it into a shortcut.
    $pkg = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue |
           Sort-Object { [version]$_.Version } -Descending |
           Select-Object -First 1

    if ($pkg) {
        $exe = Join-Path $pkg.InstallLocation 'app\claude.exe'
        if (Test-Path -LiteralPath $exe) { return $exe }
    }

    # Fallbacks: unpackaged / per-user installs.
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'AnthropicClaude\claude.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Claude\Claude.exe'),
        'C:\Program Files\Claude\Claude.exe'
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }

    throw "claude.exe not found. Is Claude Desktop installed for this user?"
}

function Get-DefaultDataDir { Join-Path $env:APPDATA 'Claude' }

function New-DefaultConfig {
    [pscustomobject]@{
        profiles = @(
            [pscustomobject]@{
                name    = 'default'
                label   = 'Claude'
                dataDir = (Get-DefaultDataDir)
                stock   = $true
            }
        )
    }
}

function Read-Config {
    if (-not (Test-Path -LiteralPath $ProfilesPath)) {
        $cfg = New-DefaultConfig
        Write-Config $cfg
        return $cfg
    }
    $raw = Get-Content -LiteralPath $ProfilesPath -Raw -Encoding UTF8
    $cfg = $raw | ConvertFrom-Json
    if ($null -eq $cfg.profiles) { throw "profiles.json has no 'profiles' array." }
    # A single-element array round-trips as a scalar; force it back.
    $cfg.profiles = @($cfg.profiles)
    # Remember the top-level "iconBase" default separately. Copying it onto
    # each profile would be simpler to read, but Write-Config would then bake
    # it into profiles.json for every entry.
    $script:IconDefaults = @{
        iconBase       = [string]$cfg.iconBase
        iconBadgePos   = [string]$cfg.iconBadgePos
        iconBadgeScale = $cfg.iconBadgeScale
        iconBaseScale  = $cfg.iconBaseScale
        iconBadgePad   = $cfg.iconBadgePad
        iconStyle      = [string]$cfg.iconStyle
    }
    return $cfg
}

function Write-Config {
    param($Config)
    $json = $Config | ConvertTo-Json -Depth 6
    Set-Content -LiteralPath $ProfilesPath -Value $json -Encoding UTF8
}

function Find-Profile {
    param($Config, [string]$ProfileName)
    if ([string]::IsNullOrWhiteSpace($ProfileName)) { return $null }
    $Config.profiles | Where-Object { $_.name -eq $ProfileName } | Select-Object -First 1
}

function Test-DesktopExePath {
    # Is this claude.exe the desktop app, rather than the Claude Code CLI?
    #
    # Both are called claude.exe, and an instance on the stock profile carries
    # no --user-data-dir to tell them apart - so a CLI session would otherwise
    # be reported as the default profile running, and block share/unshare.
    # Match on where the app is installed instead of listing places the CLI
    # has lived: the CLI moves (it is at ~\.local\bin now), the install
    # locations are the ones Resolve-ClaudeExe already knows.
    param([string]$Path)
    if (-not $Path) { return $false }
    if ($Path -match '\\WindowsApps\\Claude_[^\\]+\\app\\claude\.exe$') { return $true }
    foreach ($known in @(
        (Join-Path $env:LOCALAPPDATA 'AnthropicClaude\claude.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Claude\Claude.exe'),
        'C:\Program Files\Claude\Claude.exe')) {
        if ($Path -ieq $known) { return $true }
    }
    return $false
}

function Get-RunningProfiles {
    # Match live claude.exe processes back to a data dir via their command line.
    $result = @{}
    $procs = Get-CimInstance Win32_Process -Filter "Name = 'claude.exe'" -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        $cl = $p.CommandLine
        if (-not $cl) { continue }
        # Only the main process (no --type=renderer etc.) identifies the profile.
        if ($cl -match '--type=') { continue }
        if (-not (Test-DesktopExePath -Path $p.ExecutablePath)) { continue }
        if ($cl -match '--user-data-dir=("([^"]+)"|(\S+))') {
            $dir = $matches[2]
            if (-not $dir) { $dir = $matches[3] }
        } else {
            $dir = Get-DefaultDataDir
        }
        $key = $dir.TrimEnd('\').ToLowerInvariant()
        if (-not $result.ContainsKey($key)) { $result[$key] = @() }
        $result[$key] += $p.ProcessId
    }
    return $result
}

function Test-ProfileRunning {
    param($Prof, $Running)
    $key = ([string]$Prof.dataDir).TrimEnd('\').ToLowerInvariant()
    return $Running.ContainsKey($key)
}

function Get-ProfileAumid {
    param($Prof)
    if ($Prof.aumid) { return [string]$Prof.aumid }
    return "Anthropic.Claude.$($Prof.name)"
}

function Get-RelaunchCommand {
    # What Windows runs when the user pins the taskbar button and clicks it.
    param($Prof)
    $launcher = Join-Path $Root 'mcd.ps1'
    return "`"$env:WINDIR\System32\wscript.exe`" `"$HiddenRunner`" `"$launcher`" launch $($Prof.name)"
}

function Set-ProfileWindowIdentity {
    # Stamp the profile's AUMID onto its app windows. Windows reads the AUMID
    # when the taskbar button is created, so the sooner this lands the better -
    # hence the tight poll right after launch.
    param($Prof, [int]$ProcessId, [int]$TimeoutSeconds = 45)

    Initialize-Native
    $aumid = Get-ProfileAumid -Prof $Prof
    # Only override the icon when the profile actually has one. Pointing
    # RelaunchIconResource at our generic claude.ico would replace the app's
    # own crisp icon with a downscale of the MSIX tile art on every profile.
    $custom = Get-ProfileIconPath -Prof $Prof -CustomOnly
    $iconRes = $null
    if ($custom) { $iconRes = "$custom,0" }
    $relaunch = Get-RelaunchCommand -Prof $Prof

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $stamped = 0
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { break }
        $windows = @([McdWin]::AppWindows([uint32]$ProcessId))
        $failed = 0
        foreach ($h in $windows) {
            # The icon is set every pass, before the AUMID check below can skip
            # the window - re-stamping is how a new icon reaches an instance
            # that already carries the right AUMID.
            if ($custom) { [McdWin]::SetWindowIcon($h, $custom) | Out-Null }
            if ([McdWin]::GetWindowAppId($h) -eq $aumid) { continue }
            if ([McdWin]::StampWindow($h, $aumid, $relaunch, $Prof.label, $iconRes)) { $stamped++ }
            else { $failed++ }
        }
        # Done once the windows exist and none of them refused the stamp.
        # Waiting on $stamped alone would spin for the whole timeout whenever
        # the AUMID was already correct, which is the common case on re-stamp.
        if ($windows.Count -gt 0 -and $failed -eq 0) { break }
        Start-Sleep -Milliseconds 150
    }
    return $stamped
}

function Set-ProfileWindowIcon {
    # Icon only, no AUMID. This is what the stock profile gets: it must keep
    # the packaged AUMID so existing pinned buttons still work, but there is no
    # reason it cannot have its own picture.
    param($Prof, [int]$ProcessId, [int]$TimeoutSeconds = 45)

    $ico = Get-ProfileIconPath -Prof $Prof -CustomOnly
    if (-not $ico) { return 0 }

    Initialize-Native
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { break }
        $windows = @([McdWin]::AppWindows([uint32]$ProcessId))
        if ($windows.Count -gt 0) {
            $n = 0
            foreach ($h in $windows) {
                if ([McdWin]::SetWindowIcon($h, $ico)) { $n++ }
            }
            return $n
        }
        Start-Sleep -Milliseconds 150
    }
    return 0
}

function Initialize-Icon {
    # A .ico of the app's own logo, so the tray and the autostart shortcut do
    # not depend on the versioned exe path (which breaks on the next update).
    param([string]$ExePath)

    if (-not (Test-Path -LiteralPath $IconDir)) {
        New-Item -ItemType Directory -Path $IconDir -Force | Out-Null
    }
    $icoPath = Join-Path $IconDir 'claude.ico'

    # Prefer the exe's own icon over the packaged tile art - same reason as
    # Get-AppLogoPath: the tile art is an older rendition.
    $png = Export-AppIconPng
    if (-not $png) {
        $assets = Join-Path (Split-Path -Parent (Split-Path -Parent $ExePath)) 'assets'
        $png = @(
            (Join-Path $assets 'Square150x150Logo.png'),
            (Join-Path $assets 'Square44x44Logo.png'),
            (Join-Path $assets 'icon.png')
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }

    if ($png) {
        # Rebuild after an app update: a new package writes new asset files.
        $src = Get-Item -LiteralPath $png
        if ((Test-Path -LiteralPath $icoPath) -and
            (Get-Item -LiteralPath $icoPath).LastWriteTimeUtc -ge $src.LastWriteTimeUtc) {
            return $icoPath
        }
        try { return (ConvertTo-Ico -SourcePath $png -DestPath $icoPath) }
        catch { Write-Warn2 "Could not build an icon ($($_.Exception.Message))." }
    }

    if (Test-Path -LiteralPath $icoPath) { return $icoPath }

    # Last resort: pull the 32x32 icon straight out of the exe.
    try {
        Add-Type -AssemblyName System.Drawing
        $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($ExePath)
        $fs = [System.IO.File]::Create($icoPath)
        $ico.Save($fs)
        $fs.Close()
        return $icoPath
    } catch {
        return $null
    }
}

function New-IcoDibFrame {
    # Classic ICO frame: BITMAPINFOHEADER + bottom-up 32bpp BGRA + AND mask.
    # PNG-compressed frames are only safe from 128px up - System.Drawing's
    # Icon.ToBitmap(), which the tray menu uses, cannot decode them at all.
    param([System.Drawing.Bitmap]$Bmp)

    $w = $Bmp.Width
    $h = $Bmp.Height
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $data = $Bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                          [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $stride = $data.Stride
        $buf = New-Object byte[] ($stride * $h)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buf, 0, $buf.Length)
    } finally { $Bmp.UnlockBits($data) }

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    try {
        $bw.Write([uint32]40)          # biSize
        $bw.Write([int32]$w)           # biWidth
        $bw.Write([int32]($h * 2))     # biHeight covers XOR + AND
        $bw.Write([uint16]1)           # biPlanes
        $bw.Write([uint16]32)          # biBitCount
        $bw.Write([uint32]0)           # biCompression = BI_RGB
        $bw.Write([uint32]($w * $h * 4))
        $bw.Write([int32]0); $bw.Write([int32]0)
        $bw.Write([uint32]0); $bw.Write([uint32]0)

        for ($y = $h - 1; $y -ge 0; $y--) { $bw.Write($buf, $y * $stride, $w * 4) }

        # All-zero AND mask: the alpha channel does the masking. Rows are
        # padded to a 4-byte boundary.
        $maskStride = [int][Math]::Floor(($w + 31) / 32) * 4
        $bw.Write((New-Object byte[] ($maskStride * $h)))
        $bw.Flush()
        # The unary comma stops PowerShell unrolling the byte[] into the
        # pipeline; without it the caller gets an Object[] and BinaryWriter
        # silently picks a different overload.
        return , $ms.ToArray()
    } finally {
        $bw.Dispose()
        $ms.Dispose()
    }
}

function ConvertTo-Ico {
    # Build a multi-resolution .ico from any image the user hands us. Windows
    # picks a different size for the taskbar, Alt-Tab, Explorer and the pinned
    # shortcut, so a single-size icon looks blurry in most of them.
    param([string]$SourcePath, [string]$DestPath,
          [int[]]$Sizes = @(16, 24, 32, 48, 64, 128, 256),
          [string]$BasePath, [ValidateSet('full', 'badge', 'disc')] [string]$Style = 'full',
          [ValidateSet('top-right', 'bottom-right', 'top-left', 'bottom-left')]
          [string]$BadgeCorner = 'top-right',
          [double]$BadgeScale = 0.52, [double]$BaseScale = 1.0, [double]$BadgePad = 0.03)

    Add-Type -AssemblyName System.Drawing

    # Read through a stream: Image.FromFile keeps the file locked.
    $srcBytes = [System.IO.File]::ReadAllBytes($SourcePath)
    $srcMs = New-Object System.IO.MemoryStream(,$srcBytes)
    $src = [System.Drawing.Image]::FromStream($srcMs)

    $base = $null; $baseMs = $null
    if ($Style -eq 'badge' -and $BasePath -and (Test-Path -LiteralPath $BasePath)) {
        $baseMs = New-Object System.IO.MemoryStream(,([System.IO.File]::ReadAllBytes($BasePath)))
        $base = [System.Drawing.Image]::FromStream($baseMs)
    }
    if (-not $base) { $Style = 'full' }

    $frames = @()
    try {
        foreach ($s in $Sizes) {
            $bmp = New-Object System.Drawing.Bitmap($s, $s, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb))
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            try {
                $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                $g.Clear([System.Drawing.Color]::Transparent)

                if ($Style -eq 'badge') {
                    # Claude's own icon, with the profile image as a round
                    # badge in the bottom-right corner - the same shape Windows
                    # uses for overlay icons, so it reads as "Claude, this one".
                    # BaseScale shrinks the backdrop when the artwork has no
                    # padding of its own and would otherwise sit heavier than
                    # an untouched Claude icon next to it.
                    $bd = [int][Math]::Round($s * $BaseScale)
                    if ($bd -lt 1) { $bd = 1 }
                    $bo = [int][Math]::Round(($s - $bd) / 2)
                    $g.DrawImage($base, $bo, $bo, $bd, $bd)

                    $d = [int][Math]::Round($s * $BadgeScale)
                    if ($d -lt 7) { $d = 7 }
                    if ($d -gt $s) { $d = $s }
                    $pad = [int][Math]::Round($s * $BadgePad)
                    $far = $s - $d - $pad
                    $bx = $(if ($BadgeCorner -like '*-left') { $pad } else { $far })
                    $by = $(if ($BadgeCorner -like 'top-*') { $pad } else { $far })

                    # White disc behind the badge so any artwork stays legible
                    # against the icon underneath.
                    $g.FillEllipse([System.Drawing.Brushes]::White, $bx, $by, $d, $d)

                    $inset = [int][Math]::Round($d * 0.12)
                    if ($inset -lt 1) { $inset = 1 }
                    $ix = $bx + $inset; $iy = $by + $inset
                    $id = $d - 2 * $inset

                    $clip = New-Object System.Drawing.Drawing2D.GraphicsPath
                    $clip.AddEllipse($ix, $iy, $id, $id)
                    $g.SetClip($clip)
                    $bs = [Math]::Min($id / $src.Width, $id / $src.Height)
                    $bw2 = [int][Math]::Round($src.Width * $bs)
                    $bh2 = [int][Math]::Round($src.Height * $bs)
                    $g.DrawImage($src, $ix + [int](($id - $bw2) / 2), $iy + [int](($id - $bh2) / 2), $bw2, $bh2)
                    $g.ResetClip()
                    $clip.Dispose()

                    # Thin ring to separate the badge from the base icon.
                    $penW = [Math]::Max(1.0, $s / 32.0)
                    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(230, 255, 255, 255)), $penW
                    $g.DrawEllipse($pen, $bx, $by, $d, $d)
                    $pen.Dispose()
                } elseif ($Style -eq 'disc') {
                    # A standalone badge: fill a circle first so a transparent
                    # png does not float on whatever is behind it, then clip
                    # the artwork inside.
                    $m = [Math]::Max(0, [int][Math]::Round($s * 0.02))
                    $d = $s - 2 * $m
                    $g.FillEllipse([System.Drawing.Brushes]::White, $m, $m, ($d - 1), ($d - 1))

                    $inset = [Math]::Max(1, [int][Math]::Round($d * 0.10))
                    $ix = $m + $inset; $iy = $m + $inset
                    $id = $d - 2 * $inset

                    $clip = New-Object System.Drawing.Drawing2D.GraphicsPath
                    $clip.AddEllipse($ix, $iy, $id, $id)
                    $g.SetClip($clip)
                    $ds = [Math]::Min($id / $src.Width, $id / $src.Height)
                    $dw = [int][Math]::Round($src.Width * $ds)
                    $dh = [int][Math]::Round($src.Height * $ds)
                    $g.DrawImage($src, $ix + [int](($id - $dw) / 2), $iy + [int](($id - $dh) / 2), $dw, $dh)
                    $g.ResetClip()
                    $clip.Dispose()

                    $penW = [Math]::Max(1.0, $s / 24.0)
                    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(70, 0, 0, 0)), $penW
                    $g.DrawEllipse($pen, $m, $m, ($d - 1), ($d - 1))
                    $pen.Dispose()
                } else {
                    # Keep the aspect ratio and centre it, rather than stretching a
                    # non-square source into a square icon. BaseScale adds the
                    # padding an unplated mark needs to sit like the real one.
                    $scale = [Math]::Min($s / $src.Width, $s / $src.Height) * $BaseScale
                    $w = [int][Math]::Round($src.Width * $scale)
                    $h = [int][Math]::Round($src.Height * $scale)
                    $g.DrawImage($src, [int](($s - $w) / 2), [int](($s - $h) / 2), $w, $h)
                }
            } finally { $g.Dispose() }

            if ($s -ge 128) {
                $ms = New-Object System.IO.MemoryStream
                $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
                $bytes = $ms.ToArray()
                $ms.Dispose()
            } else {
                $bytes = [byte[]](New-IcoDibFrame -Bmp $bmp)
            }
            $bmp.Dispose()
            $frames += , [pscustomobject]@{ Size = $s; Data = $bytes }
        }
    } finally {
        $src.Dispose()
        $srcMs.Dispose()
        if ($base) { $base.Dispose() }
        if ($baseMs) { $baseMs.Dispose() }
    }

    # ICONDIR + one ICONDIRENTRY per frame, then the PNG payloads.
    $out = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($out)
    try {
        $bw.Write([uint16]0)                 # reserved
        $bw.Write([uint16]1)                 # type = icon
        $bw.Write([uint16]$frames.Count)
        $offset = 6 + (16 * $frames.Count)
        foreach ($f in $frames) {
            # 256 is stored as 0 in the single byte width/height fields.
            $dim = if ($f.Size -ge 256) { 0 } else { $f.Size }
            $bw.Write([byte]$dim)
            $bw.Write([byte]$dim)
            $bw.Write([byte]0)               # palette entries
            $bw.Write([byte]0)               # reserved
            $bw.Write([uint16]1)             # colour planes
            $bw.Write([uint16]32)            # bits per pixel
            $bw.Write([uint32]$f.Data.Length)
            $bw.Write([uint32]$offset)
            $offset += $f.Data.Length
        }
        foreach ($f in $frames) { $bw.Write($f.Data) }
        $bw.Flush()
        [System.IO.File]::WriteAllBytes($DestPath, $out.ToArray())
    } finally {
        $bw.Dispose()
        $out.Dispose()
    }
    return $DestPath
}

function Resolve-ProfileIconSource {
    # The raw value of "icon" in profiles.json, made absolute. Relative paths
    # resolve against the repo so a checkout stays portable.
    param($Prof)
    if (-not $Prof.icon) { return $null }
    $p = [string]$Prof.icon
    if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $Root $p }
    return $p
}

function Initialize-TrayIcon {
    # This tool's own mark: three stacked Claude-orange bars, with the middle
    # one wider and taller so the shape reads as designed rather than as a
    # hamburger menu. Drawn in code rather than shipped as a binary, so a
    # fresh checkout has it without icons/ being in version control.
    $icoPath = Join-Path $IconDir 'mcd-tray.ico'
    if (Test-Path -LiteralPath $icoPath) { return $icoPath }

    if (-not (Test-Path -LiteralPath $IconDir)) {
        New-Item -ItemType Directory -Path $IconDir -Force | Out-Null
    }
    Add-Type -AssemblyName System.Drawing

    $S = 512
    $widths  = @(0.62, 0.90, 0.62)   # fraction of the canvas
    $heights = @(0.19, 0.26, 0.19)
    $gap     = $S * 0.065
    $radius  = 0.35                  # fraction of each bar's height

    $bmp = New-Object System.Drawing.Bitmap($S, $S, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb))
    $gr = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $gr.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $gr.Clear([System.Drawing.Color]::Transparent)
        $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 217, 119, 87))

        $hs = $heights | ForEach-Object { $S * $_ }
        $total = ($hs | Measure-Object -Sum).Sum + 2 * $gap
        $y = ($S - $total) / 2

        for ($i = 0; $i -lt 3; $i++) {
            $bw = $S * $widths[$i]
            $bh = $hs[$i]
            $x = ($S - $bw) / 2
            $d = [Math]::Min($bh * $radius, $bw / 2) * 2
            $path = New-Object System.Drawing.Drawing2D.GraphicsPath
            $path.AddArc($x, $y, $d, $d, 180, 90)
            $path.AddArc(($x + $bw - $d), $y, $d, $d, 270, 90)
            $path.AddArc(($x + $bw - $d), ($y + $bh - $d), $d, $d, 0, 90)
            $path.AddArc($x, ($y + $bh - $d), $d, $d, 90, 90)
            $path.CloseFigure()
            $gr.FillPath($brush, $path)
            $path.Dispose()
            $y += $bh + $gap
        }
        $brush.Dispose()
    } finally { $gr.Dispose() }

    $png = Join-Path $IconDir 'mcd-tray.png'
    $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()

    try { ConvertTo-Ico -SourcePath $png -DestPath $icoPath | Out-Null }
    catch { return $null }
    return $icoPath
}

function Get-BadgeBasePath {
    # What a badge icon is drawn on top of. Precedence: the profile's own
    # "iconBase", the top-level "iconBase" in profiles.json, then whatever the
    # installed package ships. The override exists because the package's art
    # is not always the logo you want to see.
    param($Prof, [switch]$Quiet)

    foreach ($v in @([string]$Prof.iconBase, [string]$script:IconDefaults['iconBase'])) {
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        $c = $v
        if (-not [System.IO.Path]::IsPathRooted($c)) { $c = Join-Path $Root $c }
        if (Test-Path -LiteralPath $c) { return $c }
        if (-not $Quiet) { Write-Warn2 "iconBase not found: $c" }
    }
    return (Get-AppLogoPath)
}

function Export-AppIconPng {
    # Render claude.exe's own 256px icon to a png we can composite with.
    # Cached against the exe path, which carries the package version, so an
    # app update produces a new file.
    $cacheDir = Join-Path $IconDir 'cache'
    try { $exe = Resolve-ClaudeExe } catch { return $null }

    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $hash = ([BitConverter]::ToString(
            $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($exe))) -replace '-', '').Substring(0, 8).ToLowerInvariant()
    } finally { $md5.Dispose() }
    $dest = Join-Path $cacheDir "app-$hash.png"
    if (Test-Path -LiteralPath $dest) { return $dest }

    Initialize-Native
    $h = [McdWin]::ExtractIcon($exe, 256)
    if ($h -eq [IntPtr]::Zero) { return $null }
    try {
        Add-Type -AssemblyName System.Drawing
        if (-not (Test-Path -LiteralPath $cacheDir)) {
            New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        }
        $ico = [System.Drawing.Icon]::FromHandle($h)
        $bmp = $ico.ToBitmap()
        $bmp.Save($dest, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose(); $ico.Dispose()
    } catch {
        return $null
    } finally {
        [McdWin]::DestroyIcon($h) | Out-Null
    }
    Get-ChildItem -LiteralPath $cacheDir -Filter 'app-*.png' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $dest } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    return $dest
}

function Get-AppLogoPath {
    # Default base layer for a badge: the app's own icon, so a badged profile
    # sits next to an untouched one and only the badge differs.
    $fromExe = Export-AppIconPng
    if ($fromExe) { return $fromExe }

    # Fall back to the packaged tile art (an older rendition of the logo).
    try {
        $exe = Resolve-ClaudeExe
        $assets = Join-Path (Split-Path -Parent (Split-Path -Parent $exe)) 'assets'
        $png = @(
            (Join-Path $assets 'Square150x150Logo.png'),
            (Join-Path $assets 'Square44x44Logo.png'),
            (Join-Path $assets 'icon.png')
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($png) { return $png }
    } catch { }
    $fallback = Join-Path $IconDir 'claude.ico'
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    return $null
}

function Get-IconOpt {
    # A badge setting: the profile's own value, else the top-level default in
    # profiles.json, else the built-in.
    param($Prof, [string]$Name, $Default)
    $v = $Prof.$Name
    if ($null -eq $v -or "$v" -eq '') { $v = $script:IconDefaults[$Name] }
    if ($null -eq $v -or "$v" -eq '') { return $Default }
    return $v
}

function Get-ProfileIconStyle {
    # 'overlay' (default) leaves Claude's icon alone and puts the profile
    # image in the taskbar's overlay slot, the way Chrome shows a profile
    # avatar. 'badge' composites the image into the icon itself. 'full' uses
    # the image on its own.
    param($Prof)
    $v = [string]$Prof.iconStyle
    if (-not $v) { $v = [string]$script:IconDefaults['iconStyle'] }
    switch ($v) {
        'full'    { return 'full' }
        'badge'   { return 'badge' }
        'overlay' { return 'overlay' }
        default   { return 'overlay' }
    }
}

function Get-ProfileMenuIcon {
    # What the tray menu shows next to a profile. In overlay mode the window
    # icon is deliberately left as plain Claude, but a menu of identical
    # Claude icons is useless - the whole point of the list is telling the
    # profiles apart, so show the profile's own image there.
    param($Prof, [switch]$Quiet)

    if ((Get-ProfileIconStyle -Prof $Prof) -eq 'overlay') {
        $ov = Get-ProfileOverlayIcon -Prof $Prof -Quiet:$Quiet
        if ($ov) { return $ov }
    }
    return (Get-ProfileIconPath -Prof $Prof -Quiet:$Quiet)
}

function Get-DefaultIconPath {
    # The Claude icon as this setup renders it, as a real .ico. Used for the
    # AUMID registration of a profile with no icon of its own, so a registered
    # profile's taskbar button matches an untouched one.
    param($Prof, [switch]$Quiet)

    $base = Get-BadgeBasePath -Prof $Prof -Quiet:$Quiet
    if (-not $base -or -not (Test-Path -LiteralPath $base)) { return $null }
    $scale = [double](Get-IconOpt -Prof $Prof -Name 'iconBaseScale' -Default 1.0)
    return (Resolve-IconCache -SourcePath $base -ProfileName 'base' -Style 'full' -BaseScale $scale)
}

function Get-ProfileOverlayIcon {
    # The small .ico handed to the taskbar overlay slot. Always the profile
    # image on its own - the overlay is drawn on top of Claude's real icon.
    param($Prof, [switch]$Quiet)

    $src = Resolve-ProfileIconSource -Prof $Prof
    if (-not $src -or -not (Test-Path -LiteralPath $src)) { return $null }
    return (Resolve-IconCache -SourcePath $src -ProfileName "$($Prof.name)-ov" -Style 'disc' `
                              -Sizes @(16, 20, 24, 32))
}

function Resolve-IconCache {
    # Windows needs a real .ico for LoadImage, IconLocation and
    # RelaunchIconResource, but profiles.json may name a .png. Convert on
    # demand and keep the result next to the source images; the file name
    # carries a signature, so a changed input lands on a new path.
    param([string]$SourcePath, [string]$ProfileName, [string]$Style = 'badge', [string]$BasePath,
          [string]$BadgeCorner = 'top-right', [double]$BadgeScale = 0.52, [double]$BaseScale = 1.0,
          [double]$BadgePad = 0.03, [int[]]$Sizes)

    $cacheDir = Join-Path $IconDir 'cache'
    if (-not (Test-Path -LiteralPath $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }
    $safe = ($ProfileName -replace '[^A-Za-z0-9._-]', '_')
    $src = Get-Item -LiteralPath $SourcePath

    # Use $BasePath directly: a local named $basePath would be the *same*
    # variable, PowerShell not being case sensitive, and would wipe the
    # argument the caller passed in.
    $baseSig = ''
    if ($Style -eq 'badge' -and $BasePath -and (Test-Path -LiteralPath $BasePath)) {
        $b = Get-Item -LiteralPath $BasePath
        # Include the base's own identity: swapping the artwork behind the
        # badge has to produce a new file name too.
        $baseSig = "$($b.FullName)|$($b.Length)|$($b.LastWriteTimeUtc.Ticks)"
    }

    # Explorer caches a taskbar icon against the file path it came from, so
    # reusing one name would keep showing the previous picture. Fold the
    # source's identity into the name instead - a new image, a different style
    # or an app update all mean a new path.
    $sig = "$($src.FullName)|$($src.Length)|$($src.LastWriteTimeUtc.Ticks)|$Style|$baseSig|$BadgeCorner|$BadgeScale|$BaseScale|$BadgePad|$($Sizes -join ',')"
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $hash = ([BitConverter]::ToString(
            $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($sig))) -replace '-', '').Substring(0, 8).ToLowerInvariant()
    } finally { $md5.Dispose() }
    $dest = Join-Path $cacheDir "$safe-$hash.ico"

    if (Test-Path -LiteralPath $dest) { return $dest }
    try {
        $extra = @{}
        if ($Sizes) { $extra['Sizes'] = $Sizes }
        ConvertTo-Ico -SourcePath $SourcePath -DestPath $dest -BasePath $BasePath -Style $Style `
                      -BadgeCorner $BadgeCorner -BadgeScale $BadgeScale -BaseScale $BaseScale `
                      -BadgePad $BadgePad @extra | Out-Null
    } catch {
        Write-Warn2 "Could not convert $SourcePath to an icon: $($_.Exception.Message)"
        return $null
    }
    # Drop this profile's earlier conversions.
    Get-ChildItem -LiteralPath $cacheDir -ErrorAction SilentlyContinue |
        Where-Object { ($_.Name -like "$safe-*.ico" -or $_.Name -eq "$safe.ico") -and $_.FullName -ne $dest } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    return $dest
}

function Get-ProfileIconPath {
    # A usable .ico for this profile: its own if "icon" is set in
    # profiles.json (any image format - converted and cached as needed),
    # otherwise the shared Claude icon.
    param($Prof, [switch]$CustomOnly, [switch]$Quiet)

    $src = Resolve-ProfileIconSource -Prof $Prof
    $style = Get-ProfileIconStyle -Prof $Prof
    # In overlay mode the window keeps Claude's own icon untouched; the
    # profile image goes to the taskbar overlay slot instead, so there is no
    # per-profile icon to hand back here.
    if ($style -eq 'overlay') { $src = $null }

    if ($src) {
        if (Test-Path -LiteralPath $src) {
            # A .ico is already icon-shaped, so use it as-is unless it has to
            # be composited onto the Claude icon as a badge.
            if ($style -eq 'full' -and [System.IO.Path]::GetExtension($src) -ieq '.ico') { return $src }
            $base = $null
            if ($style -eq 'badge') { $base = Get-BadgeBasePath -Prof $Prof -Quiet:$Quiet }
            $conv = Resolve-IconCache -SourcePath $src -ProfileName $Prof.name -Style $style -BasePath $base `
                        -BadgeCorner ([string](Get-IconOpt -Prof $Prof -Name 'iconBadgePos'   -Default 'top-right')) `
                        -BadgeScale  ([double](Get-IconOpt -Prof $Prof -Name 'iconBadgeScale' -Default 0.52)) `
                        -BaseScale   ([double](Get-IconOpt -Prof $Prof -Name 'iconBaseScale'  -Default 1.0)) `
                        -BadgePad    ([double](Get-IconOpt -Prof $Prof -Name 'iconBadgePad'   -Default 0.03))
            if ($conv) { return $conv }
        } elseif (-not $Quiet) {
            Write-Warn2 "Icon for '$($Prof.name)' is missing: $src"
        }
    }
    if ($CustomOnly) { return $null }

    # Same Claude artwork the taskbar shows, so the tray menu matches.
    $def = Get-DefaultIconPath -Prof $Prof -Quiet
    if ($def) { return $def }

    $fallback = Join-Path $IconDir 'claude.ico'
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    return $null
}

function Test-ProfileHasIcon {
    # Cheap yes/no for listings - never triggers a conversion.
    param($Prof)
    $src = Resolve-ProfileIconSource -Prof $Prof
    return ($src -and (Test-Path -LiteralPath $src))
}

function Initialize-HiddenRunner {
    if (Test-Path -LiteralPath $HiddenRunner) { return }
    $vbs = @"
' Runs a command with no console window, so launching a profile from a
' shortcut does not flash a black box. Generated by mcd.ps1.
Set shell = CreateObject("WScript.Shell")
args = ""
For i = 0 To WScript.Arguments.Count - 1
  args = args & " " & Chr(34) & WScript.Arguments(i) & Chr(34)
Next
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File" & args, 0, False
"@
    Set-Content -LiteralPath $HiddenRunner -Value $vbs -Encoding ASCII
}

# ------------------------------------------------- shared Claude Code sessions ---

# A Claude Code session is stored in two halves:
#
#   transcript : %USERPROFILE%\.claude\projects\<encoded cwd>\<cliSessionId>.jsonl
#   index      : <dataDir>\claude-code-sessions\<accountId>\<orgId>\local_<id>.json
#
# The transcript already sits outside the data dir, so every profile can read
# it no matter which account wrote it. Only the index is split per profile -
# a few hundred bytes of metadata (cwd, title, model, cliSessionId) per session
# - and that is the sole reason each account shows a different session list.
#
# Pointing the index directories of several profiles at one shared folder with
# a directory junction makes the list identical everywhere, and a session
# started in one account appears in the other as soon as its file is written.
# Junctions need no admin rights, unlike symbolic links.
#
# Sharing is opt-in per profile via "shareSessions" in profiles.json.

function Set-ProfileProp {
    # profiles.json round-trips through ConvertFrom-Json, so entries are
    # PSCustomObjects: new fields have to be added, not just assigned.
    param($Prof, [string]$PropName, $Value)
    if ($Prof.PSObject.Properties[$PropName]) { $Prof.$PropName = $Value }
    else { $Prof | Add-Member -NotePropertyName $PropName -NotePropertyValue $Value }
}

function Test-ShareEnabled {
    param($Prof)
    return [bool]$Prof.shareSessions
}

function Resolve-SessionIdentity {
    # Find <dataDir>\claude-code-sessions\<accountId>\<orgId>. Both ids are
    # minted on first sign-in, so before that this legitimately returns $null.
    param($Prof, [string]$WantAccount, [string]$WantOrg, [switch]$Quiet)

    $acct = $WantAccount
    if (-not $acct) { $acct = [string]$Prof.accountId }
    $org = $WantOrg
    if (-not $org) { $org = [string]$Prof.orgId }

    $root = Join-Path $Prof.dataDir 'claude-code-sessions'

    if (-not $acct) {
        if (-not (Test-Path -LiteralPath $root)) { return $null }
        $dirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending)
        if ($dirs.Count -eq 0) { return $null }
        if ($dirs.Count -gt 1 -and -not $Quiet) {
            Write-Warn2 "Profile '$($Prof.name)' holds $($dirs.Count) account ids; using the most recent ($($dirs[0].Name)). Override with -AccountId."
        }
        $acct = $dirs[0].Name
    }

    if (-not $org) {
        $adir = Join-Path $root $acct
        if (-not (Test-Path -LiteralPath $adir)) { return $null }
        $dirs = @(Get-ChildItem -LiteralPath $adir -Directory -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending)
        if ($dirs.Count -eq 0) { return $null }
        if ($dirs.Count -gt 1 -and -not $Quiet) {
            Write-Warn2 "Account $acct spans $($dirs.Count) organizations; using the most recent ($($dirs[0].Name)). Override with -OrgId."
        }
        $org = $dirs[0].Name
    }

    return [pscustomobject]@{
        accountId = $acct
        orgId     = $org
        path      = (Join-Path (Join-Path $root $acct) $org)
    }
}

function Test-JunctionPath {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-JunctionTarget {
    param([string]$Path)
    $t = (Get-Item -LiteralPath $Path -Force).Target
    if ($t -is [array]) { $t = @($t)[0] }
    $t = [string]$t
    # Junction targets come back as an NT path on some Windows builds.
    if ($t.StartsWith('\??\')) { $t = $t.Substring(4) }
    return $t
}

function Remove-JunctionPath {
    # Reparse point only. Remove-Item -Recurse follows junctions on Windows
    # PowerShell 5.1 and would empty the shared store behind the link.
    param([string]$Path)
    [System.IO.Directory]::Delete($Path, $false)
}

function Get-SessionIndexDir {
    # A profile's real index directory, or $null. A junction here is a
    # leftover from the old sharing scheme and is never synced into - see
    # New-SessionIndexSync.
    param($Prof, [switch]$Quiet)
    $ids = Resolve-SessionIdentity -Prof $Prof -Quiet:$Quiet
    if (-not $ids) { return $null }
    if (-not (Test-Path -LiteralPath $ids.path)) { return $null }
    if (Test-JunctionPath -Path $ids.path) { return $null }
    return $ids.path
}

function Get-IndexBackupDir {
    # Overwritten entries are parked here, one generation per entry.
    #
    # Deliberately outside every Claude data directory: anything left in the
    # index folder is a file the app will enumerate, and this is ours, not
    # its. Under LOCALAPPDATA rather than the checkout so it survives moving
    # or re-cloning the tool.
    param([string]$ProfileName)
    $safe = ($ProfileName -replace '[^A-Za-z0-9._-]', '_')
    return (Join-Path $env:LOCALAPPDATA "multi-claude-desktop\session-index-backup\$safe")
}

function Save-OverwrittenIndexEntry {
    # Keep the copy we are about to replace. One generation, same file name,
    # so this cannot grow without bound.
    param([string]$Path, [string]$ProfileName)
    try {
        $dir = Get-IndexBackupDir -ProfileName $ProfileName
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Copy-Item -LiteralPath $Path -Destination (Join-Path $dir (Split-Path $Path -Leaf)) -Force -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Get-DeletedSessionIds {
    # deleted_<id> marker files, whose body is the deletion time in unix ms.
    # Which id it holds - the session's own uuid or the cli session id - is
    # not something the app spells out, so callers match against both. Being
    # wrong in that direction only means declining to copy something in,
    # which is the harmless outcome.
    param([string]$Dir)
    $out = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Filter 'deleted_*' -File -ErrorAction SilentlyContinue)) {
        $out[$f.Name.Substring(8)] = $true
    }
    return $out
}

function New-SessionIndexSync {
    # Keep every opted-in profile's session list the same, by handing the
    # newest copy of each entry to everyone.
    #
    #   - only local_<uuid>.json; the uuid names cannot collide
    #   - for each entry, the copy with the newest mtime wins and is pushed
    #     to every profile that has an older one or none at all
    #   - the write is temp-file-plus-rename, so a running Claude Desktop
    #     never sees a half-written entry
    #   - the destination's mtime is set to the source's, so a pass with
    #     nothing new to do copies nothing and the set converges
    #   - nothing is ever deleted, and a session the profile holds a
    #     deleted_ marker for is not handed back to it
    #   - archived-sessions.idx and scheduled-tasks.json are shared state
    #     under a fixed name, so they are left alone entirely
    #
    # Losing here costs metadata only - title, archived flag, last focused.
    # The conversation itself lives in the transcript, which this never
    # touches. The replaced copy is still parked under
    # %LOCALAPPDATA%\multi-claude-desktop\session-index-backup, one
    # generation per entry, mostly so a misbehaving pass can be seen and
    # undone.
    param($Config, [switch]$Quiet)

    $parts = @()
    foreach ($p in $Config.profiles) {
        if (-not (Test-ShareEnabled -Prof $p)) { continue }
        $dir = Get-SessionIndexDir -Prof $p -Quiet
        if (-not $dir) { continue }
        $parts += [pscustomobject]@{
            Name    = [string]$p.name
            Dir     = $dir
            Files   = @{}
            Deleted = (Get-DeletedSessionIds -Dir $dir)
        }
    }
    if ($parts.Count -lt 2) { return 0 }

    # Directory listings only - a pass with nothing to do opens no files.
    $best = @{}
    foreach ($pt in $parts) {
        foreach ($f in @(Get-ChildItem -LiteralPath $pt.Dir -Filter 'local_*.json' -File -ErrorAction SilentlyContinue)) {
            $pt.Files[$f.Name] = $f
            $cur = $best[$f.Name]
            if (-not $cur -or $f.LastWriteTimeUtc -gt $cur.LastWriteTimeUtc) { $best[$f.Name] = $f }
        }
    }

    $copied = 0
    foreach ($pt in $parts) {
        foreach ($name in $best.Keys) {
            $src = $best[$name]
            $have = $pt.Files[$name]
            if ($have -and $have.LastWriteTimeUtc -ge $src.LastWriteTimeUtc) { continue }
            if ($src.DirectoryName -ieq $pt.Dir) { continue }

            if (-not $have) {
                # Only relevant for an entry the profile does not have: a
                # marker may be filed under the session uuid or the cli id.
                $uuid = $name.Substring(6, $name.Length - 11)   # local_<uuid>.json
                if ($pt.Deleted.ContainsKey($uuid)) { continue }
                if ($pt.Deleted.Count -gt 0) {
                    $cli = $null
                    try { $cli = [string](Get-Content -LiteralPath $src.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).cliSessionId } catch { }
                    if ($cli -and $pt.Deleted.ContainsKey($cli)) { continue }
                }
            }

            $dest = Join-Path $pt.Dir $name
            $tmp = "$dest.mcd-tmp"
            try {
                # Park the version we are replacing before it goes.
                if ($have) { Save-OverwrittenIndexEntry -Path $dest -ProfileName $pt.Name | Out-Null }
                Copy-Item -LiteralPath $src.FullName -Destination $tmp -Force -ErrorAction Stop
                # Carry the source's timestamp across, or the copy would look
                # newer than its origin and bounce back on the next pass.
                (Get-Item -LiteralPath $tmp).LastWriteTimeUtc = $src.LastWriteTimeUtc
                Move-Item -LiteralPath $tmp -Destination $dest -Force -ErrorAction Stop
                $copied++
                if (-not $Quiet) {
                    Write-Info "  -> $($pt.Name): $name$(if ($have) { ' (updated)' } else { '' })"
                }
            } catch {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                if (-not $Quiet) { Write-Warn2 "  !! $($pt.Name): $name - $($_.Exception.Message)" }
            }
        }
    }
    return $copied
}

function Get-ShareState {
    # What 'list' and the tray show.
    param($Config, $Prof)
    $ids = Resolve-SessionIdentity -Prof $Prof -Quiet
    if ($ids -and (Test-JunctionPath -Path $ids.path)) { return 'JUNCTION!' }
    if (-not (Test-ShareEnabled -Prof $Prof)) { return '-' }
    if (-not $ids -or -not (Test-Path -LiteralPath $ids.path)) { return 'pending' }
    return 'synced'
}

function Assert-NotRunning {
    param($Prof, $Running, [string]$Verb)
    if (Test-ProfileRunning -Prof $Prof -Running $Running) {
        throw "Profile '$($Prof.name)' is running. Close it before you $Verb its sessions (or pass -Force)."
    }
}

# --------------------------------------------------------------- commands ---

function Invoke-List {
    $cfg = Read-Config
    $exe = Resolve-ClaudeExe
    $running = Get-RunningProfiles

    Write-Info ""
    Write-Info "claude.exe : $exe"
    Write-Info "tray       : $(if (Test-Autostart) { 'starts at sign-in' } else { 'autostart off' })"
    Write-Info ""

    $rows = foreach ($p in $cfg.profiles) {
        $exists = Test-Path -LiteralPath $p.dataDir
        $state = 'stopped'
        if (Test-ProfileRunning -Prof $p -Running $running) { $state = 'RUNNING' }
        elseif (-not $exists) { $state = 'not created' }
        [pscustomobject]@{
            Name     = $p.name
            Label    = $p.label
            State    = $state
            Sessions = (Get-ShareState -Config $cfg -Prof $p)
            Icon     = $(if (Test-ProfileHasIcon -Prof $p) { 'custom' } else { '-' })
            DataDir  = $p.dataDir
        }
    }
    $rows | Format-Table -AutoSize
}

function Invoke-Add {
    if ([string]::IsNullOrWhiteSpace($Name)) { throw "Usage: .\mcd.ps1 add <name> [-Label <text>] [-DataDir <path>]" }
    if ($Name -notmatch '^[A-Za-z0-9._-]+$') { throw "Profile name may only contain letters, digits, dot, dash and underscore." }

    $cfg = Read-Config
    if (Find-Profile -Config $cfg -ProfileName $Name) { throw "Profile '$Name' already exists." }

    $dir = $DataDir
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = Join-Path $env:APPDATA "Claude-$Name" }
    $lbl = $Label
    if ([string]::IsNullOrWhiteSpace($lbl)) { $lbl = "Claude ($Name)" }

    $new = [pscustomobject]@{ name = $Name; label = $lbl; dataDir = $dir; stock = $false }
    $cfg.profiles = @($cfg.profiles) + $new
    Write-Config $cfg

    Write-Ok "Added profile '$Name'."
    Write-Info "  label   : $lbl"
    Write-Info "  dataDir : $dir  (created on first launch)"
    Write-Info ""
    Write-Info "Next: .\mcd.ps1 launch $Name    then sign in with that account."
}

function Invoke-Remove {
    if ([string]::IsNullOrWhiteSpace($Name)) { throw "Usage: .\mcd.ps1 remove <name> [-DeleteData]" }
    $cfg = Read-Config
    $p = Find-Profile -Config $cfg -ProfileName $Name
    if (-not $p) { throw "No such profile: $Name" }
    if ($p.stock) { throw "The 'default' profile points at the stock data directory and cannot be removed." }

    if ($DeleteData) {
        if (-not $Force) {
            Write-Warn2 "This permanently deletes $($p.dataDir) (login state, local app data)."
            $ans = Read-Host "Type the profile name '$Name' to confirm"
            if ($ans -ne $Name) { Write-Info "Cancelled."; return }
        }
        if (Test-Path -LiteralPath $p.dataDir) {
            Remove-Item -LiteralPath $p.dataDir -Recurse -Force
            Write-Ok "Deleted $($p.dataDir)"
        }
    }

    Unregister-ProfileAumid -Prof $p
    $cfg.profiles = @($cfg.profiles | Where-Object { $_.name -ne $Name })
    Write-Config $cfg
    Write-Ok "Removed profile '$Name' from profiles.json."
    if (-not $DeleteData) { Write-Info "Its data directory was left in place: $($p.dataDir)" }
}

function Invoke-Launch {
    if ([string]::IsNullOrWhiteSpace($Name)) { throw "Usage: .\mcd.ps1 launch <name>" }
    $cfg = Read-Config
    $p = Find-Profile -Config $cfg -ProfileName $Name
    if (-not $p) { throw "No such profile: $Name  (see: .\mcd.ps1 list)" }

    $exe = Resolve-ClaudeExe
    $running = Get-RunningProfiles
    # Claude Desktop is single-instance per data dir: launching again just
    # surfaces the existing window and the process we start exits at once, so
    # there is nothing for us to stamp.
    $wasRunning = Test-ProfileRunning -Prof $p -Running $running
    if ($wasRunning) {
        Write-Warn2 "Profile '$Name' already has a running instance; bringing it to the front."
    }

    # Pull in session list entries from the other opted-in profiles before the
    # app reads its index. Copies files in, never touches existing ones.
    if (Test-ShareEnabled -Prof $p) {
        $n = New-SessionIndexSync -Config $cfg -Quiet
        if ($n -gt 0) { Write-Info "Synced $n session list entr$(if ($n -eq 1) { 'y' } else { 'ies' })." }
    }

    if ($p.stock) {
        # The stock profile keeps the package AUMID so it stays merged with the
        # user's existing pinned Claude button. A custom icon is still fine -
        # it changes the picture, not the grouping.
        $proc = Start-Process -FilePath $exe -PassThru
        Write-Ok "Launched '$Name' ($($p.label))."
        if (-not $NoStamp -and -not $wasRunning) {
            if ((Set-ProfileWindowIcon -Prof $p -ProcessId $proc.Id) -gt 0) {
                Write-Info "Window icon: $(Get-ProfileIconPath -Prof $p -CustomOnly)"
            }
        }
        return
    }

    if (-not (Test-Path -LiteralPath $p.dataDir)) {
        New-Item -ItemType Directory -Path $p.dataDir -Force | Out-Null
    }
    Initialize-Icon -ExePath $exe | Out-Null
    # The taskbar reads the button's icon from the AUMID registration, so it
    # has to exist before the window appears.
    Register-ProfileAumid -Prof $p | Out-Null
    # Quote the path ourselves: Start-Process does not quote arguments.
    $proc = Start-Process -FilePath $exe -ArgumentList "--user-data-dir=`"$($p.dataDir)`"" -PassThru
    Write-Ok "Launched '$Name' ($($p.label))."

    if ($NoStamp -or $wasRunning) { return }
    $n = Set-ProfileWindowIdentity -Prof $p -ProcessId $proc.Id
    if ($n -gt 0) {
        Write-Info "Taskbar identity: $(Get-ProfileAumid -Prof $p)"
    } elseif (Test-TrayRunning) {
        Write-Info "The window was not up yet; the tray will stamp it within a few seconds."
    } else {
        Write-Warn2 "Could not stamp the taskbar identity (window did not appear in time)."
        Write-Warn2 "Run '.\mcd.ps1 stamp $Name', or '.\mcd.ps1 tray' to keep it applied automatically."
    }
}

function Invoke-StampOne {
    # Re-apply one profile's taskbar identity and icon to its live windows.
    param($Prof)

    if ($Prof.stock) {
        # The packaged AUMID stays put, but the icon can be re-applied.
        if (-not (Get-ProfileIconPath -Prof $Prof -CustomOnly)) {
            # An overlay lives in the taskbar's own slot and only a resident
            # process can hold it there, so that one is the tray's job.
            if ((Get-ProfileIconStyle -Prof $Prof) -eq 'overlay' -and (Test-ProfileHasIcon -Prof $Prof)) {
                if (Test-TrayRunning) { Write-Info "$($Prof.name): overlay icon is maintained by the tray." }
                else { Write-Warn2 "$($Prof.name): overlay icon needs the tray running - start it with '.\mcd.ps1 tray'." }
                return
            }
            throw "'$($Prof.name)' is the stock profile: it keeps the packaged AUMID and has no custom icon to re-apply."
        }
        # No --user-data-dir on the command line is what identifies it.
        $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'claude.exe'" |
                   Where-Object { $_.CommandLine -and $_.CommandLine -notmatch '--type=' -and
                                  $_.CommandLine -notmatch '--user-data-dir' })
        if (-not $procs) { throw "No running instance for profile '$($Prof.name)'." }
        $n = 0
        foreach ($proc in $procs) { $n += Set-ProfileWindowIcon -Prof $Prof -ProcessId $proc.ProcessId -TimeoutSeconds 3 }
        if ($n -gt 0) { Write-Ok "$($Prof.name): re-applied the icon to $n window(s)." }
        else { Write-Warn2 "$($Prof.name): no window to re-icon." }
        return
    }

    Register-ProfileAumid -Prof $Prof | Out-Null

    $key = ([string]$Prof.dataDir).TrimEnd('').ToLowerInvariant()
    $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'claude.exe'" |
               Where-Object { $_.CommandLine -and $_.CommandLine -notmatch '--type=' -and
                              $_.CommandLine -match [regex]::Escape($key) })
    if (-not $procs) { throw "No running instance for profile '$($Prof.name)'." }

    $total = 0
    foreach ($proc in $procs) {
        $total += Set-ProfileWindowIdentity -Prof $Prof -ProcessId $proc.ProcessId -TimeoutSeconds 3
    }
    if ($total -gt 0) { Write-Ok "$($Prof.name): stamped $total window(s) with $(Get-ProfileAumid -Prof $Prof)." }
    else { Write-Info "$($Prof.name): AUMID already correct; icon re-applied where one is set." }
}

function Invoke-Stamp {
    # Re-apply the taskbar identity and icon to running instances - after the
    # app opened a new window, after the launch-time poll timed out, or after
    # you changed "icon" in profiles.json.
    $cfg = Read-Config

    if ($All) {
        $running = Get-RunningProfiles
        $any = $false
        foreach ($prof in $cfg.profiles) {
            if (-not (Test-ProfileRunning -Prof $prof -Running $running)) { continue }
            $any = $true
            try { Invoke-StampOne -Prof $prof } catch { Write-Warn2 "$($prof.name): $($_.Exception.Message)" }
        }
        if (-not $any) { Write-Info "No profile is running." }
        return
    }

    if ([string]::IsNullOrWhiteSpace($Name)) { throw "Usage: .\mcd.ps1 stamp <name> | -All" }
    $p = Find-Profile -Config $cfg -ProfileName $Name
    if (-not $p) { throw "No such profile: $Name" }
    Invoke-StampOne -Prof $p
}

function Invoke-SyncConfig {
    # claude_desktop_config.json (MCP servers) lives inside the data dir, so a
    # fresh profile starts with none. Copy it across on request.
    if ([string]::IsNullOrWhiteSpace($Name) -or [string]::IsNullOrWhiteSpace($Name2)) {
        throw "Usage: .\mcd.ps1 sync-config <from-profile> <to-profile>"
    }
    $cfg = Read-Config
    $src = Find-Profile -Config $cfg -ProfileName $Name
    $dst = Find-Profile -Config $cfg -ProfileName $Name2
    if (-not $src) { throw "No such profile: $Name" }
    if (-not $dst) { throw "No such profile: $Name2" }

    $srcFile = Join-Path $src.dataDir 'claude_desktop_config.json'
    if (-not (Test-Path -LiteralPath $srcFile)) { throw "Not found: $srcFile" }
    if (-not (Test-Path -LiteralPath $dst.dataDir)) {
        New-Item -ItemType Directory -Path $dst.dataDir -Force | Out-Null
    }
    $dstFile = Join-Path $dst.dataDir 'claude_desktop_config.json'

    if (Test-Path -LiteralPath $dstFile) {
        $backup = "$dstFile.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
        Copy-Item -LiteralPath $dstFile -Destination $backup
        Write-Info "Backed up existing config to $backup"
    }
    Copy-Item -LiteralPath $srcFile -Destination $dstFile -Force
    Write-Ok "Copied MCP config: $Name -> $Name2"
    Write-Warn2 "Restart the '$Name2' instance for it to take effect."
}

function Invoke-Icon {
    $cfg = Read-Config

    # No name: show what every profile uses today.
    if ([string]::IsNullOrWhiteSpace($Name)) {
        $rows = foreach ($p in $cfg.profiles) {
            $src = Resolve-ProfileIconSource -Prof $p
            $state = 'default'
            if ($src) { $state = $(if (Test-Path -LiteralPath $src) { 'custom' } else { 'MISSING' }) }
            [pscustomobject]@{
                Name   = $p.name
                Icon   = $state
                Style  = $(if ($src) { Get-ProfileIconStyle -Prof $p } else { '-' })
                Source = $(if ($src) { $p.icon } else { '(claude.ico)' })
            }
        }
        $rows | Format-Table -AutoSize
        Write-Info "Set one with : .\mcd.ps1 icon <name> <image>     (png, jpg, bmp, gif or ico)"
        Write-Info "               add -Full for the image on its own instead of a corner badge"
        Write-Info "Clear it with: .\mcd.ps1 icon <name> -Clear"
        Write-Info "Or edit profiles.json:  `"icon`": `"icons\work.png`", `"iconStyle`": `"badge`""
        return
    }

    $p = Find-Profile -Config $cfg -ProfileName $Name
    if (-not $p) { throw "No such profile: $Name  (see: .\mcd.ps1 list)" }

    if ($Clear) {
        Set-ProfileProp -Prof $p -PropName 'icon' -Value $null
        Write-Config $cfg
        Register-ProfileAumid -Prof $p | Out-Null
        Write-Ok "Cleared the icon for '$($p.name)'; it falls back to the Claude icon."
        Write-Info "Run '.\mcd.ps1 stamp $($p.name)' to update a running window."
        return
    }

    if ([string]::IsNullOrWhiteSpace($Name2)) {
        throw "Usage: .\mcd.ps1 icon <name> <image>  |  .\mcd.ps1 icon <name> -Clear"
    }
    $srcPath = $Name2
    if (-not [System.IO.Path]::IsPathRooted($srcPath)) { $srcPath = Join-Path (Get-Location).Path $srcPath }
    if (-not (Test-Path -LiteralPath $srcPath)) { throw "No such file: $srcPath" }

    if (-not (Test-Path -LiteralPath $IconDir)) {
        New-Item -ItemType Directory -Path $IconDir -Force | Out-Null
    }
    # Keep the image in its original format next to the repo, and record a
    # relative path. profiles.json can just as well point anywhere else - the
    # conversion to .ico happens on use either way.
    $safe = ($p.name -replace '[^A-Za-z0-9._-]', '_')
    $ext = [System.IO.Path]::GetExtension($srcPath).ToLowerInvariant()
    $dest = Join-Path $IconDir "$safe$ext"
    if ((Resolve-Path -LiteralPath $srcPath).Path -ine $dest) {
        Copy-Item -LiteralPath $srcPath -Destination $dest -Force
        Write-Info "Copied the image to $dest"
    }

    Set-ProfileProp -Prof $p -PropName 'icon' -Value "icons\$safe$ext"
    Set-ProfileProp -Prof $p -PropName 'iconStyle' -Value $(if ($Full) { 'full' } else { 'badge' })
    Write-Config $cfg
    Write-Ok "Icon for '$($p.name)': icons\$safe$ext  (style: $(Get-ProfileIconStyle -Prof $p))"

    Register-ProfileAumid -Prof $p | Out-Null

    $resolved = Get-ProfileIconPath -Prof $p -CustomOnly
    if ($resolved) { Write-Info "Built a multi-size .ico (16-256 px): $resolved" }

    # Live windows can take it right away.
    $running = Get-RunningProfiles
    if (Test-ProfileRunning -Prof $p -Running $running) {
        $key = ([string]$p.dataDir).TrimEnd('\').ToLowerInvariant()
        $n = 0
        foreach ($procId in $running[$key]) {
            $n += Set-ProfileWindowIcon -Prof $p -ProcessId $procId -TimeoutSeconds 3
        }
        if ($n -gt 0) { Write-Info "Applied it to $n running window(s)." }
    }
}

function Select-ShareTargets {
    # 'share'/'unshare' take either one profile name or -All.
    param($Config, [string]$Usage)
    if ($All) { return @($Config.profiles) }
    if ([string]::IsNullOrWhiteSpace($Name)) { throw $Usage }
    $p = Find-Profile -Config $Config -ProfileName $Name
    if (-not $p) { throw "No such profile: $Name  (see: .\mcd.ps1 list)" }
    return @($p)
}

function Invoke-Share {
    $cfg = Read-Config
    $targets = Select-ShareTargets -Config $cfg -Usage "Usage: .\mcd.ps1 share <name> | -All"

    foreach ($p in $targets) {
        # A leftover junction from the old scheme has to go first: Claude
        # Desktop refuses to write its index through one.
        $ids = Resolve-SessionIdentity -Prof $p -Quiet
        if ($ids -and (Test-JunctionPath -Path $ids.path)) {
            throw "'$($p.name)' still has the old junction at $($ids.path). Run '.\mcd.ps1 unshare $($p.name)' with Claude Desktop closed first."
        }
        Set-ProfileProp -Prof $p -PropName 'shareSessions' -Value $true
        Write-Ok "Sharing sessions: $($p.name)"
    }
    Write-Config $cfg

    $n = New-SessionIndexSync -Config $cfg
    Write-Info ""
    Write-Info "Copied $n session list entr$(if ($n -eq 1) { 'y' } else { 'ies' })."
    Write-Info "The tray keeps them in step from here; it only ever adds entries."
    Write-Warn2 "Do not open the SAME session in two profiles at once - they would"
    Write-Warn2 "both append to one transcript. Different sessions are fine."
}

function Invoke-Unshare {
    # Stops future syncing. Entries already copied in stay where they are:
    # deleting them is the one operation that could lose something, and the
    # profile has been showing them as its own.
    $cfg = Read-Config
    $targets = Select-ShareTargets -Config $cfg -Usage "Usage: .\mcd.ps1 unshare <name> | -All"
    $running = Get-RunningProfiles

    foreach ($p in $targets) {
        Set-ProfileProp -Prof $p -PropName 'shareSessions' -Value $false

        # Undo a junction left by the old scheme, which does need the app shut.
        $ids = Resolve-SessionIdentity -Prof $p -Quiet
        if ($ids -and (Test-JunctionPath -Path $ids.path)) {
            if (-not $Force) { Assert-NotRunning -Prof $p -Running $running -Verb 'unshare' }
            $target = Get-JunctionTarget -Path $ids.path
            Remove-JunctionPath -Path $ids.path
            New-Item -ItemType Directory -Path $ids.path -Force | Out-Null
            $n = 0
            foreach ($f in @(Get-ChildItem -LiteralPath $target -File -ErrorAction SilentlyContinue)) {
                Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $ids.path $f.Name) -Force
                $n++
            }
            Write-Ok "Removed the old junction on '$($p.name)' and copied $n file(s) back."
        } else {
            Write-Ok "Stopped sharing: $($p.name)"
        }
    }
    Write-Config $cfg
}

function Invoke-SyncSessions {
    $cfg = Read-Config
    $n = New-SessionIndexSync -Config $cfg
    if ($n -eq 0) { Write-Info "Nothing to copy - every shared profile already has the same entries." }
    else { Write-Ok "Copied $n session list entr$(if ($n -eq 1) { 'y' } else { 'ies' })." }
}

function Invoke-Tray {
    # The tray is a thin front end over this script's functions; it dot-sources
    # them rather than shelling out, so toggles are instant.
    if (-not (Test-Path -LiteralPath $TrayScript)) { throw "Not found: $TrayScript" }
    Initialize-HiddenRunner
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') `
                  -ArgumentList "`"$HiddenRunner`"", "`"$TrayScript`""
    Write-Ok "Tray icon started. Right-click it to launch profiles or toggle session sharing."
}

function Get-AumidRegistryDir {
    Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Multi Claude Desktop'
}

function Register-ProfileAumid {
    # Windows resolves a window's AppUserModelID by looking for a Start Menu
    # shortcut stamped with the same id, and draws the taskbar BUTTON from
    # that shortcut's icon and name. No shortcut, no custom button icon - the
    # window icon alone only reaches the hover thumbnail and Alt-Tab.
    #
    # This is registration, not a convenience shortcut: it is created and kept
    # in step automatically. Clicking it does launch the profile, which is a
    # side benefit rather than the point.
    param($Prof)

    if ($Prof.stock) { return $null }   # keeps the packaged AUMID on purpose

    $dir = Get-AumidRegistryDir
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Initialize-HiddenRunner
    $safe = ([string]$Prof.label -replace '[\\/:*?"<>|]', '-')
    $lnkPath = Join-Path $dir "$safe.lnk"

    $icon = Get-ProfileIconPath -Prof $Prof -CustomOnly -Quiet
    if (-not $icon) {
        # No per-profile icon: use the same Claude artwork the shell draws for
        # an unregistered instance, so the two buttons match.
        $icon = Get-DefaultIconPath -Prof $Prof -Quiet
        if (-not $icon) {
            try { $icon = Resolve-ClaudeExe } catch { $icon = Join-Path $IconDir 'claude.ico' }
        }
    }
    $wanted = "$($Prof.name)|$(Get-ProfileAumid -Prof $Prof)|$icon"

    $wsh = New-Object -ComObject WScript.Shell
    if (Test-Path -LiteralPath $lnkPath) {
        # Skip the rewrite (and the shell notification it triggers) when
        # nothing about the registration changed.
        if ($wsh.CreateShortcut($lnkPath).Description -eq $wanted) { return $lnkPath }
    }

    $lnk = $wsh.CreateShortcut($lnkPath)
    $lnk.TargetPath = "$env:WINDIR\System32\wscript.exe"
    $lnk.Arguments = "`"$HiddenRunner`" `"$(Join-Path $Root 'mcd.ps1')`" launch $($Prof.name)"
    $lnk.WorkingDirectory = $Root
    $lnk.Description = $wanted
    $lnk.IconLocation = "$icon,0"
    $lnk.Save()

    Initialize-Native
    try { [McdWin]::StampShortcut($lnkPath, (Get-ProfileAumid -Prof $Prof)) }
    catch { Write-Warn2 "Could not stamp the AUMID on $lnkPath : $($_.Exception.Message)" }
    return $lnkPath
}

function Unregister-ProfileAumid {
    param($Prof)
    $dir = Get-AumidRegistryDir
    $safe = ([string]$Prof.label -replace '[\\/:*?"<>|]', '-')
    $lnkPath = Join-Path $dir "$safe.lnk"
    if (Test-Path -LiteralPath $lnkPath) { Remove-Item -LiteralPath $lnkPath -Force }
}

function Test-TrayRunning {
    # The tray re-stamps windows the app opens later, so advice about a failed
    # one-shot stamp depends on whether it is up.
    $pat = '*mcd-tray.ps1*'
    return [bool](@(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -like $pat }).Count)
}

function Get-AutostartPath {
    # Per-user Startup folder: no admin rights, no scheduled task to maintain,
    # and the user can see and delete it from shell:startup.
    Join-Path ([Environment]::GetFolderPath('Startup')) 'Multi Claude Desktop (tray).lnk'
}

function Test-Autostart {
    $lnk = Get-AutostartPath
    if (-not (Test-Path -LiteralPath $lnk)) { return $false }
    # A shortcut left behind by a previous checkout points somewhere else.
    try {
        $wsh = New-Object -ComObject WScript.Shell
        return ($wsh.CreateShortcut($lnk).Arguments -like "*$TrayScript*")
    } catch { return $false }
}

function Invoke-Autostart {
    $mode = $Name
    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'on' }
    if ($mode -notin @('on', 'off', 'status')) {
        throw "Usage: .\mcd.ps1 autostart [on|off|status]"
    }
    $lnk = Get-AutostartPath

    if ($mode -eq 'off') {
        if (Test-Path -LiteralPath $lnk) {
            Remove-Item -LiteralPath $lnk -Force
            Write-Ok "Autostart off. Removed $lnk"
        } else {
            Write-Info "Autostart was already off."
        }
        return
    }

    if ($mode -eq 'status') {
        if (Test-Autostart) { Write-Ok "Autostart on : $lnk" }
        elseif (Test-Path -LiteralPath $lnk) { Write-Warn2 "A shortcut exists but points elsewhere: $lnk" }
        else { Write-Info "Autostart off." }
        return
    }

    if (-not (Test-Path -LiteralPath $TrayScript)) { throw "Not found: $TrayScript" }
    Initialize-HiddenRunner
    $ico = $null
    try { $ico = Initialize-TrayIcon } catch { }
    if (-not $ico) { try { $ico = Initialize-Icon -ExePath (Resolve-ClaudeExe) } catch { } }

    $wsh = New-Object -ComObject WScript.Shell
    $s = $wsh.CreateShortcut($lnk)
    $s.TargetPath = "$env:WINDIR\System32\wscript.exe"
    $s.Arguments = "`"$HiddenRunner`" `"$TrayScript`""
    $s.WorkingDirectory = $Root
    $s.Description = 'Multi Claude Desktop - tray icon'
    if ($ico) { $s.IconLocation = "$ico,0" }
    $s.Save()

    Write-Ok "Autostart on : $lnk"
    Write-Info "The tray icon will appear at every sign-in."
    Write-Warn2 "It runs this checkout ($Root). Moving or renaming the folder breaks it -"
    Write-Warn2 "re-run '.\mcd.ps1 autostart' from the new location if you do."
}

function Invoke-Open {
    if ([string]::IsNullOrWhiteSpace($Name)) { throw "Usage: .\mcd.ps1 open <name>" }
    $cfg = Read-Config
    $p = Find-Profile -Config $cfg -ProfileName $Name
    if (-not $p) { throw "No such profile: $Name" }
    if (-not (Test-Path -LiteralPath $p.dataDir)) { throw "Not created yet: $($p.dataDir)" }
    Start-Process explorer.exe $p.dataDir
}

function Invoke-Where {
    Write-Info (Resolve-ClaudeExe)
}

function Invoke-Help {
    Write-Info @"
Multi Claude Desktop - run several Claude accounts side by side.

  .\mcd.ps1 list
      Show every profile, its data directory and whether it is running.

  .\mcd.ps1 add <name> [-Label "text"] [-DataDir <path>]
      Register a new profile. Data dir defaults to %APPDATA%\Claude-<name>.

  .\mcd.ps1 launch <name> [-NoStamp]
      Start Claude Desktop against that profile's data directory and give its
      window a per-profile taskbar identity. -NoStamp skips the latter.

  .\mcd.ps1 stamp <name> | -All
      Re-apply the taskbar identity and icon to running instances. Run this
      after editing "icon" in profiles.json - a live window does not pick the
      change up on its own.

  .\mcd.ps1 sync-config <from> <to>
      Copy claude_desktop_config.json (MCP servers) between profiles.

  .\mcd.ps1 share <name> | -All
      Opt this profile into session list sharing: entries are copied between
      shared profiles so each one lists the same sessions. Only ever copies
      entries in - nothing is overwritten and nothing is deleted.

  .\mcd.ps1 unshare <name> | -All
      Stop syncing it. Entries already copied in stay put.

  .\mcd.ps1 sync-sessions
      Run one sync pass now. The tray does this on its own every few seconds.

  .\mcd.ps1 tray
      Tray icon: launch profiles and tick which ones share sessions.

  .\mcd.ps1 autostart [on|off|status]
      Start the tray icon at sign-in, via a shortcut in the Startup folder.

  .\mcd.ps1 icon [<name> <image> [-Full] | <name> -Clear]
      Give a profile its own icon - taskbar button, Alt-Tab and the tray
      menu. By default the image becomes a round badge on the corner of the
      Claude icon; -Full uses the image on its own. With no arguments, list
      what each profile uses.
      Equivalent to setting "icon" in profiles.json, which takes a path to any
      image (png, jpg, bmp, gif, ico); non-.ico files are converted and cached
      automatically, and reconverted whenever you edit the source image.

  .\mcd.ps1 open <name>       Open the profile's data directory in Explorer.
  .\mcd.ps1 remove <name> [-DeleteData] [-Force]
  .\mcd.ps1 where             Print the resolved claude.exe path.

Notes:
  - Sign in to each new profile once; after that both can run at the same time.
  - The 'default' profile is your existing %APPDATA%\Claude - it is untouched.
  - Session transcripts live in %USERPROFILE%\.claude and were always shared;
    'share' only joins up the per-account index that drives the session list.
  - Close a profile before sharing or unsharing it - the app holds that folder.
"@
}

# ------------------------------------------------------------------- main ---

# mcd-tray.ps1 dot-sources this file to reuse the functions above, so only run
# a command when we were actually invoked as a script.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        switch ($Command) {
            'list'        { Invoke-List }
            'add'         { Invoke-Add }
            'remove'      { Invoke-Remove }
            'launch'      { Invoke-Launch }
                'stamp'       { Invoke-Stamp }
            'sync-config' { Invoke-SyncConfig }
            'share'       { Invoke-Share }
            'unshare'     { Invoke-Unshare }
        'sync-sessions' { Invoke-SyncSessions }
            'tray'        { Invoke-Tray }
        'autostart'   { Invoke-Autostart }
        'icon'        { Invoke-Icon }
            'open'        { Invoke-Open }
            'where'       { Invoke-Where }
            default       { Invoke-Help }
        }
    } catch {
        Write-Err "Error: $($_.Exception.Message)"
        exit 1
    }
}
