# window-control.ps1 - find a titled window and send it WM_CLOSE (dev helper for the mini box).
# Usage: powershell -File test/window-control.ps1 [-TitleLike 'DeepSeek'] [-Close]
param(
  [string]$TitleLike = 'DeepSeek',
  [switch]$Close,
  [switch]$Focus
)
$ErrorActionPreference = 'Stop'
Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class MbWinCtl {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  public struct RECT { public int Left, Top, Right, Bottom; }

  public static List<IntPtr> Find(string titleLike) {
    var found = new List<IntPtr>();
    EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
      if (!IsWindowVisible(hWnd)) return true;
      var sb = new StringBuilder(512);
      GetWindowTextW(hWnd, sb, sb.Capacity);
      var title = sb.ToString();
      if (title.Length > 0 && title.IndexOf(titleLike, StringComparison.OrdinalIgnoreCase) >= 0) found.Add(hWnd);
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
"@
$candidates = @()
foreach ($hWnd in [MbWinCtl]::Find($TitleLike)) {
  $rect = New-Object MbWinCtl+RECT
  if (-not [MbWinCtl]::GetWindowRect($hWnd, [ref]$rect)) { continue }
  $w = $rect.Right - $rect.Left
  $h = $rect.Bottom - $rect.Top
  if ($w -lt 80 -or $h -lt 20) { continue }
  $procId = 0
  [void][MbWinCtl]::GetWindowThreadProcessId($hWnd, [ref]$procId)
  $candidates += [pscustomobject]@{ Handle = $hWnd; W = $w; H = $h; Pid = $procId }
}
if ($candidates.Count -eq 0) { Write-Output 'NO_WINDOW'; exit 2 }
$target = $candidates | Sort-Object { $_.W * $_.H } | Select-Object -First 1
if ($Focus) {
  [void][MbWinCtl]::ShowWindow($target.Handle, 9)
  [void][MbWinCtl]::SetForegroundWindow($target.Handle)
  Write-Output ("FOCUSED pid={0} {1}x{2}" -f $target.Pid, $target.W, $target.H)
  exit 0
}
if ($Close) {
  # WM_CLOSE = 0x0010
  [void][MbWinCtl]::PostMessageW($target.Handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
  Write-Output ("WM_CLOSE sent pid={0} {1}x{2}" -f $target.Pid, $target.W, $target.H)
  exit 0
}
Write-Output ("FOUND pid={0} {1}x{2} candidates={3}" -f $target.Pid, $target.W, $target.H, $candidates.Count)
