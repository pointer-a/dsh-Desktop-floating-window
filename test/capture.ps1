# capture.ps1 - crop the on-screen region of a titled window into a PNG (visual QA helper).
#
# Finds windows with EnumWindows (more reliable than Process.MainWindowHandle: the mini box
# uses ShowInTaskbar=False), matches the title substring, and grabs the smallest match.
#
# Usage: powershell -File test/capture.ps1 -Out <abs png path> [-TitleLike 'DeepSeek']
param(
  [Parameter(Mandatory = $true)][string]$Out,
  [string]$TitleLike = 'DeepSeek'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public struct RECT { public int Left, Top, Right, Bottom; }

public static class MbCap {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();

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
[MbCap]::SetProcessDPIAware() | Out-Null

$candidates = @()
foreach ($hWnd in [MbCap]::Find($TitleLike)) {
  $rect = New-Object RECT
  if (-not [MbCap]::GetWindowRect($hWnd, [ref]$rect)) { continue }
  $w = $rect.Right - $rect.Left
  $h = $rect.Bottom - $rect.Top
  if ($w -lt 80 -or $h -lt 20) { continue }
  $procId = 0
  [void][MbCap]::GetWindowThreadProcessId($hWnd, [ref]$procId)
  $candidates += [pscustomobject]@{ Handle = $hWnd; Rect = $rect; Width = $w; Height = $h; Pid = $procId }
}
if ($candidates.Count -eq 0) {
  Write-Output 'NO_WINDOW'
  exit 2
}
$target = $candidates | Sort-Object { $_.Width * $_.Height } | Select-Object -First 1
$bmp = New-Object System.Drawing.Bitmap $target.Width, $target.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($target.Rect.Left, $target.Rect.Top, 0, 0, $bmp.Size)
$dir = Split-Path -Parent $Out
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose()
$bmp.Dispose()
Write-Output ("OK pid={0} rect={1},{2} {3}x{4} candidates={5} -> {6}" -f $target.Pid, $target.Rect.Left, $target.Rect.Top, $target.Width, $target.Height, $candidates.Count, $Out)
