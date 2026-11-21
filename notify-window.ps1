param(
  [string]$B64Title = '',
  [string]$B64Body = '',
  [switch]$OnlyWhenAway
)

# Always-on-top, borderless completion card in the bottom-right corner.
# Independent of the Windows notification switch, which is off on this machine.
# Every completion gets its own card: up to three stack upward, each closes on
# its own click. A slot mutex decides the vertical position, so no IPC is needed.

$ErrorActionPreference = 'Stop'

function Decode([string]$b64, [string]$fallback) {
  if ([string]::IsNullOrWhiteSpace($b64)) { return $fallback }
  try { return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) }
  catch { return $fallback }
}

$title = Decode $B64Title '任务完成'
$body = Decode $B64Body '这一轮已经跑完了。点击卡片关闭。'

# Opt-in only: suppress while DSH itself is the foreground window.
if ($OnlyWhenAway) {
  try {
    Add-Type -Namespace Win32 -Name FgW -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
'@
    $hwnd = [Win32.FgW]::GetForegroundWindow()
    $ownerPid = 0
    [Win32.FgW]::GetWindowThreadProcessId($hwnd, [ref]$ownerPid) | Out-Null
    $fgName = ''
    if ($ownerPid -gt 0) {
      try { $fgName = (Get-Process -Id $ownerPid -ErrorAction Stop).ProcessName } catch { $fgName = '' }
    }
    foreach ($needle in @('dpharness', 'dsh', 'deepseek')) {
      if ($fgName -and $fgName.ToLower().Contains($needle)) { exit 0 }
    }
  } catch {
    # A foreground probe failure must not suppress the card.
  }
}

$cardLog = Join-Path $env:TEMP 'dsh-turn-notify\card.log'
function Write-CardLog([string]$line) {
  try { Add-Content -LiteralPath $cardLog -Value ((Get-Date).ToString('o') + ' ' + $line) -Encoding UTF8 } catch { }
}

# Claim the lowest free slot: 0 is nearest the corner, 2 is highest.
$slot = -1
$slotMutex = $null
for ($i = 0; $i -lt 3; $i++) {
  try {
    $candidate = New-Object System.Threading.Mutex($false, "Global\dsh-turn-notify-slot-$i")
    if ($candidate.WaitOne(0)) {
      $slot = $i
      $slotMutex = $candidate
      break
    }
    $candidate.Dispose()
  } catch {
    # A mutex failure must not prevent the card.
    $slot = $i
    break
  }
}
if ($slot -lt 0) { exit 0 }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$cardSource = @"
using System;
using System.Windows.Forms;
public class NotifyCard : Form {
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE: never steal focus
            cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW: keep out of Alt+Tab
            return cp;
        }
    }
}
"@
Add-Type -TypeDefinition $cardSource -ReferencedAssemblies @('System.Windows.Forms', 'System.Drawing')

$bg = [System.Drawing.Color]::FromArgb(27, 26, 44)
$fg = [System.Drawing.Color]::FromArgb(232, 230, 245)
$muted = [System.Drawing.Color]::FromArgb(160, 156, 190)
$accent = [System.Drawing.Color]::FromArgb(157, 107, 231)
$border = [System.Drawing.Color]::FromArgb(74, 68, 106)

function Get-UiFont([float]$size, [bool]$bold) {
  foreach ($name in @('Microsoft YaHei UI', 'Microsoft YaHei', 'Segoe UI')) {
    try {
      $style = if ($bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
      return New-Object System.Drawing.Font($name, $size, $style)
    } catch { }
  }
  return New-Object System.Drawing.Font('Arial', $size)
}

$card = New-Object NotifyCard
$card.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$card.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$card.TopMost = $true
$card.ShowInTaskbar = $false
$card.BackColor = $bg
$card.Width = 396
$card.Height = 132

# Always anchor to the PRIMARY screen: Screen.FromPoint(Cursor.Position) can
# resolve to a virtual display driver (Oray, GameViewer, ...) that the user
# cannot see, which silently renders the card off-screen.
$area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$card.Left = $area.Right - $card.Width - 20
$card.Top = $area.Bottom - $card.Height - 20 - ($slot * ($card.Height + 10))

$bar = New-Object System.Windows.Forms.Panel
$bar.BackColor = $accent
$bar.SetBounds(0, 0, 4, $card.Height)
$card.Controls.Add($bar)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = $title
$titleLabel.ForeColor = $fg
$titleLabel.Font = Get-UiFont 11.5 $true
$titleLabel.AutoEllipsis = $true
$titleLabel.SetBounds(22, 16, 320, 26)
$card.Controls.Add($titleLabel)

$bodyLabel = New-Object System.Windows.Forms.Label
$bodyLabel.Text = $body
$bodyLabel.ForeColor = $muted
$bodyLabel.Font = Get-UiFont 9.5 $false
$bodyLabel.AutoEllipsis = $true
$bodyLabel.SetBounds(22, 48, 348, 46)
$card.Controls.Add($bodyLabel)

$close = New-Object System.Windows.Forms.Label
$close.Text = '✕'
$close.ForeColor = $muted
$close.Font = Get-UiFont 10 $false
$close.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$close.Cursor = [System.Windows.Forms.Cursors]::Hand
$close.SetBounds($card.Width - 40, 12, 26, 26)
$card.Controls.Add($close)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = 'DeepSeek Harness'
$hint.ForeColor = [System.Drawing.Color]::FromArgb(110, 106, 140)
$hint.Font = Get-UiFont 8.5 $false
$hint.SetBounds(22, $card.Height - 30, 200, 20)
$card.Controls.Add($hint)

$close.Add_MouseEnter({ $close.ForeColor = $fg })
$close.Add_MouseLeave({ $close.ForeColor = $muted })

$dismiss = {
  param($sender, $e)
  $card.Close()
}
$card.Add_Click($dismiss)
$titleLabel.Add_Click($dismiss)
$bodyLabel.Add_Click($dismiss)
$close.Add_Click($dismiss)
$hint.Add_Click($dismiss)

$card.Add_Paint({
  param($sender, $e)
  $pen = New-Object System.Drawing.Pen($border, 1)
  $e.Graphics.DrawRectangle($pen, 0, 0, $sender.Width - 1, $sender.Height - 1)
  $pen.Dispose()
})

$card.Add_Shown({ Write-CardLog ("shown: slot=$slot bounds=$($card.Bounds)") })


try {
  [System.Windows.Forms.Application]::Run($card)
  Write-CardLog ("run returned: visible=$($card.Visible) disposed=$($card.IsDisposed)")
} catch {
  Write-CardLog ('run failed: ' + $_.Exception.Message)
} finally {
  if ($slotMutex -ne $null) {
    try { $slotMutex.ReleaseMutex(); $slotMutex.Dispose() } catch { }
  }
  Write-CardLog ("slot $slot closed")
}
