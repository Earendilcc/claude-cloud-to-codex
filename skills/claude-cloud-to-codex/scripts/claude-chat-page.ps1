#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$SelfTest,
    [long]$WindowHandle,
    [string]$WindowTitle,
    [string]$ThreadHeaderName,
    [ValidateSet('ToolBar','Header','Group','Pane')][string]$ThreadHeaderType='ToolBar',
    [string]$ThreadPaneName,
    [ValidateSet('Group','Pane')][string]$ThreadPaneType='Pane',
    [string]$ContainerName,
    [ValidateSet('List','Group','Pane')][string]$ContainerType='List',
    [string]$RowPrefix,
    [string]$OutputPath
)
$ErrorActionPreference = 'Stop'

function Get-OutputFile([string]$value) {
    if ($value -notmatch '^[A-Za-z]:[\\/]' -or [IO.Path]::GetExtension($value) -ine '.json' -or $value.Substring(2).Contains(':')) {
        throw 'Use an absolute local .json file path in an existing private folder.'
    }
    $file = [IO.Path]::GetFullPath($value)
    $dir = [IO.Path]::GetDirectoryName($file)
    if ($dir -ieq [IO.Path]::GetPathRoot($dir) -or ![IO.Directory]::Exists($dir)) {throw 'Select a dedicated, existing private folder.'}
    if ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($file)).DriveType -eq [IO.DriveType]::Network) {throw 'Use a private local drive.'}
    for ($ancestor=$dir; $ancestor; $ancestor=[IO.Path]::GetDirectoryName($ancestor)) {
        if ([IO.File]::GetAttributes($ancestor) -band [IO.FileAttributes]::ReparsePoint) {throw 'Linked output directories are not supported.'}
    }
    if (Test-Path -LiteralPath $file) {throw 'Destination already exists.'}
    return $file
}
function Write-NewJson($file, $payload) {
    $file=Get-OutputFile $file
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($payload | ConvertTo-Json -Depth 12))
    $tmp=Join-Path ([IO.Path]::GetDirectoryName($file)) ('.page-'+[guid]::NewGuid().ToString('N')+'.tmp')
    $stream=[IO.File]::Open($tmp,'CreateNew','Write','None')
    try {
        try {$stream.Write($bytes,0,$bytes.Length)} finally {$stream.Dispose()}
        [IO.File]::Move($tmp,$file)
    } finally {if ([IO.File]::Exists($tmp)) {[IO.File]::Delete($tmp)}}
}
function Row-Number([string]$name, [string]$prefix) {
    if (!$name.StartsWith($prefix,[StringComparison]::Ordinal)) {return $null}
    $tail=$name.Substring($prefix.Length)
    if ($tail -notmatch '^[0-9]+$') {return $null}
    return $tail
}
function Public-Link([string]$value) {
    $uri=$null
    if ([uri]::TryCreate($value,[UriKind]::Absolute,[ref]$uri) -and $uri.Scheme -in 'https','http' -and !$uri.UserInfo) {return $value}
}
function Walk-Page($node,$scope,$row,$context) {
    if (++$context.visits -gt 24000) {throw 'Accessibility tree is unusually large. Choose a narrower message container.'}
    $info=& $context.describe $node $scope
    if (!$info -or !$info.visible -or $info.protected -or $info.type -in 'Edit','ComboBox','Document','Window','Menu','MenuItem') {return}
    if ($info.type -in 'ListItem','DataItem','Group','Pane','Custom') {
        $ordinal=Row-Number $info.name $context.prefix
        if ($null -ne $ordinal) {
            if ($row -or $context.seen.ContainsKey($ordinal)) {throw 'Ambiguous nested or duplicate visible message label.'}
            $context.seen[$ordinal]=$true
            $row=[ordered]@{label=$info.name; visibleNumber=$ordinal; fragments=[Collections.Generic.List[object]]::new()}
            $context.rows.Add($row)
        }
    }
    if ($row -and $info.type -in 'Text','Hyperlink' -and $info.name) {
        $fragment=[ordered]@{type=$info.type; name=$info.name}
        if ($info.type -eq 'Hyperlink') {
            $url=Public-Link $info.url
            if ($url) {$fragment.url=$url}
        }
        $row.fragments.Add($fragment)
    }
    foreach ($item in (& $context.children $node)) {Walk-Page $item $scope $row $context}
}
function Read-Rows($container,$scope,$prefix,$describe,$children) {
    $context=@{prefix=$prefix;describe=$describe;children=$children;rows=[Collections.Generic.List[object]]::new();seen=@{};visits=0}
    foreach ($item in (& $children $container)) {Walk-Page $item $scope $null $context}
    if (!$context.rows.Count) {throw 'No visible numbered message rows in the selected container.'}
    if (@($context.rows | Where-Object { !$_.fragments.Count }).Count) {
        throw 'A visible message row has no readable text or links. Check its actual UI controls or collect this page manually.'
    }
    return $context.rows.ToArray()
}
if ([Environment]::OSVersion.Platform -ne 'Win32NT') {throw 'This helper is for Windows.'}
if ($SelfTest) {
    # Synthetic accessibility data. This branch does not inspect applications.
    $text=@{type='Text';name='Hello';visible=$true}
    $link=@{type='Hyperlink';name='Details';url='https://example.invalid/view';visible=$true}
    $hidden=@{type='Text';name='Hidden';visible=$false}
    $edit=@{type='Edit';name='Draft';visible=$true;nodes=@($text)}
    $password=@{type='Group';name='Protected';visible=$true;protected=$true;nodes=@($text)}
    $record=@{type='Group';name='Row 3';visible=$true;nodes=@($text,$link,$hidden,$edit,$password)}
    $root=@{nodes=@($record)}
    $rows=@(Read-Rows $root $null 'Row ' {param($n,$s) $n} {param($n) $n.nodes})
    if ($rows.Count -ne 1 -or $rows[0].visibleNumber -cne '3' -or $rows[0].fragments.Count -ne 2 -or $rows[0].fragments[1].url -ne $link.url) {throw 'Fixture row filtering failed.'}
    if (Public-Link 'file:///C:/hidden') {throw 'Unexpected private URI.'}
    $testFile=Join-Path ([IO.Path]::GetTempPath()) ('synthetic-chat-page-'+[guid]::NewGuid().ToString('N')+'.json')
    try {
        Write-NewJson $testFile @{rows=$rows}
        $rejected=$false
        try {Write-NewJson $testFile @{}} catch {$rejected=$_.Exception.Message -eq 'Destination already exists.'}
        if (!$rejected -or (([IO.File]::ReadAllText($testFile) | ConvertFrom-Json).rows.Count -ne 1)) {throw 'Fixture write protection failed.'}
    } finally {if ([IO.File]::Exists($testFile)) {[IO.File]::Delete($testFile)}}
    'PASS: synthetic visible rows, links, hidden/edit/protected exclusions and no-overwrite JSON.'
    return
}
foreach ($value in $WindowTitle,$ThreadHeaderName,$ContainerName,$RowPrefix,$OutputPath) {
    if ([string]::IsNullOrWhiteSpace($value)) {throw 'Supply all exact window, thread header, message container, row prefix and private output selectors.'}
}
if ($WindowHandle -le 0) {throw 'Supply the previously verified decimal handle of the authorized Claude window.'}
$file=Get-OutputFile $OutputPath
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,WindowsBase
if (!('ClaudeChatPageWindow' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ClaudeChatPageWindow {
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr w, uint flags);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr w, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr w);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr w);
}
'@
}
$w=[IntPtr]$WindowHandle
$walker=[Windows.Automation.TreeWalker]::ControlViewWalker
function Current-Window {
    if ([ClaudeChatPageWindow]::GetAncestor($w,2) -ne $w -or ![ClaudeChatPageWindow]::IsWindowVisible($w) -or [ClaudeChatPageWindow]::IsIconic($w)) {throw 'Expected a visible, restored top-level window.'}
    [uint32]$owner=0
    [void][ClaudeChatPageWindow]::GetWindowThreadProcessId($w,[ref]$owner)
    if ((Get-Process -Id $owner -ErrorAction Stop).ProcessName -ine 'Claude') {throw 'The given window is not owned by Claude.'}
    $root=[Windows.Automation.AutomationElement]::FromHandle($w)
    if ($root.Current.Name -cne $WindowTitle) {throw 'The exact window title changed.'}
    return $root
}
function Unique-Visible($parent,[string]$name,[string]$type) {
    $cond=[Windows.Automation.AndCondition]::new(
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,$name),
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::$type),
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::IsOffscreenProperty,$false))
    $hits=@($parent.FindAll([Windows.Automation.TreeScope]::Descendants,$cond) | Where-Object {
        $r=$_.Current.BoundingRectangle
        !$_.Current.IsPassword -and $r.Width -gt 0 -and $r.Height -gt 0 -and $parent.Current.BoundingRectangle.IntersectsWith($r)
    })
    if ($hits.Count -ne 1) {throw 'Cannot uniquely match a visible thread header or message container. Verify the current UI or collect this page manually.'}
    return $hits[0]
}
$describe={
    param($e,$scope)
    $cur=$e.Current
    $type=$cur.ControlType.ProgrammaticName.Split('.')[-1]
    $r=$cur.BoundingRectangle
    if ($cur.IsPassword -or $cur.IsOffscreen -or $r.Width -le 0 -or $r.Height -le 0 -or !$scope.IntersectsWith($r) -or $type -in 'Edit','ComboBox','Document','Window','Menu','MenuItem') {return}
    $value=$null
    if ($e.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern,[ref]$value) -and !$value.Current.IsReadOnly) {return}
    $url=$null
    if ($type -eq 'Hyperlink') {
        if ($value) {$url=$value.Current.Value}
        if (!$url) {$url=$cur.Name}
    }
    return @{visible=$true; protected=$false; type=$type; name=$cur.Name; url=$url}
}
$children={
    param($parent)
    $e=$walker.GetFirstChild($parent)
    while ($e) {$e; $e=$walker.GetNextSibling($e)}
}
function Current-Page {
    $root=Current-Window
    $thread=$root
    if ($ThreadPaneName) {$thread=Unique-Visible $root $ThreadPaneName $ThreadPaneType}
    $header=Unique-Visible $thread $ThreadHeaderName $ThreadHeaderType
    $pane=Unique-Visible $thread $ContainerName $ContainerType
    if (!$ThreadPaneName) {
        $headerParent=$walker.GetParent($header)
        $paneParent=$walker.GetParent($pane)
        if (!$headerParent -or !$paneParent -or ![Windows.Automation.Automation]::Compare($headerParent,$paneParent)) {
            throw 'Header and messages are not verified siblings. Supply the exact thread-specific pane containing both.'
        }
    }
    $scope=[Windows.Rect]::Intersect($root.Current.BoundingRectangle,$pane.Current.BoundingRectangle)
    if ($scope.IsEmpty) {throw 'Selected container is outside the window.'}
    $rows=@(Read-Rows $pane $scope $RowPrefix $describe $children)
    return [ordered]@{headerRuntime=($header.GetRuntimeId() -join '.');paneRuntime=($pane.GetRuntimeId() -join '.');rows=$rows}
}
$first=Current-Page
$second=Current-Page
if (($first | ConvertTo-Json -Depth 10 -Compress) -cne ($second | ConvertTo-Json -Depth 10 -Compress)) {throw 'Visible messages or selected thread changed while reading. Wait for a stable page and retry.'}
Write-NewJson $file ([ordered]@{schema='claude-visible-page/v1';source='rendered-accessibility-text';header=$ThreadHeaderName;container=$ContainerName;capturedUtc=[DateTime]::UtcNow.ToString('o');rows=$first.rows})
Write-Output ('Saved {0} visible rows to {1}' -f $first.rows.Count,$file)
