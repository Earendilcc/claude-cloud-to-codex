using namespace System.Windows.Automation
#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Inspect','Plan','Download','Adopt')][string]$Mode = 'Inspect',
    [long]$WindowHandle, [string]$Plan, [string]$Inbox, [string]$Manifest,
    [string[]]$Roots, [string]$CloudRoot = '/mnt/project-files',
    [string]$PublisherThumbprint, [string]$RelativePath, [string]$LocalFile
)
$ErrorActionPreference = 'Stop'
if (!$IsWindows) { throw 'The desktop adapter requires Windows and PowerShell 7.' }
function Full([string]$Value) {
    if (!$Value) { throw 'Missing required local path.' }
    $p = [IO.Path]::GetFullPath($Value)
    for ($a = $p; $a; $a = [IO.Path]::GetDirectoryName($a)) {
        try { $flags = [IO.File]::GetAttributes($a) }
        catch [IO.FileNotFoundException] { continue }
        catch [IO.DirectoryNotFoundException] { continue }
        if ($flags -band [IO.FileAttributes]::ReparsePoint) { throw "Linked local path: $a" }
    }
    $p
}
function Check-Key([string]$Key) {
    foreach ($s in $Key.Split('/')) {
        if (!$s -or $s -match '[<>:"\\|?*\x00-\x1f]|[. ]$|^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|(?:COM|LPT)[1-9¹²³]) *(?:\.|$)') {
            throw "Unsafe relative key: $Key"
        }
    }
}
function Save-Json($Value, $Path, [bool]$Replace) {
    $p = Full $Path
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($p))
    $temp = Join-Path ([IO.Path]::GetDirectoryName($p)) ('.writing-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temp, $p, $Replace)
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
function Load-Json($Path) { Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable }
function Digest($Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Verify-Plan($p) {
    if ($p.version -ne 1 -or !$p.cloudRoot -or $p.cloudRoot -notmatch '^/(?:[^/\\]+/)*[^/\\]+$' -or
            $p.files -isnot [Array] -or $p.directories -isnot [Array] -or !$p.windowTitle -or !$p.projectDocument) { throw 'Invalid desktop plan.' }
    Check-Key $p.cloudRoot.Substring(1)
    $seen = @{}
    foreach ($kind in @('directories','files')) {
        foreach ($item in $p[$kind]) {
            if ($item -isnot [string]) { throw 'Expected relative path string.' }
            Check-Key $item
            $k = $item.Normalize()
            if ($seen.ContainsKey($k)) { throw "Ambiguous plan entry: $item" }
            $seen[$k] = $kind
        }
    }
    foreach ($item in $seen.Keys) {
        $anc = ($item -split '/')
        for ($i=1; $i -lt $anc.Count; $i++) {
            $parent = $anc[0..($i-1)] -join '/'
            if ($seen[$parent] -eq 'files') { throw "File used as directory: $parent" }
        }
    }
}

if ($Mode -ne 'Adopt') {
    Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
    if (!('ClaudeCloudFileWin' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class ClaudeCloudFileWin {
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hwnd, uint cmd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll", EntryPoint="PostMessageW")] public static extern bool Post(IntPtr hwnd,uint msg,IntPtr w,IntPtr l);
    [DllImport("user32.dll", EntryPoint="SendMessageTimeoutW", CharSet=CharSet.Unicode)]
    static extern IntPtr Read(IntPtr h,uint msg,IntPtr w,StringBuilder l,uint flags,uint ms,out IntPtr r);
    [DllImport("user32.dll", EntryPoint="SendMessageTimeoutW")]
    static extern IntPtr Number(IntPtr h,uint msg,IntPtr w,IntPtr l,uint flags,uint ms,out IntPtr r);
    [DllImport("user32.dll", EntryPoint="SendMessageTimeoutW", CharSet=CharSet.Unicode)]
    static extern IntPtr Write(IntPtr h,uint msg,IntPtr w,string l,uint flags,uint ms,out IntPtr r);
    public static string Text(IntPtr h) {
        var b=new StringBuilder(32768); IntPtr r;
        if(Read(h,13,(IntPtr)b.Capacity,b,2,2000,out r)==IntPtr.Zero) throw new Exception("Filename control not responding");
        return b.ToString();
    }
    public static void SetFilename(IntPtr h,string value) {
        IntPtr r;
        if(Number(h,0xB1,IntPtr.Zero,(IntPtr)(-1),2,2000,out r)==IntPtr.Zero ||
           Write(h,0xC2,IntPtr.Zero,value,2,2000,out r)==IntPtr.Zero || Text(h)!=value)
            throw new Exception("Filename control refused the selected path");
    }
}
'@
    }
}
function ByType($el, $type) {
    $c = [PropertyCondition]::new([AutomationElement]::ControlTypeProperty,$type)
    $el.FindAll([TreeScope]::Descendants,$c)
}
function Rows {
    foreach ($el in (ByType $window ([ControlType]::TreeItem))) {
        $id = $el.Current.AutomationId
        if (!$id -or !$id.StartsWith('overview-library-row-', [StringComparison]::Ordinal)) { continue }
        $key = [uri]::UnescapeDataString($id.Substring('overview-library-row-'.Length))
        $pat = $null
        if ($el.TryGetCurrentPattern([ExpandCollapsePattern]::Pattern,[ref]$pat)) {
            [pscustomobject]@{Key=$key; State=[string]$pat.Current.ExpandCollapseState; UI=$el}
        }
    }
}
function File-Scroller {
    $row = @(Rows | Select-Object -First 1)
    if (!$row.Count) { return }
    $el=$row[0].UI
    while ($null -ne $el -and !$el.Equals($window)) {
        $pat=$null
        if ($el.TryGetCurrentPattern([ScrollPattern]::Pattern,[ref]$pat) -and $pat.Current.VerticallyScrollable) { return $pat }
        $el = [TreeWalker]::ControlViewWalker.GetParent($el)
    }
}
function Project-Document {
    $first=@(Rows | Select-Object -First 1)
    if ($first.Count) {
        $el=$first[0].UI
        while ($el -and !$el.Equals($window)) {
            if ($el.Current.ControlType -eq [ControlType]::Document -and $el.Current.Name) { return $el.Current.Name }
            $el=[TreeWalker]::ControlViewWalker.GetParent($el)
        }
    }
    throw 'Cannot identify the project document above the visible file tree. Open the project context/files tab.'
}
function Ensure-ProjectTree([string]$ExpectedDocument) {
    if (@(Rows | Select-Object -First 1).Count -eq 0) {
        $docs=@(ByType $window ([ControlType]::Document) | Where-Object { $_.Current.Name -ceq $ExpectedDocument })
        if ($docs.Count -ne 1) { throw 'Return to the original project context tab, then rerun Download.' }
        $tabs=@(ByType $docs[0] ([ControlType]::TabItem) | Where-Object { $_.Current.Name -cin @('上下文','Context') })
        if ($tabs.Count -ne 1) { throw 'Select the visible file tree in the original project before resuming.' }
        $tabs[0].GetCurrentPattern([SelectionItemPattern]::Pattern).Select()
        $null=Wait-Value { @(Rows | Select-Object -First 1).Count -gt 0 } 5 'File tree did not return.'
    }
    if ((Project-Document) -cne $ExpectedDocument) { throw 'The active project document changed.' }
}
function Start-Scan {
    $s=File-Scroller
    if ($s) { $s.SetScrollPercent(-1,0); Start-Sleep -Milliseconds 200 }
    return $s
}
function Next-Page($scroll) {
    if (!$scroll -or $scroll.Current.VerticalScrollPercent -ge 99.99) { return $false }
    $before=$scroll.Current.VerticalScrollPercent
    $scroll.Scroll([ScrollAmount]::NoAmount,[ScrollAmount]::LargeIncrement)
    Start-Sleep -Milliseconds 200
    if ($scroll.Current.VerticalScrollPercent -le $before) { throw 'Scrolling did not advance; scroll manually and retry.' }
    return $true
}
function Find-Row($key) {
    $hits=@(Rows | Where-Object { $_.Key -ceq $key })
    if (!$hits.Count) {
        $scroll=Start-Scan
        for ($i=0; $i -lt 400; $i++) {
            $hits=@(Rows | Where-Object { $_.Key -ceq $key })
            if ($hits.Count -or !(Next-Page $scroll)) { break }
        }
    }
    if ($hits.Count -ne 1) { throw "Cannot uniquely locate exact visible row '$key'. Expand/scroll the tree and resume." }
    $row=$hits[0]
    if ($row.State -ne 'LeafNode') { throw "Expected a file row: $key" }
    $pat=$null
    if ($row.UI.TryGetCurrentPattern([ScrollItemPattern]::Pattern,[ref]$pat)) { $pat.ScrollIntoView() }
    return $row.UI
}
function In-Scope($key) {
    foreach ($r in $Roots) {
        if ($key -ceq $r -or $key.StartsWith($r+'/',[StringComparison]::Ordinal)) { return $true }
    }
    return $false
}
function Make-Plan {
    if (!$Roots -or !$Plan) { throw 'Plan requires -Roots and -Plan.' }
    foreach ($r in $Roots) { Check-Key $r }
    $last=$null; $lastExpansion=$null
    for ($pass=0; $pass -lt 100; $pass++) {
        $dirs=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $files=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $expansion=$false
        $scroll=Start-Scan
        for ($page=0; ; $page++) {
            if ($page -ge 400) { throw 'No confirmed end of file list.' }
            foreach ($row in @(Rows)) {
                if (!(In-Scope $row.Key)) { continue }
                Check-Key $row.Key
                if ($row.State -eq 'LeafNode') { [void]$files.Add($row.Key); continue }
                [void]$dirs.Add($row.Key)
                if ($row.State -eq 'Collapsed') {
                    if ($lastExpansion -ceq $row.Key) { throw "Expand '$($row.Key)' by hand and restart Plan; UIA expansion had no effect." }
                    $lastExpansion=$row.Key
                    $row.UI.GetCurrentPattern([ExpandCollapsePattern]::Pattern).Expand()
                    $expansion=$true; Start-Sleep -Milliseconds 350; break
                }
                if ($row.State -ne 'Expanded') { throw "Unreadable folder state: $($row.Key)" }
            }
            if ($expansion -or !(Next-Page $scroll)) { break }
        }
        if ($expansion) { continue }
        foreach ($r in $Roots) { if (!$dirs.Contains($r) -and !$files.Contains($r)) { throw "Selected file or directory not found: $r" } }
        $p=[ordered]@{version=1;windowTitle=$window.Current.Name;projectDocument=Project-Document;cloudRoot=$CloudRoot.TrimEnd('/');
            directories=@($dirs | Sort-Object -CaseSensitive); files=@($files | Sort-Object -CaseSensitive)}
        Verify-Plan $p
        $fingerprint=$p | ConvertTo-Json -Depth 5 -Compress
        if ($last -ceq $fingerprint) { Save-Json $p $Plan $false; Write-Host "Plan: $($files.Count) files, $($dirs.Count) directories. Review against the source tree."; return }
        $last=$fingerprint; Start-Sleep -Milliseconds 400
    }
    throw 'File inventory did not stabilize. Split the selection or inspect the tree.'
}
function Wait-Value([scriptblock]$Read, [int]$Seconds, $Reason) {
    $end=[datetime]::UtcNow.AddSeconds($Seconds)
    do { $v=& $Read; if ($v) { return $v }; Start-Sleep -Milliseconds 150 } until ([datetime]::UtcNow -gt $end)
    throw $Reason
}
function Save-Window {
    $cond=[PropertyCondition]::new([AutomationElement]::ClassNameProperty,'#32770')
    $found=@{}
    foreach ($candidate in @($window.FindAll([TreeScope]::Descendants,$cond)) + @([AutomationElement]::RootElement.FindAll([TreeScope]::Children,$cond))) {
        if ($candidate.Current.Name -notin '另存为','另存為','Save As') { continue }
        $h=[IntPtr]$candidate.Current.NativeWindowHandle
        for ($depth=0; $h -and $depth -lt 12; $depth++) {
            if ($h.ToInt64() -eq $WindowHandle) { $found[$candidate.Current.NativeWindowHandle]=$candidate; break }
            $h=[ClaudeCloudFileWin]::GetWindow($h,4)
        }
    }
    if ($found.Count -gt 1) { throw 'Multiple Save As windows belong to the selected window.' }
    if ($found.Count -eq 1) { return @($found.Values)[0] }
}
function Row-Menu($key,$labels) {
    if (Save-Window) { throw 'Finish the pending Claude Save As dialog before continuing.' }
    $existing=@(ByType $window ([ControlType]::MenuItem) | Where-Object { $_.Current.Name -cin $labels })
    if ($existing) { throw 'Close the already-open context menu, then retry.' }
    $row=Find-Row $key
    $leaf=($key -split '/')[-1]
    $actions=@(ByType $row ([ControlType]::Button) | Where-Object {
        $_.Current.Name -cin @("$leaf 的操作","$leaf 的操作選單","Actions for $leaf","Actions for $leaf.", "More actions for $leaf")
    })
    if ($actions.Count -ne 1) { throw "No unique row-local action button for '$key'." }
    $actions[0].GetCurrentPattern([ExpandCollapsePattern]::Pattern).Expand()
    $item=Wait-Value {
        $hits=@(ByType $window ([ControlType]::MenuItem) | Where-Object { $_.Current.Name -cin $labels })
        if ($hits.Count -gt 1) { throw 'Ambiguous file menu.' }
        if ($hits.Count) { $hits[0] }
    } 5 "Expected menu entry for '$key'."
    $item.GetCurrentPattern([InvokePattern]::Pattern).Invoke()
}
function Download-One($key, $target) {
    Ensure-ProjectTree $scope.projectDocument
    $names=@('无法下载此文件。','無法下載此檔案。','Unable to download this file.','Could not download this file.')
    foreach ($name in $names) {
        $cond=[PropertyCondition]::new([AutomationElement]::NameProperty,$name)
        if ($window.FindFirst([TreeScope]::Descendants,$cond)) { throw 'Dismiss the previous download error before retrying.' }
    }
    $seq=[ClaudeCloudFileWin]::GetClipboardSequenceNumber()
    Row-Menu $key @('复制路径','複製路徑','Copy path','Copy Path')
    $expected=$scope.cloudRoot+'/'+$key
    $copied=Wait-Value {
        if ([ClaudeCloudFileWin]::GetClipboardSequenceNumber() -ne $seq) { Get-Clipboard -Raw }
    } 5 'Copy path did not update the clipboard.'
    if ([string]$copied -cne $expected) { throw "Copied cloud path differs from the plan for '$key'. Verify the project and source root." }
    Start-Sleep -Milliseconds 150
    Row-Menu $key @('下载','下載','Download')
    Receive-Save $key $target $names
}
function Receive-Save($key,$target,$names) {
    $dialog=Wait-Value {
        $d=Save-Window
        if ($d) { return $d }
        foreach ($name in $names) {
            $cond=[PropertyCondition]::new([AutomationElement]::NameProperty,$name)
            if ($window.FindFirst([TreeScope]::Descendants,$cond)) { return 'unavailable' }
        }
    } 15 'No owned Save As dialog appeared. Check for a canceled request or a direct download; use Adopt if needed.'
    if ($dialog -is [string]) {
        if ($dialog -ne 'unavailable') { throw 'Unknown download state.' }
        $null=Wait-Value {
            foreach ($name in $names) {
                $cond=[PropertyCondition]::new([AutomationElement]::NameProperty,$name)
                if ($window.FindFirst([TreeScope]::Descendants,$cond)) { return $false }
            }
            return $true
        } 12 'Dismiss the download error and resume.'
        return $false
    }
    $null=Wait-Value {
        $cond=[PropertyCondition]::new([AutomationElement]::AutomationIdProperty,'FileNameControlHost')
        $dialog.FindFirst([TreeScope]::Descendants,$cond)
    } 5 'Save As did not finish loading its filename field.'
    $controls=@($dialog.FindAll([TreeScope]::Descendants,[Condition]::TrueCondition))
    $hosts=@($controls | Where-Object { $_.Current.AutomationId -ceq 'FileNameControlHost' })
    if ($hosts.Count -ne 1) { throw 'Unrecognized filename control in Save As.' }
    $edits=@($hosts[0].FindAll([TreeScope]::Descendants,[Condition]::TrueCondition) | Where-Object {
        $_.Current.ClassName -ceq 'Edit' -and $_.Current.NativeWindowHandle })
    $buttons=@($controls | Where-Object { $_.Current.AutomationId -ceq '1' -and $_.Current.ClassName -ceq 'Button' -and
        $_.Current.Name -match '^(Save|保存|儲存)(\s*\(&?S\))?$' -and $_.Current.IsEnabled })
    if ($edits.Count -ne 1 -or $buttons.Count -ne 1) { throw 'Cannot identify the filename and Save controls.' }
    $leaf=($key -split '/')[-1]; $edit=[IntPtr]$edits[0].Current.NativeWindowHandle
    $stem=[regex]::Escape([IO.Path]::GetFileNameWithoutExtension($leaf))
    $extension=[regex]::Escape([IO.Path]::GetExtension($leaf))
    if ([ClaudeCloudFileWin]::Text($edit) -cnotmatch ('^'+$stem+'(?: \(\d+\))?(?:'+$extension+')?$')) { throw "Unexpected suggested filename for '$key'." }
    [ClaudeCloudFileWin]::SetFilename($edit,$target)
    $pat=$null
    if ($buttons[0].TryGetCurrentPattern([InvokePattern]::Pattern,[ref]$pat)) { $pat.Invoke() }
    elseif (![ClaudeCloudFileWin]::Post([IntPtr]$buttons[0].Current.NativeWindowHandle,0xF5,[IntPtr]::Zero,[IntPtr]::Zero)) { throw 'Could not activate the validated Save button.' }
    $h=[IntPtr]$dialog.Current.NativeWindowHandle
    $last=$null; $end=[datetime]::UtcNow.AddSeconds(60)
    do {
        if (![ClaudeCloudFileWin]::IsWindow($h) -and [IO.File]::Exists($target)) {
            $fi=[IO.FileInfo]::new((Full $target))
            $stamp="$($fi.Length)/$($fi.LastWriteTimeUtc.Ticks)"
            if ($stamp -ceq $last) {
                try { $stream=[IO.File]::Open($target,'Open','Read','None'); $stream.Dispose(); return $true }
                catch [IO.IOException] { }
            }
            $last=$stamp
        }
        Start-Sleep -Milliseconds 300
    } until ([datetime]::UtcNow -gt $end)
    throw "Save canceled or not completed: '$key'. Resume with the same plan."
}

if ($MyInvocation.InvocationName -eq '.') { return } # Allows isolated tests to supply a synthetic file tree.
if ($Mode -ne 'Adopt') {
    if ($Mode -eq 'Inspect' -and !$WindowHandle) {
        $wins=@(Get-Process -Name Claude -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })
        $wins | Select-Object @{n='WindowHandle';e={$_.MainWindowHandle.ToInt64()}},MainWindowTitle,Path
        return
    }
    [uint32]$ownerProcess=0
    [void][ClaudeCloudFileWin]::GetWindowThreadProcessId([IntPtr]$WindowHandle,[ref]$ownerProcess)
    $matches=@(Get-Process -Id $ownerProcess -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -ieq 'Claude' -and $_.MainWindowHandle.ToInt64() -eq $WindowHandle })
    if ($matches.Count -ne 1) { throw 'Select one running Claude window using Inspect.' }
    $exe=$matches[0].Path
    if ($PublisherThumbprint) {
        $sig=Get-AuthenticodeSignature -LiteralPath $exe
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Thumbprint -ne $PublisherThumbprint) { throw 'Publisher signature check failed.' }
    }
    $window=[AutomationElement]::FromHandle([IntPtr]$WindowHandle)
    if ($Mode -eq 'Inspect') {
        Write-Host "Window: $($window.Current.Name). Document: $(Project-Document)"
        Rows | Where-Object { !$Roots -or (In-Scope $_.Key) } | Select-Object Key,State; return
    }
    if ($Mode -eq 'Plan') { Make-Plan; return }
}
$planPath=Full $Plan; $inboxRoot=Full $Inbox; $mapPath=Full $Manifest
$lockPath=Full ($mapPath+'.lock'); $scopePath=Full ($mapPath+'.scope.json')
$distinct=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($stateFile in @($planPath,$mapPath,$scopePath,$lockPath)) {
    if (!$distinct.Add($stateFile) -or $stateFile -ieq $inboxRoot -or
        $stateFile.StartsWith($inboxRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or
        $inboxRoot.StartsWith($stateFile+'\',[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Keep plan, manifest, scope and lock at distinct file paths outside the inbox.'
    }
}
$scope=Load-Json $planPath; Verify-Plan $scope
if ($Mode -eq 'Download' -and $window.Current.Name -cne $scope.windowTitle) { throw 'Selected window title differs from the reviewed plan.' }
if ($Mode -eq 'Adopt') {
    if ($scope.files -cnotcontains $RelativePath) { throw 'Adopt requires an exact planned relative path.' }
    $manual=Full $LocalFile
    if (![IO.File]::Exists($manual)) { throw 'Missing manually downloaded file.' }
}
[void][IO.Directory]::CreateDirectory($inboxRoot)
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($mapPath))
$lock=[IO.FileStream]::new($lockPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None,1,[IO.FileOptions]::DeleteOnClose)
try {
    $expectedHash=Digest $planPath
    if ([IO.File]::Exists($scopePath)) {
        $binding=Load-Json $scopePath
        if ($binding.planSHA256 -cne $expectedHash -or $binding.inbox -ine $inboxRoot) { throw 'Checkpoint belongs to another plan or inbox.' }
    } else {
        if ([IO.File]::Exists($mapPath)) { throw 'Existing restore map has no matching checkpoint.' }
        Save-Json @{planSHA256=$expectedHash;inbox=$inboxRoot} $scopePath $false
    }
    $map=if ([IO.File]::Exists($mapPath)) { Load-Json $mapPath } else {
        [ordered]@{version=1; directories=@($scope.directories); files=@()}
    }
    if ($map.version -ne 1 -or $map.files -isnot [Array] -or $map.directories -isnot [Array] -or
            (($map.directories | ConvertTo-Json -Compress) -cne ($scope.directories | ConvertTo-Json -Compress))) { throw 'Unexpected checkpoint structure.' }
    $done=@{}
    foreach ($entry in $map.files) {
        if ($scope.files -cnotcontains $entry.path -or $done.ContainsKey($entry.path)) { throw 'Unexpected or duplicate checkpoint entry.' }
        Check-Key $entry.download
        $stored=Full (Join-Path $inboxRoot $entry.download)
        if (![IO.File]::Exists($stored) -or (Get-Item -LiteralPath $stored).Length -ne $entry.bytes -or (Digest $stored) -cne $entry.sha256) { throw "Checkpoint verification failed: $($entry.path)" }
        $done[$entry.path]=$true
    }
    if (![IO.File]::Exists($mapPath)) { Save-Json $map $mapPath $false }
    $work=if ($Mode -eq 'Adopt') { @($RelativePath) } else { @($scope.files) }
    foreach ($key in $work) {
        if ($done.ContainsKey($key)) { continue }
        $sub=[guid]::NewGuid().ToString('N')
        $localKey=$sub+'/'+($key -split '/')[-1]
        $target=Full (Join-Path $inboxRoot $localKey)
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        if ($Mode -eq 'Adopt') {
            $hash=Digest $manual
            [IO.File]::Copy($manual,$target,$false)
            if ((Digest $target) -cne $hash) { throw 'Manual download changed during copy.' }
        } elseif (!(Download-One $key $target)) {
            [IO.Directory]::Delete([IO.Path]::GetDirectoryName($target),$false)
            Write-Warning "Claude reported an unavailable file: $key"; continue
        }
        $map.files=@($map.files)+@([ordered]@{path=$key;download=$localKey;bytes=(Get-Item -LiteralPath $target).Length;sha256=Digest $target})
        Save-Json $map $mapPath $true
        $done[$key]=$true
        Write-Host "Verified $key"
    }
    $missing=@($scope.files | Where-Object { !$done.ContainsKey($_) })
    Write-Host "Verified $($done.Count)/$($scope.files.Count) planned files. Map: $mapPath"
    if ($missing) {
        Write-Warning ('Outstanding: '+($missing -join ', '))
        if ($Mode -eq 'Download') { exit 2 }
    }
} finally { $lock.Dispose() }
