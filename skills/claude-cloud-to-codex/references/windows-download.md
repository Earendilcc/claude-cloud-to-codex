# Windows 桌面端批量下载云项目文件

[claude-download.ps1](../scripts/claude-download.ps1) 面向 Claude 桌面端的项目文件树。选定目录后，脚本枚举其文件，逐个操作文件行的菜单，接收客户端返回的原件并生成 [离线恢复命令](claude-desktop.md) 可直接使用的清单。对话、记忆和聊天附件另走各自的入口。

## 准备

- 使用 Windows、PowerShell 7（`pwsh`）和当前交互式登录桌面。让 Claude 打开正确项目的「上下文」或文件页，关闭已有的菜单和保存框。让 Claude 保持可见。脚本不需要开通 Claude 对话额度。
- 首先在用户授权的桌面会话运行。Codex 的文件沙箱可能无法看到真实窗口或系统剪贴板，此时为这次 Claude 窗口自动化和私有工作目录申请宿主允许的桌面操作权限。以 Claude 窗口相同的普通用户身份运行即可。没有桌面权限或环境禁止 shell 操作桌面时，使用该宿主允许的桌面控制能力，或让用户在自己的 PowerShell 运行这些命令。离线文件恢复本身无需桌面权限。
- 准备一个用户专用、只在本机的暂存目录。下面的命令从已安装的 skill 根目录运行。将脚本路径和工作目录换成自己的值。先在一个小目录验证本机的界面版本和语言。执行期间会用“复制路径”改写剪贴板，暂时避免其他复制和下载操作。
- 脚本只识别进程名 Claude 的主窗口。Inspect 会显示本机程序路径和窗口句柄；根据画面确定目标。对需要校验发行者的环境，可以在可信渠道核实证书后，向 Inspect、Plan 和 Download 传入 `-PublisherThumbprint <指纹>`，脚本会检查签名状态和指纹。

```powershell
$tool = './scripts/claude-download.ps1'
$private = Join-Path ([IO.Path]::GetTempPath()) ('cloud-recovery-' + [guid]::NewGuid())
$plan = Join-Path $private 'selected.json'
$map = Join-Path $private 'verified.json'
$inbox = Join-Path $private 'downloads'
& $tool -Mode Inspect
```

## 枚举与核对

把上一步显示的十进制窗口句柄填入 `$hwnd`。第二次 Inspect 仅检查所选窗口中可访问的云文件树，并显示窗口标题、文件树所属项目文档及路径。它们是检查用户所选项目的重要依据。文件名的中文或空格原样保留。

```powershell
$hwnd = 123456    # 换成当前会话中 Inspect 显示并核实的值
& $tool -Mode Inspect -WindowHandle $hwnd
& $tool -Mode Plan -WindowHandle $hwnd -Roots @('sample-dev','sample-transfer') -Plan $plan
Get-Content -Raw -LiteralPath $plan
```

也可只选择树中一个完整相对文件名，如 `-Roots @('sample-dev/tests/check.txt')`，或把文件和目录混选。使用独立的 `-Plan` 文件名，不覆盖另一批任务的计划。

`-Roots` 为 UI 树内的完整相对目录，大小写敏感。默认云前缀是 `/mnt/project-files`；如果菜单「复制路径」显示其他根，给 Plan 加 `-CloudRoot '/实际云根'`。递归展开只发生在选中目录；对于支持 UI Automation 的可滚动树，脚本按页扫描，只有连续两次看到相同清单才输出。若某个目录的 Expand 操作无效，请在当前项目点开提示的那个目录后重新生成。滚动、折叠、懒加载、权限差异都可能使一个稳定清单依然有缺口。核对项目、目录、文件数量及能确认的最深层示例，必要时分段滚动、缩小 `-Roots` 或据已核实的完整云路径整理计划。Plan 不覆盖已有文件，可为修订计划指定新文件名。

可手写同格式的计划以迁移已明确点名的文件。云前缀、文档名、窗口标题和行内相对路径均须与本机当前窗口匹配。以下值为虚构示例。

```json
{
  "version": 1,
  "windowTitle": "Claude",
  "projectDocument": "Sample workspace - Claude Code",
  "cloudRoot": "/mnt/project-files",
  "directories": ["sample-dev", "sample-dev/empty"],
  "files": ["sample-dev/check.txt"]
}
```

## 单个试跑与批量执行

单文件试跑可用独立的小计划、暂存区及清单；回到完整计划后仍使用其自身的暂存区。Download 只在对应名称的项目文档中工作。文件树行需要有携带完整相对路径的 UIA 标识（本适配器识别 `overview-library-row-`），行内菜单需要提供「复制路径」和「下载」。脚本验证剪贴板得到了本次复制的 `cloudRoot/相对路径`，重新定位同一路径的行，才选中它的下载项。相同文件名可以出现在不同子目录。窗口标题、语义控件或行不唯一时会停止。

```powershell
& $tool -Mode Download -WindowHandle $hwnd -Plan $plan -Inbox $inbox -Manifest $map
```

支持由所选 Claude 窗口拥有的 Windows 原生“另存为”。脚本确认建议文件名（允许隐藏扩展名及系统生成的同名编号）、原生文件名编辑框与保存按钮，把本次文件存为私有暂存区中 `随机目录/原文件名`。每项均等候实际文件可独占读取且大小和写入时间稳定，计算字节数与 SHA-256 后，原子更新恢复清单。无需为同名文件猜测对应关系。本地哈希可验证后续复制；若发布方提供大小或校验和，应另外比对。

- 正常返回并显示全部核验后，使用 `restore_files.py` 先预检再复原。如果部署环境仅提供 PowerShell 宿主而无 Python，可转到有 Python 的受信任机器进行离线恢复。
- 明确遇到「无法下载此文件」会等待该提示消失，跳过该项并处理独立文件。结束时有缺项会列出路径，Download 的退出码为 2。遇到取消、未知对话框、复制结果不匹配、超时或无法唯一定位行会立即停止，本轮此前已核验的项目留在清单中。
- 点击取消后，先关闭弹框，检查浏览器/桌面客户端的可见下载记录或暂存区。重新执行相同 Download 命令，已完成项会先重新核验哈希再跳过。客户端重启需要重新 Inspect，使用新窗口句柄。暂存区中的孤立未登记文件只作为待人工核对项；脚本不会按同名自动接纳。
- 如果当前 Claude 版本直接保存到 Downloads、无原生另存为弹框，或普通菜单文字/可访问控件发生变化，Download 会提示停止。在可见下载记录确认该文件确切的源云路径、实际下载完成和本机文件，再用 Adopt 补入。Adopt 不操作窗口。不要把同名新版代指旧版失效附件，也不要将不完整的下载文件补入。
- 保持 `selected.json`、`verified.json`、相邻的 `.scope.json` 和暂存区作为同一组。绑定记录用于防止误用另一项目的检查点；若需要变更计划或切换源项目，使用新的一组临时路径。两个进程不能同时更新同一份清单。

```powershell
& $tool -Mode Adopt -Plan $plan -Inbox $inbox -Manifest $map `
  -RelativePath 'sample-dev/check.txt' -LocalFile 'C:\private-downloads\reviewed-copy.txt'
python scripts/restore_files.py --manifest $map --inbox $inbox --dest .\recovered
python scripts/restore_files.py --manifest $map --inbox $inbox --dest .\recovered --apply
```

`verified.json` 只列已取得字节的文件。离线恢复成功并不代表云端计划全部完成。将 `selected.json` 的文件路径集合与 `verified.json` 的 `files[].path` 对照，分别报告已取回、失效、取消和待人工补项。保留用户要求的目标项目结果；验收后按用户要求清理本任务暂存区。
