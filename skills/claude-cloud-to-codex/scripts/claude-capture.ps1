#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('List','Capture','SelfTest')][string]$Mode = 'List',
    [long]$WindowHandle,
    [string]$OutDir,
    [int[]]$Region,
    [string]$ScrollName,
    [ValidateRange(1,50)][int]$Count = 1,
    [ValidateRange(0,600)][int]$IntervalSeconds = 0
)
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne 'Win32NT') { throw 'Use this capture helper on Windows.' }
Add-Type -AssemblyName System.Drawing
if (-not ('ClaudeWindowCapture' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class ClaudeWindowCapture {
    public delegate bool EnumProc(IntPtr w, IntPtr value);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc fn,IntPtr value);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr w);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr w);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr w, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr w,StringBuilder val,int max);
    [StructLayout(LayoutKind.Sequential)] public struct Rect {public int l,t,r,b;}
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr w,out Rect rect);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr w,IntPtr dc,uint flags);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);
    public static IntPtr[] Windows(){
        var windows=new List<IntPtr>();
        EnumWindows(delegate(IntPtr w,IntPtr arg){if(IsWindowVisible(w))windows.Add(w);return true;},IntPtr.Zero);
        return windows.ToArray();
    }
    public static int Owner(IntPtr w){uint pid;GetWindowThreadProcessId(w,out pid);return (int)pid;}
    public static string Caption(IntPtr w){var s=new StringBuilder(2048);GetWindowText(w,s,s.Capacity);return s.ToString();}
}
'@
}

function Get-ClaudeWindows {
    foreach ($w in [ClaudeWindowCapture]::Windows()) {
        $owner = [ClaudeWindowCapture]::Owner($w)
        $proc = Get-Process -Id $owner -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -ieq 'Claude') {
            $title = [ClaudeWindowCapture]::Caption($w)
            if ($title) { [pscustomobject]@{WindowHandle=$w.ToInt64(); ProcessId=$owner; Title=$title} }
        }
    }
}
function Get-PrivateDestination([string]$value) {
    if (![IO.Path]::IsPathRooted($value) -or $value -notmatch '^[A-Za-z]:[\\/]') {
        throw 'Select an absolute local output directory.'
    }
    $full = [IO.Path]::GetFullPath($value)
    if ($full.TrimEnd('\') -eq [IO.Path]::GetPathRoot($full).TrimEnd('\')) { throw 'Select a private subdirectory.' }
    for ($p=$full; $p; $p=[IO.Path]::GetDirectoryName($p)) {
        if (Test-Path -LiteralPath $p) {
            $d=Get-Item -Force -LiteralPath $p
            if (!$d.PSIsContainer -or ($d.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Unsuitable output directory: $p" }
        }
    }
    return $full
}
function Step-SelectedPane([IntPtr]$w,[int]$owner,[string]$name) {
    if ([ClaudeWindowCapture]::Owner($w) -ne $owner -or [ClaudeWindowCapture]::IsIconic($w)) {throw 'Window changed.'}
    Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
    $root=[Windows.Automation.AutomationElement]::FromHandle($w)
    $query=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,$name)
    $scrollable=@(foreach ($item in $root.FindAll([Windows.Automation.TreeScope]::Descendants,$query)) {
        $pattern=$null
        if (!$item.Current.IsOffscreen -and $item.TryGetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern,[ref]$pattern) -and $pattern.Current.VerticallyScrollable) { $pattern }
    })
    if ($scrollable.Count -ne 1) {throw 'Expected one visible scrolling pane with this exact accessibility name. Use single captures or manual turns.'}
    $sp=$scrollable[0]
    $before=$sp.Current.VerticalScrollPercent
    $view=$sp.Current.VerticalViewSize
    if ($before -ge 99.999 -or $view -ge 100) {return $false}
    if ($before -lt 0 -or $view -le 0) {throw 'No trustworthy scroll range.'}
    # Move 70% of a viewport, leaving an overlap to verify continuity.
    $next=[Math]::Min(100.0,$before+70.0*$view/(100.0-$view))
    $sp.SetScrollPercent(-1,$next)
    for ($i=0;$i -lt 15;$i++) {
        Start-Sleep -Milliseconds 120
        if ($sp.Current.VerticalScrollPercent -gt $before) {return $true}
    }
    throw 'The selected pane did not advance. Check the page before continuing.'
}
function Save-ClientImage([IntPtr]$w,[int]$owner,[int[]]$area,[string]$file) {
    if ([ClaudeWindowCapture]::Owner($w) -ne $owner -or ![ClaudeWindowCapture]::IsWindowVisible($w) -or [ClaudeWindowCapture]::IsIconic($w)) {
        throw 'The selected window changed, closed, or was minimized.'
    }
    $size = New-Object ClaudeWindowCapture+Rect
    if (![ClaudeWindowCapture]::GetClientRect($w,[ref]$size)) { throw 'No client rectangle.' }
    $width=$size.r-$size.l
    $height=$size.b-$size.t
    if ($width -lt 1 -or $height -lt 1 -or ([long]$width*$height) -gt 64000000) {throw 'Unexpected client dimensions.'}
    $rect = [Drawing.Rectangle]::new(0,0,$width,$height)
    if ($area -and $area.Length) {
        if ($area.Length -ne 4 -or $area[0] -lt 0 -or $area[1] -lt 0 -or $area[2] -lt 1 -or $area[3] -lt 1 -or
            ([long]$area[0]+$area[2]) -gt $width -or ([long]$area[1]+$area[3]) -gt $height) {
            throw "Region needs x,y,width,height inside the client area ($width x $height)."
        }
        $rect = [Drawing.Rectangle]::new($area[0],$area[1],$area[2],$area[3])
    }
    $frame=[Drawing.Bitmap]::new($width,$height,[Drawing.Imaging.PixelFormat]::Format24bppRgb)
    try {
        $g=[Drawing.Graphics]::FromImage($frame)
        try {
            $dc=$g.GetHdc()
            try { $ok=[ClaudeWindowCapture]::PrintWindow($w,$dc,3) } finally { $g.ReleaseHdc($dc) }
        } finally { $g.Dispose() }
        if (!$ok) {throw 'The application did not render the selected window.'}
        $image=$frame.Clone($rect,[Drawing.Imaging.PixelFormat]::Format24bppRgb)
        try {
            $baseColor=$image.GetPixel(0,0).ToArgb()
            $varied=$false
            for($y=0;$y -lt $image.Height -and !$varied;$y += [Math]::Max(1,[int]($image.Height/90))) {
                for($x=0;$x -lt $image.Width;$x += [Math]::Max(1,[int]($image.Width/90))) {
                    if ($image.GetPixel($x,$y).ToArgb() -ne $baseColor) {$varied=$true;break}
                }
            }
            if (!$varied) {throw 'Uniform image. Bring the page into view or use an explicitly selected manual region.'}
            $bytes=[IO.MemoryStream]::new()
            try {
                $image.Save($bytes,[Drawing.Imaging.ImageFormat]::Png)
                $bytes.Position=0
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file))
                $stream=[IO.File]::Open($file,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                try { $bytes.CopyTo($stream) } finally { $stream.Dispose() }
            } finally { $bytes.Dispose() }
        } finally { $image.Dispose() }
    } finally { $frame.Dispose() }
}

if ($Mode -eq 'List') {Get-ClaudeWindows; return}
$dpi = [ClaudeWindowCapture]::SetThreadDpiAwarenessContext([IntPtr](-4))
try {
    if ($Mode -eq 'SelfTest') {
        Add-Type -AssemblyName System.Windows.Forms
        $testPath=Join-Path ([IO.Path]::GetTempPath()) ("capture-fixture-"+[guid]::NewGuid().ToString('N')+".png")
        $form=New-Object Windows.Forms.Form
        try {
            $form.Text='Synthetic window capture fixture'
            $form.ShowInTaskbar=$false
            $form.StartPosition='Manual'
            $form.Location=[Drawing.Point]::new(-2000,-2000)
            $form.ClientSize=[Drawing.Size]::new(120,90)
            $form.BackColor=[Drawing.Color]::White
            $box=New-Object Windows.Forms.Panel
            $box.Location=[Drawing.Point]::new(10,10)
            $box.Size=[Drawing.Size]::new(25,25)
            $box.BackColor=[Drawing.Color]::Navy
            $form.Controls.Add($box)
            $form.Show()
            $form.Refresh()
            [Windows.Forms.Application]::DoEvents()
            Save-ClientImage $form.Handle $PID @(5,5,60,55) $testPath
            $pic=[Drawing.Bitmap]::FromFile($testPath)
            try {
                if ($pic.Width -ne 60 -or $pic.Height -ne 55 -or $pic.GetPixel(12,12).ToArgb() -ne [Drawing.Color]::Navy.ToArgb() -or $pic.GetPixel(54,50).ToArgb() -ne [Drawing.Color]::White.ToArgb()) {
                    throw 'Fixture dimensions or colored pixels differ.'
                }
            } finally { $pic.Dispose() }
            'PASS: selected fixture client area, region, PNG and pixels'
        } finally { $form.Dispose(); if ([IO.File]::Exists($testPath)) { [IO.File]::Delete($testPath) } }
        return
    }
    $match = @(Get-ClaudeWindows | Where-Object { $_.WindowHandle -eq $WindowHandle })
    if ($match.Count -ne 1) { throw 'Run -Mode List, select a visible Claude window and pass its decimal handle.' }
    $dest=Get-PrivateDestination $OutDir
    $batch=[guid]::NewGuid().ToString('N').Substring(0,12)
    $lastDigest=$null
    for($i=1;$i -le $Count;$i++){
        if ($i -gt 1) {
            if ($ScrollName) {
                if (!(Step-SelectedPane ([IntPtr]$WindowHandle) $match[0].ProcessId $ScrollName)) {break}
                Start-Sleep -Milliseconds 750
                if ($IntervalSeconds) {Start-Sleep -Seconds $IntervalSeconds}
            } elseif ($IntervalSeconds) {Start-Sleep -Seconds $IntervalSeconds}
            else { [void](Read-Host 'Turn to the next page in the same project, then press Enter (Ctrl+C to stop)') }
        }
        if ([ClaudeWindowCapture]::Caption([IntPtr]$WindowHandle) -cne $match[0].Title) {
            throw 'Window title changed. Verify the project and begin a new batch.'
        }
        $target=Join-Path $dest ('page-{0}-{1:d3}.png' -f $batch,$i)
        Save-ClientImage ([IntPtr]$WindowHandle) $match[0].ProcessId $Region $target
        $digest=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        if ($digest -eq $lastDigest) {Write-Warning 'Two consecutive captures match. Verify that the page advanced.'}
        $lastDigest=$digest
        Write-Output $target
    }
} finally { if ($dpi -ne [IntPtr]::Zero) { [void][ClaudeWindowCapture]::SetThreadDpiAwarenessContext($dpi) } }
