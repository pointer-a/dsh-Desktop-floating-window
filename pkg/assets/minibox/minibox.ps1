#requires -version 5.1
<#
  minibox.ps1 — dsh-taskbox 桌面小窗（独立进程）

  PowerShell 5.1 + WPF（.NET Framework 4.8，Windows 自带，无第三方依赖）。
  不 import 任何 DSH 代码，只按 docs/PROTOCOL.md（v1 + v1.1 增补）通过 HTTP 读写 Host：
    GET  /state    每 1000ms 轮询，超时 800ms
    POST /action   回答确认 / 聚焦会话 / 打开主窗 / 关闭
    POST /window   ready / moved / collapsed

  拉起方式（由 Host 负责）：
    powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -WindowStyle Hidden `
      -File minibox.ps1 -Port <port> -Token <token> -AssetDir "<dir>"

  -Theme auto|dark|light 仅供开发和截图用（默认 auto = 跟随系统 AppsUseLightTheme）。

  作者：minibox-ui（dsh-taskbox 小窗半区）
#>

[CmdletBinding()]
param(
  [int]$Port = 0,
  [string]$Token = '',
  [string]$AssetDir = '',
  [ValidateSet('auto', 'dark', 'light')][string]$Theme = 'auto'
)

$script:Version = '1.1.0'
$script:ExpandedHeight = 360
$script:CollapsedHeight = 44
$script:BaseWidth = 320
$script:PollMs = 1000
$script:HttpTimeoutMs = 800

$script:Port = $Port
$script:Token = $Token
$script:AssetDir = $AssetDir

# 参数校验：缺失时给 stderr 明确报错 + 非 0 退出码（Host 从日志/退出码排障）
if ($Port -le 0 -or $Port -gt 65535) {
  [Console]::Error.WriteLine("minibox: 缺少或非法的 -Port（收到 '$Port'）。用法: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File minibox.ps1 -Port <port> -Token <token> -AssetDir <dir>")
  [Environment]::Exit(2)
}
if (-not $Token) {
  [Console]::Error.WriteLine('minibox: 缺少 -Token（Host 每次拉起都必须带 x-taskbox-token）。')
  [Environment]::Exit(2)
}

# ---------------------------------------------------------------------------
# 0. 进程级初始化：DPI 感知必须先于任何窗口创建
# ---------------------------------------------------------------------------

$nativeSrc = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class MbNative
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT pt, uint flags);
    [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr hmon, int dpiType, out uint dpiX, out uint dpiY);

    // 某个物理点所在显示器的有效 DPI（125% → 120）；失败退回系统 DPI
    public static uint GetDpiForPoint(int x, int y)
    {
        try
        {
            POINT pt; pt.X = x; pt.Y = y;
            IntPtr mon = MonitorFromPoint(pt, 2); // MONITOR_DEFAULTTONEAREST
            if (mon != IntPtr.Zero)
            {
                uint dx, dy;
                if (GetDpiForMonitor(mon, 0, out dx, out dy) == 0 && dx > 0) return dx;
            }
        }
        catch { }
        try { return GetDpiForSystem(); } catch { return 96; }
    }

    [DllImport("user32.dll", SetLastError = true)] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("shcore.dll", SetLastError = true)] public static extern int SetProcessDpiAwareness(int v);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);

    // 在指定进程里找「主窗口」：优先可见未最小化、有标题的非工具窗口；
    // 主程序最小化到托盘（窗口隐藏）时，仍返回隐藏窗口句柄供 ShowWindow 恢复。
    public static IntPtr FindAppWindow(uint[] pids)
    {
        IntPtr best = IntPtr.Zero;
        IntPtr any = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr l)
        {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            bool match = false;
            for (int i = 0; i < pids.Length; i++) { if (pids[i] == pid) { match = true; break; } }
            if (!match) return true;
            if (GetWindowTextLength(h) == 0) return true;
            int ex = GetWindowLong(h, -20);            // GWL_EXSTYLE
            if ((ex & 0x00000080) != 0) return true;   // WS_EX_TOOLWINDOW
            if (IsWindowVisible(h))
            {
                if (best == IntPtr.Zero) best = h;
                if (!IsIconic(h)) { best = h; return false; }
            }
            else if (any == IntPtr.Zero) { any = h; }
            return true;
        }, IntPtr.Zero);
        if (best != IntPtr.Zero) return best;
        return any;
    }
}
'@

if (-not ('MbNative' -as [type])) {
  try { Add-Type -TypeDefinition $nativeSrc -Language CSharp -ErrorAction Stop } catch {
    Write-Output "minibox: Add-Type failed: $($_.Exception.Message)"
  }
}

# PER_MONITOR_AWARE_V2 (-4)，失败再退 DPI_AWARE(2)、System Aware
$dpiOk = $false
if ('MbNative' -as [type]) {
  try { $dpiOk = [MbNative]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { $dpiOk = $false }
  if (-not $dpiOk) { try { $dpiOk = ([MbNative]::SetProcessDpiAwareness(2) -eq 0) } catch { $dpiOk = $false } }
  if (-not $dpiOk) { try { $dpiOk = [MbNative]::SetProcessDPIAware() } catch { $dpiOk = $false } }
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$script:Dpi = 96
if ('MbNative' -as [type]) {
  try { $d = [MbNative]::GetDpiForSystem(); if ($d -gt 0) { $script:Dpi = [double]$d } } catch { }
}
$script:Scale = [double]$script:Dpi / 96.0
if ($script:Scale -le 0.1) { $script:Scale = 1.0 }

# ---------------------------------------------------------------------------
# 1. 日志（只写 Host 约定的 task-box 目录，三级回退）
# ---------------------------------------------------------------------------

function NowMs { return [long]([DateTime]::UtcNow.Ticks / 10000) }

$script:LogPath = ''
try {
  $candidates = @()
  if ($env:DSH_HOME) { $candidates += (Join-Path $env:DSH_HOME 'task-box') }
  if ($env:USERPROFILE) { $candidates += (Join-Path (Join-Path $env:USERPROFILE '.dsh') 'task-box') }
  if ($env:TEMP) { $candidates += (Join-Path $env:TEMP 'dsh-taskbox') }
  foreach ($dir in $candidates) {
    try {
      if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop }
      $probe = Join-Path $dir '.write-test'
      [System.IO.File]::WriteAllText($probe, 'ok')
      Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
      $script:LogPath = Join-Path $dir 'minibox.log'
      break
    } catch { }
  }
  if ($script:LogPath -and (Test-Path -LiteralPath $script:LogPath) -and ((Get-Item -LiteralPath $script:LogPath).Length -gt 256KB)) {
    Remove-Item -LiteralPath $script:LogPath -Force -ErrorAction SilentlyContinue
  }
} catch { $script:LogPath = '' }

# 日志落点写到 stderr 第一行（Host 排障用）
[Console]::Error.WriteLine("minibox: log file: $(if ($script:LogPath) { $script:LogPath } else { '(unavailable)' })")

function Log([string]$msg) {
  if (-not $script:LogPath) { return }
  try {
    $line = '{0:yyyy-MM-dd HH:mm:ss.fff} [{1}] {2}' -f (Get-Date), $script:Version, $msg
    [System.IO.File]::AppendAllText($script:LogPath, $line + "`r`n", [System.Text.UTF8Encoding]::new($false))
  } catch { }
}

Log "boot: port=$Port dpi=$($script:Dpi) scale=$($script:Scale) theme=$Theme dpiOk=$dpiOk ps=$($PSVersionTable.PSVersion) assetDir=$AssetDir"

# ---------------------------------------------------------------------------
# 2. 主题
# ---------------------------------------------------------------------------

function Get-SystemUsesLight {
  try {
    $v = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' `
      -Name 'AppsUseLightTheme' -ErrorAction Stop
    return ([int]$v.AppsUseLightTheme -ne 0)
  } catch { return $false }
}

$script:IsLight = switch ($Theme) {
  'light' { $true }
  'dark' { $false }
  default { Get-SystemUsesLight }
}

function New-ThemeTable([bool]$light) {
  if (-not $light) {
    # 近黑面板，97% 不透明；层次只靠极低对比的白色叠加
    return @{
      PanelBg       = '#F71B1B1C'
      PanelBorder   = '#14FFFFFF'
      AskPanelBg    = '#0AFFFFFF'
      CardBg        = '#0CFFFFFF'
      CardBorder    = '#16FFFFFF'
      CodeBg        = '#40000000'
      CodeText      = '#F4F5F7'
      CodeBorder    = 'Transparent'
      Divider       = '#12FFFFFF'
      TextPrimary   = '#F4F5F7'
      TextSecondary = '#9EA0A6'
      TextTertiary  = '#71717A'
      OnAccent      = '#FFFFFF'
      RowHover      = '#0BFFFFFF'
      WaitingRowBg  = '#14F5A623'
      Surface       = '#0FFFFFFF'
      SurfaceHover  = '#1AFFFFFF'
      Brand         = '#2B7FFF'
      BrandHover    = '#4A93FF'
      BrandSoft     = '#1F2B7FFF'
      Waiting       = '#F5A623'
      WaitingSoft   = '#1FF5A623'
      Danger        = '#F07C7C'
      DangerGhost   = '#33F07C7C'
      DangerHoverBg = '#14F07C7C'
      DangerSoft    = '#1FFF6B6B'
      Idle          = '#8A8A8E'
      Icon          = '#A0A0A8'
      IconHover     = '#F4F5F7'
      IconHoverBg   = '#14FFFFFF'
      ScrollThumb   = '#2EFFFFFF'
    }
  }
  return @{
    # 浅色底板纯不透明：避免透出后面窗口文字（深色仍 0.97）
    PanelBg       = '#F7F8FA'
    PanelBorder   = '#1A000000'
    AskPanelBg    = '#F4F5F7'
    CardBg        = '#FFFFFFFF'
    CardBorder    = '#14000000'
    CodeBg        = '#F1F3F6'
    CodeText      = '#111827'
    CodeBorder    = '#0F000000'
    Divider       = '#0F000000'
    TextPrimary   = '#17181B'
    TextSecondary = '#4B5563'
    TextTertiary  = '#6B7280'
    OnAccent      = '#FFFFFF'
    RowHover      = '#08000000'
    WaitingRowBg  = '#1AF5A623'
    Surface       = '#F1F2F4'
    SurfaceHover  = '#E6E9ED'
    Brand         = '#2B7FFF'
    BrandHover    = '#1F6FEF'
    BrandSoft     = '#142B7FFF'
    Waiting       = '#A56410'
    WaitingSoft   = '#1FF5A623'
    Danger        = '#C9343A'
    DangerGhost   = '#33C9343A'
    DangerHoverBg = '#14C9343A'
    DangerSoft    = '#14D93B42'
    Idle          = '#9AA0A6'
    Icon          = '#5E6470'
    IconHover     = '#17181B'
    IconHoverBg   = '#0A000000'
    ScrollThumb   = '#29000000'
  }
}

$script:Th = New-ThemeTable $script:IsLight

$script:BrushCache = @{}
function BrHex([string]$hex) {
  if (-not $hex) { return [System.Windows.Media.Brushes]::Transparent }
  if ($hex -ne 'Transparent') {
    $key = $hex.ToUpperInvariant()
    if ($script:BrushCache.ContainsKey($key)) { return $script:BrushCache[$key] }
  }
  try {
    if ($hex -eq 'Transparent') { return [System.Windows.Media.Brushes]::Transparent }
    $c = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
    $b = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]$c)
    $b.Freeze()
    $script:BrushCache[$key] = $b
    return $b
  } catch {
    return [System.Windows.Media.Brushes]::Transparent
  }
}
function Br([string]$key) { return (BrHex $script:Th[$key]) }

# 同色降透明度（chip 分隔符 60%）
function BrAlpha([string]$hex, [double]$alpha) {
  try {
    $c = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
    $a = [byte]([Math]::Round(255 * $alpha))
    $c2 = [System.Windows.Media.Color]::FromArgb($a, $c.R, $c.G, $c.B)
    $b = [System.Windows.Media.SolidColorBrush]::new($c2)
    $b.Freeze()
    return $b
  } catch { return (BrHex $hex) }
}

function Safe-Str($v, [string]$def = '') {
  if ($null -eq $v) { return $def }
  if ($v -is [string]) { return $v }
  if ($v -is [bool]) { if ($v) { return 'true' } else { return $def } }
  try { return [string]$v } catch { return $def }
}
function Safe-Num($v, [double]$def = 0) {
  if ($null -eq $v) { return $def }
  if ($v -is [bool]) { return $def }
  try { return [double]$v } catch { return $def }
}

# ---------------------------------------------------------------------------
# 3. XAML 外壳
# ---------------------------------------------------------------------------

$uiFont = 'Segoe UI Variable Text, Microsoft YaHei UI, Segoe UI'
$numFont = 'Segoe UI Variable Display, Segoe UI'

$xamlTemplate = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DeepSeek 任务"
        Width="320" Height="360"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        ShowActivated="False" WindowStartupLocation="Manual"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        FontFamily="%UiFont%" FontSize="12"
        TextOptions.TextFormattingMode="Ideal"
        TextOptions.TextRenderingMode="Grayscale">
  <Window.Resources>
    <Style TargetType="{x:Type ScrollBar}">
      <Setter Property="Width" Value="4"/>
      <Setter Property="MinWidth" Value="4"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type ScrollBar}">
            <Grid Background="Transparent" Width="4">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="{x:Type Thumb}">
                        <Border CornerRadius="2" Background="%ScrollThumb%" Margin="0,1"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border x:Name="Shell" CornerRadius="14" BorderThickness="1"
          Background="%PanelBg%" BorderBrush="%PanelBorder%">
    <Grid x:Name="Root">
      <Grid.RowDefinitions>
        <RowDefinition Height="44"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- 标题栏 -->
      <Grid x:Name="TitleBar" Grid.Row="0" Margin="14,0,8,0" Background="Transparent">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Ellipse x:Name="Dot" Width="7" Height="7" Fill="%Idle%" VerticalAlignment="Center" Margin="0,0,9,0"/>
        <TextBlock x:Name="TitleText" Grid.Column="1" Text="任务" FontSize="13" FontWeight="SemiBold"
                   Foreground="%TextPrimary%" VerticalAlignment="Center"/>
        <TextBlock x:Name="CountsText" Grid.Column="2" Text="" FontSize="11" Foreground="%TextSecondary%"
                   VerticalAlignment="Center" Margin="8,1,4,0" HorizontalAlignment="Left" MaxWidth="182"
                   TextTrimming="CharacterEllipsis"/>
        <Border x:Name="BtnMain" Grid.Column="3" Width="26" Height="26" CornerRadius="6" Background="Transparent"
                VerticalAlignment="Center" Margin="0,0,2,0" Cursor="Hand" ToolTip="打开 DeepSeek Harness">
          <Path x:Name="IconMain" HorizontalAlignment="Center" VerticalAlignment="Center"
                Data="M5.4,10.6 L10.6,5.4 M6.4,5.0 L10.6,5.0 L10.6,9.2"
                Stroke="%Icon%" StrokeThickness="1.35"
                StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
        </Border>
        <Border x:Name="BtnClose" Grid.Column="4" Width="26" Height="26" CornerRadius="6" Background="Transparent"
                VerticalAlignment="Center" Cursor="Hand" ToolTip="关闭小窗">
          <Path x:Name="IconClose" HorizontalAlignment="Center" VerticalAlignment="Center"
                Data="M4.9,4.9 L11.1,11.1 M11.1,4.9 L4.9,11.1"
                Stroke="%Icon%" StrokeThickness="1.35"
                StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
        </Border>
      </Grid>

      <!-- 离线提示 -->
      <Border x:Name="OfflineBar" Grid.Row="1" Margin="10,0,10,4" Padding="10,5" CornerRadius="8"
              Background="%WaitingSoft%" Visibility="Collapsed">
        <StackPanel Orientation="Horizontal">
          <Ellipse Width="5" Height="5" Fill="%Waiting%" VerticalAlignment="Center" Margin="0,0,7,0"/>
          <TextBlock Text="连接中断，正在重试…" FontSize="10.5" Foreground="%Waiting%" VerticalAlignment="Center"/>
        </StackPanel>
      </Border>

      <!-- 会话列表 -->
      <Grid Grid.Row="2">
        <ScrollViewer x:Name="ListScroll" VerticalScrollBarVisibility="Auto"
                      HorizontalScrollBarVisibility="Disabled" Focusable="False"
                      Padding="0,0,2,0">
          <StackPanel x:Name="ListPanel" Margin="8,0,8,6"/>
        </ScrollViewer>
        <StackPanel x:Name="EmptyBox" VerticalAlignment="Center" HorizontalAlignment="Center"
                    Visibility="Collapsed" Margin="0,0,0,12">
          <TextBlock Text="暂无对话" FontSize="12.5" Foreground="%TextSecondary%" HorizontalAlignment="Center"/>
          <TextBlock Text="DeepSeek Harness 没有正在运行的任务" FontSize="10.5" Foreground="%TextTertiary%"
                     Margin="0,6,0,0" HorizontalAlignment="Center"/>
        </StackPanel>
      </Grid>

      <!-- 待确认面板：贴底停靠，与列表之间 1px 分隔线 -->
      <StackPanel x:Name="AskHost" Grid.Row="3" Visibility="Collapsed" Margin="1,0,1,1">
        <Border x:Name="AskDivider" Height="1" Background="%Divider%"/>
        <Border x:Name="AskCard" Background="%AskPanelBg%" Padding="14,12,14,14"
                CornerRadius="0,0,13,13" MaxHeight="244">
          <StackPanel x:Name="AskBody"/>
        </Border>
      </StackPanel>

      <!-- 底栏（toast / notice） -->
      <Border x:Name="FootBar" Grid.Row="4" Padding="14,0,14,9" Visibility="Collapsed" Background="Transparent">
        <TextBlock x:Name="FootText" Text="" FontSize="10.5" Foreground="%Danger%"
                   TextTrimming="CharacterEllipsis" TextWrapping="NoWrap"/>
      </Border>

      <!-- 折叠 + 有待确认时的琥珀呼吸描边 -->
      <Border x:Name="PulseRing" CornerRadius="14" BorderThickness="1" BorderBrush="%Waiting%"
              IsHitTestVisible="False" Visibility="Collapsed" Opacity="0" Grid.RowSpan="5"/>
    </Grid>
  </Border>
</Window>
'@

$xaml = $xamlTemplate
$xaml = $xaml.Replace('%UiFont%', $uiFont).Replace('%NumFont%', $numFont)
foreach ($k in $script:Th.Keys) { $xaml = $xaml.Replace('%' + $k + '%', [string]$script:Th[$k]) }

$window = $null
try {
  $window = [System.Windows.Markup.XamlReader]::Parse($xaml)
} catch {
  Log "fatal: xaml parse failed: $($_.Exception.Message)"
  Write-Output "minibox: xaml parse failed: $($_.Exception.Message)"
  [Environment]::Exit(3)
}

$script:ui = @{}
foreach ($n in @('Shell', 'Root', 'TitleBar', 'Dot', 'TitleText', 'CountsText', 'BtnMain', 'IconMain',
    'BtnClose', 'IconClose', 'OfflineBar', 'ListScroll', 'ListPanel', 'EmptyBox',
    'AskHost', 'AskDivider', 'AskCard', 'AskBody', 'FootBar', 'FootText', 'PulseRing')) {
  $el = $window.FindName($n)
  if ($null -eq $el) { Log "warn: FindName('$n') = null" }
  $script:ui[$n] = $el
}
Log "xaml ok: light=$($script:IsLight) shell=$($null -ne $script:ui.Shell)"

$script:window = $window

# 预取常用画刷
$script:BrPrimary = Br 'TextPrimary'
$script:BrSecondary = Br 'TextSecondary'
$script:BrTertiary = Br 'TextTertiary'
$script:BrBrand = Br 'Brand'
$script:BrBrandHover = Br 'BrandHover'
$script:BrBrandSoft = Br 'BrandSoft'
$script:BrWaiting = Br 'Waiting'
$script:BrIdle = Br 'Idle'
$script:BrDanger = Br 'Danger'
$script:BrDangerGhost = Br 'DangerGhost'
$script:BrDangerHoverBg = Br 'DangerHoverBg'
$script:BrOnAccent = Br 'OnAccent'
$script:BrSurface = Br 'Surface'
$script:BrSurfaceHover = Br 'SurfaceHover'
$script:BrRowHover = Br 'RowHover'
$script:BrWaitingRow = Br 'WaitingRowBg'
$script:BrIcon = Br 'Icon'
$script:BrIconHover = Br 'IconHover'
$script:BrIconHoverBg = Br 'IconHoverBg'
$script:BrTransparent = [System.Windows.Media.Brushes]::Transparent

# ---------------------------------------------------------------------------
# 4. 运行时状态
# ---------------------------------------------------------------------------

$script:closing = $false
$script:closeSent = $false
$script:collapsed = $false
$script:dragging = $false
$script:offline = $false
$script:failCount = 0
$script:lastSig = ''
$script:lastPollOk = $false
$script:clockNow = NowMs
$script:rows = @()
$script:rowCount = 0
$script:waitingCount = 0
$script:runningCount = 0
$script:sessionCount = 0
$script:hasAsk = $false
$script:askId = ''
$script:submitting = $false
$script:Hwnd = [IntPtr]::Zero

# 待确认卡片状态
$script:askItems = @()
$script:askKind = 'question'
$script:askSessionId = ''
$script:askMultiItem = $false
$script:itemSel = @{}        # itemId -> string[] 选中的 optionId
$script:optRefs = @{}        # itemId -> optId -> @{ row; mark; fill; ctx; selected }
$script:submitBtn = $null
$script:submitLabel = $null
$script:suppressAskId = ''
$script:suppressUntil = 0
$script:clickedLabel = $null
$script:clickedLabelText = ''
$script:clickedLabelFg = $null
$script:offlineStreak = 0
$script:lastTitleDown = 0
$script:dragStart = $null
$script:askNoteActive = $false
$script:heightAnimTarget = [double]$script:ExpandedHeight

$script:toastText = ''
$script:toastUntil = 0
$script:noticeText = ''
$script:noticeUntil = 0
$script:lastNotice = ''
$script:readySent = $false

# ---------------------------------------------------------------------------
# 5. HTTP
# ---------------------------------------------------------------------------

function Invoke-Api([string]$Method, [string]$Path, $Body, [int]$TimeoutMs = 800) {
  $url = 'http://127.0.0.1:' + [int]$script:Port + $Path
  $req = [System.Net.WebRequest]::Create($url)
  $req.Method = $Method
  $req.Proxy = $null
  $req.Timeout = $TimeoutMs
  $req.KeepAlive = $false
  try { $req.ReadWriteTimeout = $TimeoutMs } catch { }
  if ($script:Token) { $req.Headers.Add('x-taskbox-token', [string]$script:Token) }

  if ($null -ne $Body) {
    $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Compress -Depth 6 }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $req.ContentType = 'application/json; charset=utf-8'
    $req.ContentLength = $bytes.Length
    $st = $req.GetRequestStream()
    try { $st.Write($bytes, 0, $bytes.Length) } finally { $st.Close() }
  }

  $resp = $null
  try {
    $resp = $req.GetResponse()
    $sr = [System.IO.StreamReader]::new($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
    try { return $sr.ReadToEnd() } finally { $sr.Close() }
  } finally {
    if ($null -ne $resp) { $resp.Close() }
  }
}

function Invoke-GetState {
  $txt = Invoke-Api 'GET' '/state' $null $script:HttpTimeoutMs
  if (-not $txt) { throw 'empty state body' }
  $obj = $txt | ConvertFrom-Json
  if ($null -eq $obj) { throw 'state is null' }
  if ($obj.ok -ne $true) { throw 'state envelope not ok' }
  return $obj
}

# 只在失败时轻量提示，不弹窗、不抛
function Invoke-Post([string]$Path, $Body, [int]$TimeoutMs = 1200) {
  try {
    $txt = Invoke-Api 'POST' $Path $Body $TimeoutMs
    if (-not $txt) { return @{ ok = $true } }
    $obj = $txt | ConvertFrom-Json
    if ($null -eq $obj) { return @{ ok = $true } }
    return $obj
  } catch {
    return @{ ok = $false; error = ($_.Exception.Message) }
  }
}

# ---------------------------------------------------------------------------
# 6. 通用 UI 小工具
# ---------------------------------------------------------------------------

function Format-Rel([double]$deltaMs) {
  if ($deltaMs -lt 0) { $deltaMs = 0 }
  if ($deltaMs -lt 45000) { return '刚刚' }
  $m = [Math]::Floor($deltaMs / 60000)
  if ($m -lt 60) { return ('{0} 分钟' -f [int]$m) }
  $h = [Math]::Floor($m / 60)
  if ($h -lt 24) { return ('{0} 小时' -f [int]$h) }
  $d = [Math]::Floor($h / 24)
  if ($d -gt 99) { $d = 99 }
  return ('{0} 天' -f [int]$d)
}

function Get-StatusBrush([string]$st) {
  switch ($st) {
    'waiting' { return $script:BrWaiting }
    'running' { return $script:BrBrand }
    default { return $script:BrIdle }
  }
}

function New-Text([string]$text, [double]$size, $brush, [double]$lineHeight = 0) {
  $tb = [System.Windows.Controls.TextBlock]::new()
  $tb.Text = $text
  $tb.FontSize = $size
  $tb.Foreground = $brush
  $tb.TextWrapping = [System.Windows.TextWrapping]::Wrap
  $tb.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
  if ($lineHeight -gt 0) {
    $tb.LineHeight = $lineHeight
    $tb.LineStackingStrategy = [System.Windows.LineStackingStrategy]::BlockLineHeight
  }
  return $tb
}

function New-Chip([string]$text, [string]$fgHex, [string]$bgHex, [string]$meta = '') {
  $b = [System.Windows.Controls.Border]::new()
  $b.CornerRadius = [System.Windows.CornerRadius]::new(5)
  $b.Padding = [System.Windows.Thickness]::new(6, 2, 6, 2)
  $b.Background = (BrHex $bgHex)
  $b.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
  $b.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $t = [System.Windows.Controls.TextBlock]::new()
  $t.FontSize = 10
  $t.Foreground = (BrHex $fgHex)
  $t.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $t.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
  # 整条 chip 同色：只有分隔符降到 60% 不透明度
  $r1 = [System.Windows.Documents.Run]::new($text)
  $r1.Foreground = (BrHex $fgHex)
  [void]$t.Inlines.Add($r1)
  if ($meta) {
    $r2 = [System.Windows.Documents.Run]::new(' · ')
    $r2.Foreground = (BrAlpha $fgHex 0.6)
    [void]$t.Inlines.Add($r2)
    $r3 = [System.Windows.Documents.Run]::new($meta)
    $r3.Foreground = (BrHex $fgHex)
    [void]$t.Inlines.Add($r3)
  }
  $b.Child = $t
  return $b
}

# 等宽「原文」块：Consolas / Cascadia Mono，12px，比卡片再暗一档
function New-CodeBlock([string]$text, [double]$maxHeight = 88) {
  $b = [System.Windows.Controls.Border]::new()
  $b.CornerRadius = [System.Windows.CornerRadius]::new(8)
  $b.Background = (BrHex $script:Th.CodeBg)
  $b.Padding = [System.Windows.Thickness]::new(10, 8, 10, 8)
  $borderHex = [string]$script:Th.CodeBorder
  if ($borderHex -and $borderHex -ne 'Transparent') {
    $b.BorderThickness = [System.Windows.Thickness]::new(1)
    $b.BorderBrush = (BrHex $borderHex)
  }
  $t = [System.Windows.Controls.TextBlock]::new()
  $t.Text = $text
  $t.FontFamily = [System.Windows.Media.FontFamily]::new('Cascadia Mono, Consolas, Courier New')
  $t.FontSize = 12
  $t.Foreground = (BrHex $script:Th.CodeText)
  $t.TextWrapping = [System.Windows.TextWrapping]::Wrap
  $t.LineHeight = 17
  $t.LineStackingStrategy = [System.Windows.LineStackingStrategy]::BlockLineHeight
  if ($maxHeight -gt 0) { $t.MaxHeight = $maxHeight }
  $t.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
  $b.Child = $t
  return $b
}

# 可点击的圆角块（hover 由 ctx.base / ctx.hover 控制，选中态可改 ctx.base）
function New-HoverBox($child, [string]$baseHex, [string]$hoverHex, $actTag, [double]$height, [double]$radius = 8) {
  $b = [System.Windows.Controls.Border]::new()
  $b.Height = $height
  $b.CornerRadius = [System.Windows.CornerRadius]::new($radius)
  $b.Background = (BrHex $baseHex)
  $b.Cursor = [System.Windows.Input.Cursors]::Hand
  $ctx = @{ base = (BrHex $baseHex); baseHex0 = $baseHex; hover = (BrHex $hoverHex); hoverHex0 = $hoverHex; act = $actTag }
  $b.Tag = $ctx
  if ($null -ne $child) { $b.Child = $child }
  $b.Add_MouseEnter({ param($snd, $e) $c = $snd.Tag; if ($c -and $c.hover) { $snd.Background = $c.hover } })
  $b.Add_MouseLeave({ param($snd, $e) $c = $snd.Tag; if ($c -and $c.base) { $snd.Background = $c.base } })
  $b.Add_MouseLeftButtonDown({ param($snd, $e) $e.Handled = $true })
  $b.Add_MouseLeftButtonUp({ param($snd, $e) $e.Handled = $true; $c = $snd.Tag; if ($c -and $c.act) { Invoke-ActTag $c.act } })
  return $b
}

# ---------------------------------------------------------------------------
# 7. 会话列表
# ---------------------------------------------------------------------------

function Get-RightText($s) {
  if ($script:clockNow -le 0) { $script:clockNow = NowMs }
  $st = (Safe-Str $s.status 'idle').ToLowerInvariant()
  if ($st -eq 'waiting') {
    # waiting 行右侧固定显示状态语（琥珀），不显示 activity / 相对时间
    $sid = Safe-Str $s.id ''
    if ($script:askSessionId -and $sid -and $sid -eq $script:askSessionId) {
      if ($script:askNoteActive) { return '等待输入' }
      if ($script:askKind -eq 'approval') { return '等待授权' }
      return '等待选择'
    }
    $act = (Safe-Str $s.activity '').Trim()
    if ($act -match '^等待') {
      if ($act.Length -gt 10) { $act = $act.Substring(0, 10) + '…' }
      return $act
    }
    return '等待中'
  }
  $act = (Safe-Str $s.activity '').Trim()
  if ($act) {
    if ($act.Length -gt 42) { $act = $act.Substring(0, 42) + '…' }
    return $act
  }
  $up = Safe-Num $s.updatedAt 0
  if ($up -le 0) { return '' }
  return (Format-Rel ($script:clockNow - $up))
}

function New-SessionRow($s) {
  $st = (Safe-Str $s.status 'idle').ToLowerInvariant()
  if (@('running', 'waiting', 'idle') -notcontains $st) { $st = 'idle' }
  $sid = Safe-Str $s.id ''
  $title = (Safe-Str $s.title '').Trim()
  if (-not $title) { $title = '未命名对话' }
  if ($title.Length -gt 120) { $title = $title.Substring(0, 120) }
  $ws = (Safe-Str $s.workspace '').Trim()

  $rowB = [System.Windows.Controls.Border]::new()
  $rowB.Height = 34
  $rowB.CornerRadius = [System.Windows.CornerRadius]::new(7)
  $rowB.Padding = [System.Windows.Thickness]::new(6, 0, 8, 0)
  $rowB.Margin = [System.Windows.Thickness]::new(0, 0, 0, 2)   # 行间 2px 呼吸
  $rowB.Cursor = [System.Windows.Input.Cursors]::Hand
  $tip = $title
  if ($ws) { $tip = $title + "`n" + $ws }
  $rowB.ToolTip = $tip
  $rowB.Background = if ($st -eq 'waiting') { $script:BrWaitingRow } else { $script:BrTransparent }

  $g = [System.Windows.Controls.Grid]::new()
  $rowB.Child = $g

  $c0 = [System.Windows.Controls.ColumnDefinition]::new()
  $c0.Width = [System.Windows.GridLength]::new([double]6)
  $c1 = [System.Windows.Controls.ColumnDefinition]::new()
  $c1.Width = [System.Windows.GridLength]::new([double]1, [System.Windows.GridUnitType]::Auto)
  $c2 = [System.Windows.Controls.ColumnDefinition]::new()
  $c2.Width = [System.Windows.GridLength]::new([double]1, [System.Windows.GridUnitType]::Star)
  $c3 = [System.Windows.Controls.ColumnDefinition]::new()
  $c3.Width = [System.Windows.GridLength]::new([double]1, [System.Windows.GridUnitType]::Auto)
  [void]$g.ColumnDefinitions.Add($c0)
  [void]$g.ColumnDefinitions.Add($c1)
  [void]$g.ColumnDefinitions.Add($c2)
  [void]$g.ColumnDefinitions.Add($c3)

  # waiting：琥珀色左边条（列宽固定，所有行对齐）
  $bar = [System.Windows.Controls.Border]::new()
  $bar.Width = 3
  $bar.Height = 16
  $bar.CornerRadius = [System.Windows.CornerRadius]::new(1)
  $bar.Background = $script:BrWaiting
  $bar.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
  $bar.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  if ($st -ne 'waiting') { $bar.Visibility = [System.Windows.Visibility]::Hidden }
  [void]$g.Children.Add($bar)

  $dot = [System.Windows.Shapes.Ellipse]::new()
  $dot.Width = 6
  $dot.Height = 6
  $dot.Fill = (Get-StatusBrush $st)
  $dot.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $dot.Margin = [System.Windows.Thickness]::new(0, 0, 9, 0)
  [System.Windows.Controls.Grid]::SetColumn($dot, 1)
  [void]$g.Children.Add($dot)

  $tb = [System.Windows.Controls.TextBlock]::new()
  $tb.Text = $title
  $tb.FontSize = 12
  $tb.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $tb.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
  $tb.TextWrapping = [System.Windows.TextWrapping]::NoWrap
  if ($st -eq 'waiting') {
    $tb.Foreground = $script:BrPrimary
    $tb.FontWeight = [System.Windows.FontWeights]::SemiBold
  } elseif ($st -eq 'running') {
    $tb.Foreground = $script:BrPrimary
  } else {
    $tb.Foreground = $script:BrSecondary
  }
  [System.Windows.Controls.Grid]::SetColumn($tb, 2)
  [void]$g.Children.Add($tb)

  $rt = [System.Windows.Controls.TextBlock]::new()
  $rt.Text = (Get-RightText $s)
  $rt.FontSize = 10.5
  $rt.FontFamily = [System.Windows.Media.FontFamily]::new($numFont)
  $rt.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $rt.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
  $rt.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
  $rt.MaxWidth = 118
  $rt.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
  $rt.TextWrapping = [System.Windows.TextWrapping]::NoWrap
  if ($st -eq 'waiting') { $rt.Foreground = $script:BrWaiting }
  elseif ($st -eq 'running') { $rt.Foreground = $script:BrSecondary }
  else { $rt.Foreground = $script:BrTertiary }
  [System.Windows.Controls.Grid]::SetColumn($rt, 3)
  [void]$g.Children.Add($rt)

  $ctx = @{ base = $rowB.Background; hover = $script:BrRowHover; session = $sid }
  $rowB.Tag = $ctx
  $rowB.Add_MouseEnter({ param($snd, $e) $c = $snd.Tag; if ($c) { $snd.Background = $c.hover } })
  $rowB.Add_MouseLeave({ param($snd, $e) $c = $snd.Tag; if ($c) { $snd.Background = $c.base } })
  $rowB.Add_MouseLeftButtonDown({ param($snd, $e) $e.Handled = $true })
  $rowB.Add_MouseLeftButtonUp({
      param($snd, $e)
      $e.Handled = $true
      $c = $snd.Tag
      if ($c -and $c.session) { Select-Session ([string]$c.session) }
    })

  return @{ Row = $rowB; Right = $rt; Data = $s }
}

function Update-RelTimes {
  foreach ($r in $script:rows) {
    $d = $r.Data
    if ($null -eq $d) { continue }
    $st = (Safe-Str $d.status '').ToLowerInvariant()
    # waiting 行右侧是状态语，会随 ask 变化；非 waiting 且已有 activity 的不用每 tick 算
    if ($st -ne 'waiting' -and (Safe-Str $d.activity '').Trim()) { continue }
    $txt = Get-RightText $d
    if ($r.Right.Text -ne $txt) { $r.Right.Text = $txt }
  }
}

function Render-Sessions($sessions) {
  $list = @()
  foreach ($s in $sessions) { if ($null -ne $s) { $list += $s } }

  $same = ($list.Count -eq $script:rows.Count) -and ($list.Count -gt 0)
  if ($same) {
    for ($i = 0; $i -lt $list.Count; $i++) {
      $a = $list[$i]; $b = $script:rows[$i].Data
      if ((Safe-Str $a.id '') -ne (Safe-Str $b.id '') -or
        (Safe-Str $a.status '') -ne (Safe-Str $b.status '') -or
        (Safe-Str $a.title '') -ne (Safe-Str $b.title '')) { $same = $false; break }
    }
  }

  if ($same) {
    for ($i = 0; $i -lt $list.Count; $i++) {
      $script:rows[$i].Data = $list[$i]
      $txt = Get-RightText $list[$i]
      if ($script:rows[$i].Right.Text -ne $txt) { $script:rows[$i].Right.Text = $txt }
    }
    return
  }

  $offset = 0.0
  try { $offset = [double]$script:ui.ListScroll.VerticalOffset } catch { }

  $panel = $script:ui.ListPanel
  $panel.Children.Clear()
  $script:rows = @()
  foreach ($s in $list) {
    $item = New-SessionRow $s
    [void]$panel.Children.Add($item.Row)
    $script:rows += $item
  }
  $script:rowCount = $list.Count
  $script:ui.EmptyBox.Visibility = if ($list.Count -eq 0) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
  if ($offset -gt 0.5) {
    try { $script:ui.ListScroll.ScrollToVerticalOffset($offset) } catch { }
  }
}

# ---------------------------------------------------------------------------
# 8. 待确认面板（v1 单组 + v1.1 多组 / note / selections）
# ---------------------------------------------------------------------------

function Split-NaturalCode([string]$text) {
  $res = @{ natural = ''; code = '' }
  if (-not $text) { return $res }
  $lines = @($text -split "`r?`n")
  while ($lines.Count -gt 0 -and -not ([string]$lines[0]).Trim()) {
    if ($lines.Count -eq 1) { $lines = @(); break }
    $lines = @($lines[1..($lines.Count - 1)])
  }
  if ($lines.Count -eq 0) { return $res }
  $res.natural = ([string]$lines[0]).Trim()
  if ($lines.Count -gt 1) {
    $rest = @($lines[1..($lines.Count - 1)])
    $res.code = (($rest -join "`n")).Trim()
  }
  return $res
}

function Get-AskItems($ask) {
  $items = @()
  foreach ($it in @($ask.items)) {
    if ($null -eq $it) { continue }
    if (-not (Safe-Str $it.id '')) { continue }
    $opts = @()
    foreach ($o in @($it.options)) {
      if ($null -ne $o -and (Safe-Str $o.id '')) { $opts += $o }
    }
    $items += @{
      id          = (Safe-Str $it.id '')
      header      = (Safe-Str $it.header '').Trim()
      question    = (Safe-Str $it.question '').Trim()
      detail      = (Safe-Str $it.detail '').Trim()
      multiSelect = [bool]$it.multiSelect
      options     = $opts
    }
  }
  if ($items.Count -gt 0) { return $items }

  # v1 兼容：顶层 detail/multiSelect/options 合成一个 item
  $topOpts = @()
  foreach ($o in @($ask.options)) {
    if ($null -ne $o -and (Safe-Str $o.id '')) { $topOpts += $o }
  }
  return @(@{
      id          = 'v1-item'
      header      = ''
      question    = ''
      detail      = (Safe-Str $ask.detail '').Trim()
      multiSelect = [bool]$ask.multiSelect
      options     = $topOpts
    })
}

function Get-ItemSel([string]$itemId) {
  if ($script:itemSel.ContainsKey($itemId)) { return @($script:itemSel[$itemId]) }
  return @()
}
function Set-ItemSel([string]$itemId, [string[]]$ids) {
  $script:itemSel[$itemId] = @($ids | Where-Object { $_ })
}

function Apply-OptVisual([string]$itemId, [string]$oid, [bool]$selected) {
  if (-not $script:optRefs.ContainsKey($itemId)) { return }
  if (-not $script:optRefs[$itemId].ContainsKey($oid)) { return }
  $r = $script:optRefs[$itemId][$oid]
  if ($null -ne $r.mark) {
    if ($selected) {
      $r.mark.Background = $script:BrBrand
      $r.mark.BorderBrush = $script:BrBrand
    } else {
      $r.mark.Background = $script:BrTransparent
      $r.mark.BorderBrush = $script:BrTertiary
    }
  }
  if ($null -ne $r.fill) {
    $r.fill.Visibility = if ($selected) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
  }
  if ($null -ne $r.ctx) {
    if ($selected) {
      $r.ctx.base = $script:BrBrandSoft
      $r.ctx.hover = $script:BrBrandSoft
      $r.row.BorderBrush = $script:BrBrand
    } else {
      $r.ctx.base = (BrHex $r.ctx.baseHex0)
      $r.ctx.hover = (BrHex $r.ctx.hoverHex0)
      $r.row.BorderBrush = $script:BrTransparent
    }
    $r.row.Background = $r.ctx.base
  }
  $r.selected = $selected
}

function Refresh-ItemVisuals([string]$itemId) {
  if (-not $script:optRefs.ContainsKey($itemId)) { return }
  $sel = Get-ItemSel $itemId
  foreach ($oid in @($script:optRefs[$itemId].Keys)) {
    Apply-OptVisual $itemId $oid ($sel -contains $oid)
  }
}

function Update-SubmitState {
  if ($null -eq $script:submitBtn) { return }
  $ok = $true
  $missing = 0
  foreach ($item in $script:askItems) {
    $sel = @(Get-ItemSel $item.id)
    if ($sel.Count -eq 0) { $ok = $false; $missing++ }
  }
  if ($script:askMultiItem) {
    if ($ok) {
      $script:submitBtn.Opacity = 1.0
      $script:submitLabel.Text = '提交'
    } else {
      $script:submitBtn.Opacity = 0.42
      $script:submitLabel.Text = ('还差 {0} 项' -f $missing)
    }
  } else {
    $n = (Get-ItemSel $script:askItems[0].id).Count
    if ($n -gt 0) {
      $script:submitBtn.Opacity = 1.0
      $script:submitLabel.Text = ('提交 · 已选 {0} 项' -f $n)
      $ok = $true
    } else {
      $script:submitBtn.Opacity = 0.42
      $script:submitLabel.Text = '提交'
      $ok = $false
    }
  }
  $script:submitBtn.IsHitTestVisible = $ok
}

function Mark-SubmittingTarget($lbl) {
  $script:clickedLabel = $lbl
  if ($null -ne $lbl) {
    $script:clickedLabelText = [string]$lbl.Text
    $script:clickedLabelFg = $lbl.Foreground
  }
}

function Set-Submitting([bool]$on) {
  $script:submitting = $on
  $card = $script:ui.AskCard
  if ($on) {
    # 明确反馈：被点的按钮变「已提交…」灰态，整卡 120ms 淡出，不等下一次轮询
    if ($null -ne $script:clickedLabel) {
      $script:clickedLabel.Text = '已提交…'
      $script:clickedLabel.Foreground = $script:BrTertiary
    }
    $card.IsHitTestVisible = $false
    $anim = [System.Windows.Media.Animation.DoubleAnimation]::new()
    $anim.To = 0.35
    $anim.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(120))
    $ease = [System.Windows.Media.Animation.CubicEase]::new()
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $anim.EasingFunction = $ease
    $card.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $anim)
  } else {
    if ($null -ne $script:clickedLabel) {
      $script:clickedLabel.Text = $script:clickedLabelText
      if ($null -ne $script:clickedLabelFg) { $script:clickedLabel.Foreground = $script:clickedLabelFg }
    }
    $card.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    $card.Opacity = 1.0
    $card.IsHitTestVisible = $true
  }
}

function New-AskMark([bool]$round) {
  $mark = [System.Windows.Controls.Border]::new()
  $mark.Width = 14
  $mark.Height = 14
  $mark.CornerRadius = [System.Windows.CornerRadius]::new($(if ($round) { 7 } else { 4 }))
  $mark.BorderThickness = [System.Windows.Thickness]::new(1)
  $mark.BorderBrush = $script:BrTertiary
  $mark.Background = $script:BrTransparent
  $mark.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $mark.Margin = [System.Windows.Thickness]::new(0, 0, 9, 0)
  if ($round) {
    $dot = [System.Windows.Shapes.Ellipse]::new()
    $dot.Width = 6
    $dot.Height = 6
    $dot.Fill = $script:BrOnAccent
    $dot.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $dot.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $dot.Visibility = [System.Windows.Visibility]::Collapsed
    $mark.Child = $dot
    return @{ mark = $mark; fill = $dot }
  }
  $check = [System.Windows.Shapes.Path]::new()
  $check.Data = [System.Windows.Media.Geometry]::Parse('M3.2,7.2 L5.6,9.6 L10.4,4.4')
  $check.Stroke = $script:BrOnAccent
  $check.StrokeThickness = 1.5
  $check.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round
  $check.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round
  $check.StrokeLineJoin = [System.Windows.Media.PenLineJoin]::Round
  $check.Visibility = [System.Windows.Visibility]::Collapsed
  $mark.Child = $check
  return @{ mark = $mark; fill = $check }
}

# 竖排整行选项：showMark=true 时带单选/复选标记（多组确认用）
function New-AskOptionRow([string]$askId, [string]$itemId, $opt, [bool]$multiItem, [bool]$multi, [bool]$showMark) {
  $oid = Safe-Str $opt.id ''
  $label = Safe-Str $opt.label $oid
  if ($label.Length -gt 60) { $label = $label.Substring(0, 60) }
  $desc = (Safe-Str $opt.description '').Trim()
  if ($desc.Length -gt 60) { $desc = $desc.Substring(0, 60) }

  $g = [System.Windows.Controls.Grid]::new()
  $c0 = [System.Windows.Controls.ColumnDefinition]::new()
  $c0.Width = [System.Windows.GridLength]::new([double]1, [System.Windows.GridUnitType]::Auto)
  $c1 = [System.Windows.Controls.ColumnDefinition]::new()
  $c1.Width = [System.Windows.GridLength]::new([double]1, [System.Windows.GridUnitType]::Star)
  [void]$g.ColumnDefinitions.Add($c0)
  [void]$g.ColumnDefinitions.Add($c1)

  $markInfo = $null
  if ($showMark) {
    $markInfo = New-AskMark (-not $multi)
    [System.Windows.Controls.Grid]::SetColumn($markInfo.mark, 0)
    [void]$g.Children.Add($markInfo.mark)
  }

  $labelTb = [System.Windows.Controls.TextBlock]::new()
  $labelTb.Text = $label
  $labelTb.FontSize = 12
  $labelTb.Foreground = $script:BrPrimary
  $labelTb.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
  $labelTb.TextWrapping = [System.Windows.TextWrapping]::NoWrap

  if ($desc) {
    $stack = [System.Windows.Controls.StackPanel]::new()
    $stack.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $labelTb.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
    $db = [System.Windows.Controls.TextBlock]::new()
    $db.Text = $desc
    $db.FontSize = 10.5
    $db.Foreground = $script:BrTertiary
    $db.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    $db.TextWrapping = [System.Windows.TextWrapping]::NoWrap
    $db.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
    [void]$stack.Children.Add($labelTb)
    [void]$stack.Children.Add($db)
    [System.Windows.Controls.Grid]::SetColumn($stack, 1)
    [void]$g.Children.Add($stack)
  } else {
    $labelTb.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [System.Windows.Controls.Grid]::SetColumn($labelTb, 1)
    [void]$g.Children.Add($labelTb)
  }

  $act = @{
    kind      = 'ask-opt'
    ask       = $askId
    item      = $itemId
    opt       = $oid
    multi     = $multi
    multiItem = $multiItem
    showMark  = $showMark
    lbl       = $labelTb
  }
  $height = if ($desc) { 46 } else { 34 }
  $row = New-HoverBox $g $script:Th.Surface $script:Th.SurfaceHover $act $height 8
  $row.Padding = [System.Windows.Thickness]::new(10, 0, 12, 0)

  # 选中态需要能按 (item, opt) 找到行/标记
  if ($markInfo) {
    if (-not $script:optRefs.ContainsKey($itemId)) { $script:optRefs[$itemId] = @{} }
    $ctx = $row.Tag
    $script:optRefs[$itemId][$oid] = @{
      row = $row; mark = $markInfo.mark; fill = $markInfo.fill; ctx = $ctx; selected = $false
    }
  }
  return $row
}

function New-AskOptionPill([string]$askId, [string]$itemId, $opt) {
  $oid = Safe-Str $opt.id ''
  $label = Safe-Str $opt.label $oid
  if ($label.Length -gt 24) { $label = $label.Substring(0, 24) }
  $style = Safe-Str $opt.style 'default'
  if (@('primary', 'danger', 'default') -notcontains $style) { $style = 'default' }

  $txt = [System.Windows.Controls.TextBlock]::new()
  $txt.Text = $label
  $txt.FontSize = 12.5
  $txt.FontWeight = [System.Windows.FontWeights]::SemiBold
  $txt.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
  $txt.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $txt.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
  $txt.TextWrapping = [System.Windows.TextWrapping]::NoWrap

  $act = @{ kind = 'ask-opt'; ask = $askId; item = $itemId; opt = $oid; multi = $false; multiItem = $false; showMark = $false; lbl = $txt }
  switch ($style) {
    'primary' {
      $txt.Foreground = $script:BrOnAccent
      $pill = New-HoverBox $txt $script:Th.Brand $script:Th.BrandHover $act 34 8
    }
    'danger' {
      # ghost：透明底 + 描边 + 彩色字，不与主按钮抢视觉
      $txt.Foreground = $script:BrDanger
      $pill = New-HoverBox $txt 'Transparent' $script:Th.DangerHoverBg $act 34 8
      $pill.BorderThickness = [System.Windows.Thickness]::new(1)
      $pill.BorderBrush = $script:BrDangerGhost
    }
    default {
      $txt.Foreground = $script:BrPrimary
      $pill = New-HoverBox $txt $script:Th.Surface $script:Th.SurfaceHover $act 34 8
    }
  }
  return $pill
}

function Add-AskItem($stack, $item, [int]$index, [int]$total, [string]$askId, [bool]$multiItem, [bool]$noteActive, [string]$kind) {
  if ($multiItem) {
    $head = [System.Windows.Controls.TextBlock]::new()
    $h = ('问题 {0}/{1}' -f ($index + 1), $total)
    if ($item.header) { $h = $h + ' · ' + $item.header }
    $head.Text = $h
    $head.FontSize = 10.5
    $head.Foreground = $script:BrTertiary
    $head.Margin = if ($index -eq 0) { [System.Windows.Thickness]::new(0, 0, 0, 6) } else { [System.Windows.Thickness]::new(0, 10, 0, 6) }
    [void]$stack.Children.Add($head)
  }

  # 自然语言题干与「原文」分开排：
  #   detail 多行 → 第一行是自然语言，其余是原文（等宽块）；
  #   detail 单行 → 工具授权视为原文（等宽块），其他视为补充说明（sans 次级色）。
  $natural = $item.question
  $sub = ''
  $code = ''
  $detailText = $item.detail
  if ($detailText) {
    $dlines = @($detailText -split "`r?`n")
    if ($dlines.Count -gt 1) {
      $split = Split-NaturalCode $detailText
      if (-not $natural) { $natural = $split.natural } else { $sub = $split.natural }
      $code = $split.code
    } elseif ($kind -eq 'approval') {
      $code = $detailText.Trim()
    } else {
      if (-not $natural) { $natural = $detailText.Trim() } else { $sub = $detailText.Trim() }
    }
  }
  if ($natural.Length -gt 400) { $natural = $natural.Substring(0, 400) + '…' }
  if ($natural) {
    $q = New-Text $natural 14 $script:BrPrimary 21
    $q.MaxHeight = 84
    [void]$stack.Children.Add($q)
  }
  if ($sub) {
    if ($sub.Length -gt 240) { $sub = $sub.Substring(0, 240) + '…' }
    $s = New-Text $sub 12 $script:BrSecondary 18
    $s.MaxHeight = 54
    $s.Margin = [System.Windows.Thickness]::new(0, 5, 0, 0)
    [void]$stack.Children.Add($s)
  }
  if ($code) {
    if ($code.Length -gt 900) { $code = $code.Substring(0, 900) + '…' }
    $blk = New-CodeBlock $code
    $blk.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    [void]$stack.Children.Add($blk)
  }

  if ($noteActive) { return }
  $opts = $item.options
  if ($opts.Count -eq 0) { return }
  $multi = [bool]$item.multiSelect

  # 单组 + 工具授权 + 两个选项：等宽双按钮
  if (-not $multiItem -and -not $multi -and $opts.Count -eq 2 -and $kind -eq 'approval') {
    $grid = [System.Windows.Controls.Grid]::new()
    $grid.Margin = [System.Windows.Thickness]::new(0, 12, 0, 0)
    for ($i = 0; $i -lt 2; $i++) {
      $cd = [System.Windows.Controls.ColumnDefinition]::new()
      $cd.Width = [System.Windows.GridLength]::new([double]1, [System.Windows.GridUnitType]::Star)
      [void]$grid.ColumnDefinitions.Add($cd)
    }
    for ($i = 0; $i -lt 2; $i++) {
      $pill = New-AskOptionPill $askId $item.id $opts[$i]
      [System.Windows.Controls.Grid]::SetColumn($pill, $i)
      if ($i -gt 0) { $pill.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0) }
      [void]$grid.Children.Add($pill)
    }
    [void]$stack.Children.Add($grid)
    return
  }

  # 其余：竖排整行
  $showMark = $multiItem -or $multi
  $vstack = [System.Windows.Controls.StackPanel]::new()
  $vstack.Margin = [System.Windows.Thickness]::new(0, 10, 0, 0)
  $first = $true
  foreach ($o in $opts) {
    $row = New-AskOptionRow $askId $item.id $o $multiItem $multi $showMark
    if (-not $first) { $row.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0) }
    $first = $false
    [void]$vstack.Children.Add($row)
  }
  [void]$stack.Children.Add($vstack)
}

function Hide-Ask {
  $script:ui.AskHost.Visibility = [System.Windows.Visibility]::Collapsed
  $script:ui.AskBody.Children.Clear()
  $script:ui.AskCard.Opacity = 1.0
  $script:ui.AskCard.IsHitTestVisible = $true
  $script:hasAsk = $false
  $script:submitting = $false
  $script:askId = ''
  $script:askItems = @()
  $script:itemSel = @{}
  $script:optRefs = @{}
  $script:submitBtn = $null
  $script:submitLabel = $null
  $script:askMultiItem = $false
  $script:askSessionId = ''
  $script:clickedLabel = $null
  $script:clickedLabelText = ''
  $script:clickedLabelFg = $null
  $script:askNoteActive = $false
$script:heightAnimTarget = [double]$script:ExpandedHeight
}

function Build-AskCard($ask) {
  $body = $script:ui.AskBody
  $card = $script:ui.AskCard
  $body.Children.Clear()
  $script:submitBtn = $null
  $script:submitLabel = $null
  $script:optRefs = @{}

  $askId = Safe-Str $ask.id ''
  $kind = Safe-Str $ask.kind 'question'
  if (@('approval', 'question') -notcontains $kind) { $kind = 'question' }
  $note = (Safe-Str $ask.note '').Trim()
  $items = @(Get-AskItems $ask)
  $script:askItems = $items
  $script:askKind = $kind
  $script:askSessionId = Safe-Str $ask.sessionId ''
  # note 模式没有选项区，按单组排版
  $script:askMultiItem = ($items.Count -gt 1) -and (-not $note)
  $script:askNoteActive = [bool]$note

  # --- 头部：chip（整条一个底色一个文字色，只有分隔符 60%）+ 会话名 ---
  $metaText = (Safe-Str $ask.meta '').Trim()
  if ($metaText.Length -gt 28) { $metaText = $metaText.Substring(0, 28) + '…' }
  $head = [System.Windows.Controls.Grid]::new()
  $h0 = [System.Windows.Controls.ColumnDefinition]::new()
  $h0.Width = [System.Windows.GridLength]::new([double]1, [System.Windows.GridUnitType]::Auto)
  $h1 = [System.Windows.Controls.ColumnDefinition]::new()
  $h1.Width = [System.Windows.GridLength]::new([double]1, [System.Windows.GridUnitType]::Star)
  [void]$head.ColumnDefinitions.Add($h0)
  [void]$head.ColumnDefinitions.Add($h1)

  $chipText = Safe-Str $ask.title ''
  if (-not $chipText) { $chipText = if ($kind -eq 'approval') { '需要授权' } else { '需要选择' } }
  if ($chipText.Length -gt 16) { $chipText = $chipText.Substring(0, 16) }
  if ($kind -eq 'approval') {
    $chip = New-Chip $chipText $script:Th.Waiting $script:Th.WaitingSoft $metaText
  } else {
    $chip = New-Chip $chipText $script:Th.Brand $script:Th.BrandSoft $metaText
  }
  [System.Windows.Controls.Grid]::SetColumn($chip, 0)
  [void]$head.Children.Add($chip)

  $stitle = (Safe-Str $ask.sessionTitle '').Trim()
  if ($stitle) {
    if ($stitle.Length -gt 26) { $stitle = $stitle.Substring(0, 26) + '…' }
    $stb = [System.Windows.Controls.TextBlock]::new()
    $stb.Text = $stitle
    $stb.FontSize = 10.5
    $stb.Foreground = $script:BrTertiary
    $stb.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $stb.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $stb.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    $stb.Margin = [System.Windows.Thickness]::new(10, 0, 0, 0)
    [System.Windows.Controls.Grid]::SetColumn($stb, 1)
    [void]$head.Children.Add($stb)
  }

  # --- 布局 ---
  #   多组：卡片定高 236 = 头部(Auto) + 可滚动问题区(*) + 提交行(Auto，钉底常驻)
  #   单组：整体放进 MaxHeight 220 的 ScrollViewer（卡片上限 244），超出卡内滚动
  $layout = $null
  $inner = $null
  if ($script:askMultiItem) {
    $card.Height = 236
    $card.MaxHeight = 236
    $layout = [System.Windows.Controls.Grid]::new()
    $layout.Height = 212
    $r0 = [System.Windows.Controls.RowDefinition]::new()
    $r0.Height = [System.Windows.GridLength]::new([double]1, [System.Windows.GridUnitType]::Auto)
    $r1 = [System.Windows.Controls.RowDefinition]::new()
    $r1.Height = [System.Windows.GridLength]::new([double]1, [System.Windows.GridUnitType]::Star)
    $r2 = [System.Windows.Controls.RowDefinition]::new()
    $r2.Height = [System.Windows.GridLength]::new([double]1, [System.Windows.GridUnitType]::Auto)
    [void]$layout.RowDefinitions.Add($r0)
    [void]$layout.RowDefinitions.Add($r1)
    [void]$layout.RowDefinitions.Add($r2)
    [System.Windows.Controls.Grid]::SetRow($head, 0)
    [void]$layout.Children.Add($head)
    [void]$body.Children.Add($layout)
  } else {
    $card.Height = [double]::NaN
    # 上限 = 360 − 标题栏 44 − 2 行会话 72 − 余量 → 240，按钮绝不会掉出窗口
    $card.MaxHeight = 240
    $sv0 = [System.Windows.Controls.ScrollViewer]::new()
    $sv0.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $sv0.HorizontalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Disabled
    $sv0.Focusable = $false
    $sv0.MaxHeight = 214
    $inner = [System.Windows.Controls.StackPanel]::new()
    $sv0.Content = $inner
    [void]$body.Children.Add($sv0)
    [void]$inner.Children.Add($head)
  }

  # --- note：需要回主窗口补充信息 ---
  if ($note) {
    if ($note.Length -gt 200) { $note = $note.Substring(0, 200) + '…' }
    $nt = New-Text $note 12 $script:BrSecondary 18
    $nt.MaxHeight = 60
    $nt.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    [void]$inner.Children.Add($nt)
  }

  # --- 问题区 ---
  $content = [System.Windows.Controls.StackPanel]::new()
  for ($i = 0; $i -lt $items.Count; $i++) {
    Add-AskItem $content $items[$i] $i $items.Count $askId $script:askMultiItem ([bool]$note) $kind
  }
  if ($script:askMultiItem) {
    $sv = [System.Windows.Controls.ScrollViewer]::new()
    $sv.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $sv.HorizontalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Disabled
    $sv.Focusable = $false
    $sv.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    $sv.Content = $content
    [System.Windows.Controls.Grid]::SetRow($sv, 1)
    [void]$layout.Children.Add($sv)
  } else {
    $content.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    [void]$inner.Children.Add($content)
  }

  # --- note 模式：主按钮「去主窗口回答」（只发 focus）---
  if ($note) {
    $txt = [System.Windows.Controls.TextBlock]::new()
    $txt.Text = '去主窗口回答'
    $txt.FontSize = 12.5
    $txt.FontWeight = [System.Windows.FontWeights]::SemiBold
    $txt.Foreground = $script:BrOnAccent
    $txt.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $txt.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $act = @{ kind = 'focus-main'; ask = $askId; session = $script:askSessionId; lbl = $txt }
    $btn = New-HoverBox $txt $script:Th.Brand $script:Th.BrandHover $act 34 8
    $btn.Margin = [System.Windows.Thickness]::new(0, 12, 0, 0)
    [void]$inner.Children.Add($btn)
    return
  }

  # --- 提交行：多组时钉在卡片底部（滚动区之外），单组多选放内容下方 ---
  $needSubmit = $script:askMultiItem -or [bool]$items[0].multiSelect
  if ($needSubmit) {
    $txt = [System.Windows.Controls.TextBlock]::new()
    $txt.Text = '提交'
    $txt.FontSize = 12.5
    $txt.FontWeight = [System.Windows.FontWeights]::SemiBold
    $txt.Foreground = $script:BrOnAccent
    $txt.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $txt.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $act = @{ kind = 'ask-submit'; ask = $askId; lbl = $txt }
    $btn = New-HoverBox $txt $script:Th.Brand $script:Th.BrandHover $act 34 8
    $script:submitBtn = $btn
    $script:submitLabel = $txt
    if ($script:askMultiItem) {
      $btn.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
      [System.Windows.Controls.Grid]::SetRow($btn, 2)
      [void]$layout.Children.Add($btn)
    } else {
      $btn.Margin = [System.Windows.Thickness]::new(0, 12, 0, 0)
      [void]$inner.Children.Add($btn)
    }
    Update-SubmitState
  }
}
function Render-Ask($ask) {
  if ($null -eq $ask -or -not (Safe-Str $ask.id '')) {
    if ($script:hasAsk) { Hide-Ask }
    return
  }
  $aid = Safe-Str $ask.id ''
  # 刚提交过的确认：Host 有 ≤200ms 延迟，先别画回来，避免闪
  if ($aid -eq $script:suppressAskId -and (NowMs) -lt $script:suppressUntil) {
    if ($script:hasAsk) { Hide-Ask }
    return
  }
  $isNew = ($aid -ne $script:askId)
  if ($isNew) {
    $script:askId = $aid
    $script:itemSel = @{}
    $script:submitting = $false
    $script:ui.AskCard.IsHitTestVisible = $true
    $script:ui.AskCard.Opacity = 1.0
  }
  Build-AskCard $ask
  $script:hasAsk = $true
  $script:ui.AskHost.Visibility = [System.Windows.Visibility]::Visible
  if ($isNew -and -not $script:collapsed) {
    $script:ui.AskCard.Opacity = 0.0
    $anim = [System.Windows.Media.Animation.DoubleAnimation]::new()
    $anim.From = 0.0
    $anim.To = 1.0
    $anim.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(160))
    $ease = [System.Windows.Media.Animation.CubicEase]::new()
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $anim.EasingFunction = $ease
    $script:ui.AskCard.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $anim)
  }
}

# ---------------------------------------------------------------------------
# 9. 标题栏 / 离线 / 折叠
# ---------------------------------------------------------------------------

function New-Run([string]$text, $brush) {
  $r = [System.Windows.Documents.Run]::new($text)
  $r.Foreground = $brush
  return $r
}

function Set-CountsText {
  $tb = $script:ui.CountsText
  $tb.Inlines.Clear()
  if ($script:offline) { return }

  $sep = New-Run ' · ' (BrAlpha $script:Th.TextTertiary 0.6)
  if ($script:collapsed) {
    # 折叠：一行紧凑摘要
    $any = $false
    if ($script:waitingCount -gt 0) {
      [void]$tb.Inlines.Add((New-Run ('{0} 待确认' -f $script:waitingCount) $script:BrWaiting))
      $any = $true
    }
    if ($script:runningCount -gt 0) {
      if ($any) { [void]$tb.Inlines.Add($sep) }
      [void]$tb.Inlines.Add((New-Run ('{0} 进行中' -f $script:runningCount) $script:BrBrand))
      $any = $true
    }
    if (-not $any) {
      [void]$tb.Inlines.Add((New-Run ('{0} 对话' -f $script:sessionCount) $script:BrSecondary))
    }
    return
  }

  # 三段不同色：待确认=琥珀 / 进行中=品牌蓝 / 对话数=次级灰
  $segs = @()
  if ($script:waitingCount -gt 0) { $segs += @{ t = ('{0} 待确认' -f $script:waitingCount); b = $script:BrWaiting } }
  if ($script:runningCount -gt 0) { $segs += @{ t = ('{0} 进行中' -f $script:runningCount); b = $script:BrBrand } }
  $segs += @{ t = ('{0} 对话' -f $script:sessionCount); b = $script:BrSecondary }
  for ($i = 0; $i -lt $segs.Count; $i++) {
    if ($i -gt 0) { [void]$tb.Inlines.Add($sep) }
    [void]$tb.Inlines.Add((New-Run $segs[$i].t $segs[$i].b))
  }
}

function Update-Title($state) {
  if ($script:offline) {
    $script:ui.TitleText.Text = '离线'
    $script:ui.CountsText.Inlines.Clear()
    $script:ui.Dot.Fill = $script:BrIdle
    return
  }
  $script:ui.TitleText.Text = '任务'

  $n = 0; $r = 0; $w = 0
  if ($null -ne $state -and $null -ne $state.counts) {
    $n = [int](Safe-Num $state.counts.sessions 0)
    $r = [int](Safe-Num $state.counts.running 0)
    $w = [int](Safe-Num $state.counts.waiting 0)
  }
  if ($null -ne $state -and $n -le 0) {
    # counts 缺失时退化用列表推断（仅展示用）
    $ss = @()
    foreach ($s in @($state.sessions)) { if ($null -ne $s) { $ss += $s } }
    $n = $ss.Count
    $r = @($ss | Where-Object { (Safe-Str $_.status '') -eq 'running' }).Count
    $w = @($ss | Where-Object { (Safe-Str $_.status '') -eq 'waiting' }).Count
  }
  $script:sessionCount = $n
  $script:runningCount = $r
  $script:waitingCount = $w

  if ($w -gt 0) { $script:ui.Dot.Fill = $script:BrWaiting }
  elseif ($r -gt 0) { $script:ui.Dot.Fill = $script:BrBrand }
  else { $script:ui.Dot.Fill = $script:BrIdle }

  Set-CountsText
  Update-Pulse
}

function Update-Pulse {
  $ring = $script:ui.PulseRing
  if ($null -eq $ring) { return }
  $on = $script:collapsed -and -not $script:offline -and $script:waitingCount -gt 0
  if ($on) {
    if ($ring.Visibility -ne [System.Windows.Visibility]::Visible) {
      $ring.Visibility = [System.Windows.Visibility]::Visible
      $anim = [System.Windows.Media.Animation.DoubleAnimation]::new()
      $anim.From = 0.18
      $anim.To = 0.85
      $anim.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(1100))
      $anim.AutoReverse = $true
      $anim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
      $ring.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $anim)
    }
  } else {
    if ($ring.Visibility -ne [System.Windows.Visibility]::Collapsed) {
      $ring.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
      $ring.Visibility = [System.Windows.Visibility]::Collapsed
      $ring.Opacity = 0
    }
  }
}

function Set-Offline([bool]$off) {
  if ($script:offline -eq $off) { return }
  $script:offline = $off
  if ($off) {
    Log 'offline: 连续轮询失败'
    $script:ui.TitleText.Text = '离线'
    $script:ui.CountsText.Inlines.Clear()
    $script:ui.Dot.Fill = $script:BrIdle
  }
  Apply-Chrome
  Update-Pulse
  Update-WindowHeight
}

function Apply-Chrome {
  if ($script:collapsed) {
    $script:ui.ListScroll.Visibility = [System.Windows.Visibility]::Collapsed
    $script:ui.EmptyBox.Visibility = [System.Windows.Visibility]::Collapsed
    $script:ui.AskHost.Visibility = [System.Windows.Visibility]::Collapsed
    $script:ui.OfflineBar.Visibility = [System.Windows.Visibility]::Collapsed
    $script:ui.FootBar.Visibility = [System.Windows.Visibility]::Collapsed
    return
  }
  $script:ui.ListScroll.Visibility = [System.Windows.Visibility]::Visible
  $script:ui.EmptyBox.Visibility = if ($script:rowCount -eq 0) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
  $script:ui.AskHost.Visibility = if ($script:hasAsk) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
  $script:ui.OfflineBar.Visibility = if ($script:offline) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
}

function Get-StateSignature($state) {
  $sb = [System.Text.StringBuilder]::new()
  [void]$sb.Append('off=').Append([int]$script:offline).Append(';')
  [void]$sb.Append('col=').Append([int]$script:collapsed).Append(';')
  if ($null -ne $state) {
    if ($null -ne $state.counts) {
      [void]$sb.Append('c=').Append([int](Safe-Num $state.counts.sessions 0)).Append(',')
      [void]$sb.Append([int](Safe-Num $state.counts.running 0)).Append(',')
      [void]$sb.Append([int](Safe-Num $state.counts.waiting 0)).Append(';')
    }
    foreach ($s in @($state.sessions)) {
      if ($null -eq $s) { continue }
      [void]$sb.Append('s=').Append((Safe-Str $s.id '')).Append('|').Append((Safe-Str $s.status '')).Append('|')
      [void]$sb.Append((Safe-Str $s.title '')).Append('|').Append((Safe-Str $s.activity '')).Append(';')
    }
    $a = $state.ask
    if ($null -ne $a) {
      [void]$sb.Append('a=').Append((Safe-Str $a.id '')).Append('|').Append((Safe-Str $a.kind '')).Append('|')
      [void]$sb.Append((Safe-Str $a.title '')).Append('|').Append((Safe-Str $a.note '')).Append('|')
      [void]$sb.Append((Safe-Str $a.detail '')).Append('|').Append((Safe-Str $a.meta '')).Append('|')
      [void]$sb.Append([int][bool]$a.multiSelect).Append(';')
      foreach ($it in @($a.items)) {
        if ($null -eq $it) { continue }
        [void]$sb.Append('i=').Append((Safe-Str $it.id '')).Append('|').Append((Safe-Str $it.header '')).Append('|')
        [void]$sb.Append((Safe-Str $it.question '')).Append('|').Append((Safe-Str $it.detail '')).Append('|')
        [void]$sb.Append([int][bool]$it.multiSelect).Append(';')
        foreach ($o in @($it.options)) {
          if ($null -eq $o) { continue }
          [void]$sb.Append('o=').Append((Safe-Str $o.id '')).Append('|').Append((Safe-Str $o.label '')).Append('|')
          [void]$sb.Append((Safe-Str $o.style '')).Append('|').Append((Safe-Str $o.description '')).Append(';')
        }
      }
      foreach ($o in @($a.options)) {
        if ($null -eq $o) { continue }
        [void]$sb.Append('x=').Append((Safe-Str $o.id '')).Append('|').Append((Safe-Str $o.label '')).Append(';')
      }
    } else {
      [void]$sb.Append('a=;')
    }
  }
  return $sb.ToString()
}

# --- 高度自适应：44(标题栏) + 行高×min(行数,6) + 底部内边距；下限 132、上限 360 ---
function Compute-DesiredHeight([int]$rows, [bool]$hasAsk, [bool]$offline, [bool]$collapsed) {
  if ($collapsed) { return [double]$script:CollapsedHeight }
  if ($hasAsk) { return [double]$script:ExpandedHeight }        # 有卡片固定 360，卡片优先
  $n = [Math]::Min([Math]::Max($rows, 0), 6)
  if ($rows -gt 6) { return [double]$script:ExpandedHeight }    # >6 行锁 360，列表内部滚动
  $h = 44 + ($n * 36) + 10
  if ($offline) { $h += 30 }                                    # 离线提示条占位
  if ($h -lt 132) { $h = 132 }
  if ($h -gt 360) { $h = 360 }
  return [double]$h
}

# 窗口当前所在屏的工作区（DIP）；拿不到就用主屏
function Get-WindowWorkAreaDip {
  try {
    $rect = Get-WindowPhysicalRect
    if ($rect.w -gt 0) {
      $cx = $rect.x + [int]($rect.w / 2)
      $cy = $rect.y + [int]($rect.h / 2)
      foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
        $b = $s.Bounds
        if ($cx -ge $b.Left -and $cx -lt $b.Right -and $cy -ge $b.Top -and $cy -lt $b.Bottom) {
          $dpi = Get-DpiForPoint ([int]($b.Left + 4)) ([int]($b.Top + 4))
          $k = $dpi / 96.0
          if ($k -le 0.1) { $k = 1.0 }
          $wa = $s.WorkingArea
          return @{ left = [double]$wa.Left / $k; top = [double]$wa.Top / $k; right = [double]$wa.Right / $k; bottom = [double]$wa.Bottom / $k }
        }
      }
    }
  } catch { }
  try {
    $wa = [System.Windows.SystemParameters]::WorkArea
    return @{ left = [double]$wa.Left; top = [double]$wa.Top; right = [double]$wa.Right; bottom = [double]$wa.Bottom }
  } catch { }
  return $null
}

function Animate-WindowHeight([double]$target) {
  $win = $script:window
  $cur = [double]$win.Height
  if ([Math]::Abs($target - $cur) -lt 0.5) { return }
  $script:heightAnimTarget = $target
  $anim = [System.Windows.Media.Animation.DoubleAnimation]::new()
  $anim.From = $cur
  $anim.To = $target
  $anim.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(120))
  $ease = [System.Windows.Media.Animation.CubicEase]::new()
  $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
  $anim.EasingFunction = $ease
  $anim.Add_Completed({
      param($snd, $e)
      try {
        $script:window.BeginAnimation([System.Windows.FrameworkElement]::HeightProperty, $null)
        $script:window.Height = [double]$script:heightAnimTarget
      } catch { }
    })
  $win.BeginAnimation([System.Windows.FrameworkElement]::HeightProperty, $anim)
}

# 应用目标高度：长高前先保证不越出工作区底边；缩小走 120ms 动画
function Apply-WindowHeight([double]$target, [bool]$animate) {
  $win = $script:window
  $cur = [double]$win.Height
  if ([Math]::Abs($target - $cur) -lt 0.5) { return }
  if ($target -gt $cur) {
    try {
      $wa = Get-WindowWorkAreaDip
      if ($null -ne $wa -and $wa.bottom -gt 0) {
        $maxTop = [double]$wa.bottom - $target - 4
        if ([double]$win.Top -gt $maxTop) {
          $win.Top = [Math]::Max([double]$wa.top, $maxTop)
        }
      }
    } catch { }
  }
  if ($animate) {
    Animate-WindowHeight $target
  } else {
    $win.BeginAnimation([System.Windows.FrameworkElement]::HeightProperty, $null)
    $win.Height = $target
  }
}

function Update-WindowHeight {
  if ($script:closing) { return }
  $target = Compute-DesiredHeight $script:rowCount $script:hasAsk $script:offline $script:collapsed
  $cur = [double]$script:window.Height
  if ([Math]::Abs($target - $cur) -lt 0.5) { return }
  if ($target -gt $cur) { Apply-WindowHeight $target $false }  # 放大瞬时（内容已就位前先量好）
  else { Apply-WindowHeight $target $true }                    # 缩小 120ms 平滑
}

function Apply-State($state) {
  $script:clockNow = Safe-Num $state.now (NowMs)
  if ($script:clockNow -le 0) { $script:clockNow = NowMs }

  if ($script:offline) {
    $script:offline = $false
    Log 'online: 轮询恢复'
  }

  $notice = Safe-Str $state.notice ''
  if ($notice -ne $script:lastNotice) {
    $script:lastNotice = $notice
    if ($notice) {
      if ($notice.Length -gt 100) { $notice = $notice.Substring(0, 100) + '…' }
      $script:noticeText = $notice
      $script:noticeUntil = (NowMs) + 4000
    }
  }

  $sig = Get-StateSignature $state
  if ($sig -ne $script:lastSig) {
    $script:lastSig = $sig
    # 先按本帧数据预判目标高度：会长高就先长，避免卡片/新行出现时被裁一帧
    $willRows = 0
    foreach ($s in @($state.sessions)) { if ($null -ne $s) { $willRows++ } }
    $willAsk = $false
    if ($null -ne $state.ask) {
      $aid = Safe-Str $state.ask.id ''
      if ($aid -and -not ($aid -eq $script:suppressAskId -and (NowMs) -lt $script:suppressUntil)) { $willAsk = $true }
    }
    $targetH = Compute-DesiredHeight $willRows $willAsk $script:offline $script:collapsed
    if ($targetH -gt [double]$script:window.Height + 0.5) { Apply-WindowHeight $targetH $false }
    # 先渲染 ask：会话行右侧的「等待授权 / 等待选择」依赖当前 ask
    Render-Ask $state.ask
    Render-Sessions $state.sessions
    Update-Title $state
    Apply-Chrome
    Update-WindowHeight
  } else {
    Update-RelTimes
    Update-WindowHeight
  }
}

function Exit-Offline {
  # 连续离线 60 次（约 60s）：上报一次几何后自行退出。
  # 否则 DSH 重启后新 Host 拉起新窗，旧的会留在桌面上当孤儿置顶窗。
  Log 'offline: 连续 60 次轮询失败，自行退出'
  try { Send-WindowMoved } catch { }
  $script:closing = $true
  try { $script:pollTimer.Stop() } catch { }
  try { $script:footTimer.Stop() } catch { }
  try { $script:window.Close() } catch { }
  Start-Sleep -Milliseconds 120
  [Environment]::Exit(0)
}

function Invoke-Poll {
  if ($script:closing) { return }
  if ($script:dragging) { return }

  try {
    $state = Invoke-GetState
    $script:failCount = 0
    $script:offlineStreak = 0
$script:lastTitleDown = 0
$script:dragStart = $null
$script:askNoteActive = $false
$script:heightAnimTarget = [double]$script:ExpandedHeight
    $script:lastPollOk = $true
    Apply-State $state
    if ($script:offline) { Set-Offline $false }
  } catch {
    $script:lastPollOk = $false
    $err = $_.Exception.Message
    $script:failCount++
    if ($script:failCount -ge 2 -and -not $script:offline) { Set-Offline $true }
    if ($script:offline) {
      $script:offlineStreak++
      if ($script:offlineStreak -ge 60) { Exit-Offline; return }
    }
    if ($script:failCount -eq 2 -or ($script:failCount % 30) -eq 0) { Log "poll fail #$($script:failCount): $err" }
  }
}

# ---------------------------------------------------------------------------
# 10. 动作
# ---------------------------------------------------------------------------

function Wake-DshWindow {
  if (-not ('MbNative' -as [type])) { return }
  try {
    $pids = @()
    $mainHwnd = [IntPtr]::Zero
    foreach ($p in [System.Diagnostics.Process]::GetProcesses()) {
      try {
        $pn = $p.ProcessName
        if (-not $pn) { continue }
        if ($p.Id -eq $PID) { continue }
        if ($pn -match 'DeepSeek' -or $pn -match 'Harness' -or $pn -match 'dsh') {
          $pids += [uint32]$p.Id
          if ($mainHwnd -eq [IntPtr]::Zero -and $p.MainWindowHandle -ne [IntPtr]::Zero) {
            $mainHwnd = $p.MainWindowHandle
          }
        }
      } catch { }
    }
    if ($mainHwnd -eq [IntPtr]::Zero -and $pids.Count -gt 0) {
      $mainHwnd = [MbNative]::FindAppWindow([uint32[]]$pids)
    }
    if ($mainHwnd -eq [IntPtr]::Zero) {
      Log 'wake: 未找到 DeepSeek Harness 主窗口，只发 /action'
      return
    }
    if ([MbNative]::IsIconic($mainHwnd)) { $null = [MbNative]::ShowWindow($mainHwnd, 9) }
    else { $null = [MbNative]::ShowWindow($mainHwnd, 5) }
    if (-not [MbNative]::SetForegroundWindow($mainHwnd)) {
      try {
        $fg = [MbNative]::GetForegroundWindow()
        [uint32]$pidFg = 0
        [uint32]$pidTgt = 0
        $tidFg = [MbNative]::GetWindowThreadProcessId($fg, [ref]$pidFg)
        $tidTgt = [MbNative]::GetWindowThreadProcessId($mainHwnd, [ref]$pidTgt)
        if ($tidFg -ne 0 -and $tidTgt -ne 0 -and $tidFg -ne $tidTgt) {
          [void][MbNative]::AttachThreadInput($tidFg, $tidTgt, $true)
          [void][MbNative]::SetForegroundWindow($mainHwnd)
          [void][MbNative]::AttachThreadInput($tidFg, $tidTgt, $false)
        }
      } catch { }
    }
    Log ("wake: hwnd=0x{0:X}" -f $mainHwnd.ToInt64())
  } catch {
    Log "wake failed: $($_.Exception.Message)"
  }
}

function Select-Session([string]$sessionId) {
  $r = Invoke-Post '/action' @{ type = 'focus'; sessionId = $sessionId } 900
  if ($null -eq $r -or $r.ok -ne $true) {
    $m = if ($r -and $r.error) { [string]$r.error } else { '聚焦对话失败' }
    Show-Toast $m
  }
  Wake-DshWindow
}

function Open-Main {
  $r = Invoke-Post '/action' @{ type = 'open-main' } 900
  if ($null -eq $r -or $r.ok -ne $true) {
    $m = if ($r -and $r.error) { [string]$r.error } else { '打开主窗失败' }
    Show-Toast $m
  }
  Wake-DshWindow
}

function Focus-FromAsk {
  $sid = $script:askSessionId
  if ($sid) { $null = Invoke-Post '/action' @{ type = 'focus'; sessionId = $sid } 900 }
  Wake-DshWindow
}

function Send-Answer([string]$askId, [string[]]$optionIds, $selections) {
  $body = @{ type = 'answer'; askId = $askId }
  if ($null -ne $selections) {
    $body.selections = $selections
  } else {
    $ids = @($optionIds | Where-Object { $_ })
    if ($ids.Count -eq 0) { return }
    $body.optionIds = $ids
  }

  Set-Submitting $true
  $r = Invoke-Post '/action' $body 1500
  if ($null -ne $r -and $r.ok -eq $true) {
    $script:suppressAskId = $askId
    $script:suppressUntil = (NowMs) + 3000
    Log "answer ok: $askId"
    Hide-Ask
    Apply-Chrome
    Update-WindowHeight
    $script:lastSig = ''
    Invoke-Poll
  } else {
    $m = if ($r -and $r.error) { [string]$r.error } else { '提交失败' }
    Set-Submitting $false
    Show-Toast $m
    Log "answer failed: $askId $m"
  }
}

function Handle-AskOption($act) {
  if ($script:submitting) { return }
  $askId = [string]$act.ask
  $itemId = [string]$act.item
  $oid = [string]$act.opt
  if (-not $askId -or -not $oid) { return }

  Mark-SubmittingTarget $act.lbl
  if (-not $act.multiItem -and -not $act.multi) {
    Send-Answer $askId @($oid) $null
    return
  }

  $cur = @(Get-ItemSel $itemId)
  if ($act.multi) {
    if ($cur -contains $oid) { $new = @($cur | Where-Object { $_ -ne $oid }) }
    else { $new = @($cur + $oid) }
  } else {
    $new = @($oid)
  }
  Set-ItemSel $itemId $new
  Refresh-ItemVisuals $itemId
  Update-SubmitState
}

function Handle-AskSubmit([string]$askId) {
  if ($script:submitting) { return }
  Mark-SubmittingTarget $script:submitLabel
  if ($script:askMultiItem) {
    $selections = @{}
    foreach ($item in $script:askItems) {
      $sel = @(Get-ItemSel $item.id)
      if ($sel.Count -eq 0) { return }
      $selections[$item.id] = @($sel)
    }
    Send-Answer $askId $null $selections
  } else {
    if ($script:askItems.Count -eq 0) { return }
    $sel = @(Get-ItemSel $script:askItems[0].id)
    if ($sel.Count -eq 0) { return }
    Send-Answer $askId @($sel) $null
  }
}

function Invoke-ActTag($tag) {
  if ($null -eq $tag) { return }
  if ($script:submitting -and $tag.kind -ne 'close') { return }
  switch ([string]$tag.kind) {
    'ask-opt' { Handle-AskOption $tag }
    'ask-submit' { Handle-AskSubmit ([string]$tag.ask) }
    'focus-main' { Focus-FromAsk }
    'open' { Open-Main }
    'close' { Close-Box }
    default { }
  }
}

function Show-Toast([string]$msg) {
  if (-not $msg) { $msg = '操作失败' }
  if ($msg.Length -gt 120) { $msg = $msg.Substring(0, 120) + '…' }
  $script:toastText = $msg
  $script:toastUntil = (NowMs) + 1500
  Update-Footer
}

function Update-Footer {
  if ($script:collapsed) {
    if ($script:ui.FootBar.Visibility -ne [System.Windows.Visibility]::Collapsed) {
      $script:ui.FootBar.Visibility = [System.Windows.Visibility]::Collapsed
    }
    return
  }
  $now = NowMs
  $text = ''
  $brush = $null
  if ($script:toastText -and $now -lt $script:toastUntil) {
    $text = $script:toastText
    $brush = $script:BrDanger
  } elseif ($script:noticeText -and $now -lt $script:noticeUntil) {
    $text = $script:noticeText
    $brush = $script:BrBrand
  }
  if ($text) {
    if ($script:ui.FootText.Text -ne $text) { $script:ui.FootText.Text = $text }
    if (-not [object]::ReferenceEquals($script:ui.FootText.Foreground, $brush)) { $script:ui.FootText.Foreground = $brush }
    if ($script:ui.FootBar.Visibility -ne [System.Windows.Visibility]::Visible) {
      $script:ui.FootBar.Visibility = [System.Windows.Visibility]::Visible
    }
  } else {
    if ($script:ui.FootText.Text) { $script:ui.FootText.Text = '' }
    if ($script:ui.FootBar.Visibility -ne [System.Windows.Visibility]::Collapsed) {
      $script:ui.FootBar.Visibility = [System.Windows.Visibility]::Collapsed
    }
  }
}

# ---------------------------------------------------------------------------
# 11. 窗口几何 / 折叠
# ---------------------------------------------------------------------------

function Get-WindowPhysicalRect {
  $r = [MbNative+RECT]::new()
  if ('MbNative' -as [type]) {
    try {
      if ([MbNative]::GetWindowRect($script:Hwnd, [ref]$r)) {
        return @{ x = $r.Left; y = $r.Top; w = ($r.Right - $r.Left); h = ($r.Bottom - $r.Top) }
      }
    } catch { }
  }
  return @{ x = 0; y = 0; w = 0; h = 0 }
}

function Send-WindowMoved {
  $rect = Get-WindowPhysicalRect
  $body = @{
    type = 'moved'
    x = [int]$rect.x
    y = [int]$rect.y
    w = [int]$rect.w
    h = [int]$rect.h
    collapsed = [bool]$script:collapsed
  }
  $null = Invoke-Post '/window' $body 900
}

function Send-WindowReady {
  if ($script:readySent) { return }
  $script:readySent = $true
  $null = Invoke-Post '/window' @{ type = 'ready' } 900
  Log 'window: ready sent'
}

function Send-WindowCollapsed {
  $null = Invoke-Post '/window' @{ type = 'collapsed'; collapsed = [bool]$script:collapsed } 900
}

function Set-Collapsed([bool]$value, [bool]$notify) {
  if ($script:collapsed -eq $value) {
    if ($notify) { Send-WindowCollapsed }
    return
  }
  $script:collapsed = $value
  $script:window.BeginAnimation([System.Windows.FrameworkElement]::HeightProperty, $null)
  $script:window.Height = Compute-DesiredHeight $script:rowCount $script:hasAsk $script:offline $value
  Apply-Chrome
  Update-Footer
  Set-CountsText
  Update-Pulse
  if (-not $value) {
    $script:lastSig = ''
    if ($script:lastPollOk) { Invoke-Poll }
  }
  Log "window: collapsed=$value"
  if ($notify) {
    Send-WindowCollapsed
    Send-WindowMoved
  }
}

function Toggle-Collapse {
  Set-Collapsed (-not $script:collapsed) $true
}

# ---------------------------------------------------------------------------
# 12. 生命周期
# ---------------------------------------------------------------------------

function Close-Box {
  if ($script:closing) { return }
  $script:closing = $true
  try { if ($script:pollTimer) { $script:pollTimer.Stop() } } catch { }
  try { if ($script:footTimer) { $script:footTimer.Stop() } } catch { }
  try {
    if (-not $script:closeSent) {
      $script:closeSent = $true
      $null = Invoke-Post '/action' @{ type = 'close' } 700
      Log 'window: close action sent'
    }
  } catch { }
  try { $script:window.Close() } catch { }
}

function On-Loaded {
  try {
    $script:Hwnd = [IntPtr]::Zero
    if ('MbNative' -as [type]) {
      $helper = [System.Windows.Interop.WindowInteropHelper]::new($script:window)
      $script:Hwnd = $helper.Handle
    }
    Log ("window: loaded hwnd=0x{0:X} size={1}x{2}" -f $script:Hwnd.ToInt64(), $script:window.ActualWidth, $script:window.ActualHeight)
    if ('MbNative' -as [type] -and $null -ne $script:targetPhys) {
      try {
        $rect = Get-WindowPhysicalRect
        if ($rect.w -gt 0) {
          $dx = [Math]::Abs($rect.x - [int]$script:targetPhys.x)
          $dy = [Math]::Abs($rect.y - [int]$script:targetPhys.y)
          if ($dx -gt 2 -or $dy -gt 2) {
            [void][MbNative]::SetWindowPos($script:Hwnd, [IntPtr]::Zero, [int]$script:targetPhys.x, [int]$script:targetPhys.y, 0, 0, 0x0001 -bor 0x0004)
          }
        }
      } catch { }
    }
    Send-WindowReady
    if (-not $script:lastPollOk) { Invoke-Poll }
  } catch {
    Log "loaded handler failed: $($_.Exception.Message)"
  }
}

function On-Closing {
  if (-not $script:closing) {
    $script:closing = $true
    try { if ($script:pollTimer) { $script:pollTimer.Stop() } } catch { }
    try { if ($script:footTimer) { $script:footTimer.Stop() } } catch { }
    try {
      if (-not $script:closeSent) {
        $script:closeSent = $true
        $null = Invoke-Post '/action' @{ type = 'close' } 700
      }
    } catch { }
  }
}

# ---------------------------------------------------------------------------
# 13. 事件接线
# ---------------------------------------------------------------------------

$titleBar = $script:ui.TitleBar
# 标题栏拖动：自己跟踪鼠标（不使用 DragMove 的模态循环，否则双击会被吞掉）
$titleBar.Add_MouseLeftButtonDown({
    param($snd, $e)
    $now = NowMs
    if ($e.ClickCount -ge 2 -or (($now - $script:lastTitleDown) -lt 420 -and $script:lastTitleDown -gt 0)) {
      $script:lastTitleDown = 0
$script:dragStart = $null
      $e.Handled = $true
      Toggle-Collapse
      return
    }
    $script:lastTitleDown = $now
    $p = [System.Windows.Forms.Cursor]::Position
    $script:dragStart = @{
      sx = [int]$p.X
      sy = [int]$p.Y
      wx = [double]$script:window.Left
      wy = [double]$script:window.Top
      moved = $false
    }
    $script:dragging = $true
    try { [void]$snd.CaptureMouse() } catch { }
    $e.Handled = $true
  })
$titleBar.Add_MouseMove({
    param($snd, $e)
    if (-not $script:dragging -or $null -eq $script:dragStart) { return }
    $p = [System.Windows.Forms.Cursor]::Position
    $dx = ([double]$p.X - [double]$script:dragStart.sx) / $script:Scale
    $dy = ([double]$p.Y - [double]$script:dragStart.sy) / $script:Scale
    if ([Math]::Abs($dx) -gt 1.5 -or [Math]::Abs($dy) -gt 1.5) { $script:dragStart.moved = $true }
    $script:window.Left = [double]$script:dragStart.wx + $dx
    $script:window.Top = [double]$script:dragStart.wy + $dy
  })
$titleBar.Add_MouseLeftButtonUp({
    param($snd, $e)
    if (-not $script:dragging) { return }
    $script:dragging = $false
    try { [void]$snd.ReleaseMouseCapture() } catch { }
    $moved = $false
    if ($null -ne $script:dragStart) { $moved = [bool]$script:dragStart.moved; $script:dragStart = $null }
    if ($moved) { Send-WindowMoved }
    $e.Handled = $true
  })

foreach ($btnKey in @('BtnMain', 'BtnClose')) {
  $btn = $script:ui[$btnKey]
  if ($null -eq $btn) { continue }
  $btn.Add_MouseLeftButtonDown({ param($snd, $e) $e.Handled = $true })
}
$script:ui.BtnMain.Add_MouseEnter({ param($snd, $e) $snd.Background = $script:BrIconHoverBg; $script:ui.IconMain.Stroke = $script:BrIconHover })
$script:ui.BtnMain.Add_MouseLeave({ param($snd, $e) $snd.Background = $script:BrTransparent; $script:ui.IconMain.Stroke = $script:BrIcon })
$script:ui.BtnMain.Add_MouseLeftButtonUp({ param($snd, $e) $e.Handled = $true; Open-Main })
$script:ui.BtnClose.Add_MouseEnter({ param($snd, $e) $snd.Background = $script:BrIconHoverBg; $script:ui.IconClose.Stroke = $script:BrIconHover })
$script:ui.BtnClose.Add_MouseLeave({ param($snd, $e) $snd.Background = $script:BrTransparent; $script:ui.IconClose.Stroke = $script:BrIcon })
$script:ui.BtnClose.Add_MouseLeftButtonUp({ param($snd, $e) $e.Handled = $true; Close-Box })

$script:window.Add_Loaded({ On-Loaded })
$script:window.Add_Closing({ On-Closing })
$script:window.Add_MouseRightButtonUp({ param($snd, $e) $e.Handled = $true })

$script:pollTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:pollTimer.Interval = [TimeSpan]::FromMilliseconds($script:PollMs)
$script:pollTimer.Add_Tick({ Invoke-Poll })

$script:footTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:footTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:footTimer.Add_Tick({ Update-Footer })

# ---------------------------------------------------------------------------
# 14. 首帧位置（Show 之前就摆好，避免启动闪一下）
# ---------------------------------------------------------------------------

$script:PlacementMarginDip = 16   # 贴边留 16 DIP（125% 下 = 20 物理像素）

function Get-DpiForPoint([int]$x, [int]$y) {
  if ('MbNative' -as [type]) {
    try { $d = [MbNative]::GetDpiForPoint($x, $y); if ($d -gt 0) { return [double]$d } } catch { }
  }
  return [double]$script:Dpi
}

# 每块屏的工作区，换算成各自 DPI 下的 DIP 坐标
function Get-WorkAreasDip {
  $out = @()
  try {
    foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
      $wa = $s.WorkingArea
      $dpi = Get-DpiForPoint ([int]($wa.Left + 4)) ([int]($wa.Top + 4))
      $sc = $dpi / 96.0
      if ($sc -le 0.1) { $sc = 1.0 }
      $out += @{
        left   = [double]$wa.Left / $sc
        top    = [double]$wa.Top / $sc
        right  = [double]$wa.Right / $sc
        bottom = [double]$wa.Bottom / $sc
        dpi    = $dpi
      }
    }
  } catch { }
  return $out
}

# 默认位置：主屏工作区右下角，全程用 WPF 的 DIP 值算
function Get-DefaultPosDip([double]$wDip, [double]$hDip) {
  $m = [double]$script:PlacementMarginDip
  $wa = $null
  try { $wa = [System.Windows.SystemParameters]::WorkArea } catch { }
  if ($null -ne $wa -and $wa.Width -gt 1 -and $wa.Height -gt 1) {
    return @{
      x    = [Math]::Max([double]$wa.Left, [double]$wa.Right - $wDip - $m)
      y    = [Math]::Max([double]$wa.Top, [double]$wa.Bottom - $hDip - $m)
      area = @{ left = [double]$wa.Left; top = [double]$wa.Top; right = [double]$wa.Right; bottom = [double]$wa.Bottom; dpi = [double]$script:Dpi }
    }
  }
  # 兜底：主屏物理工作区按系统 DPI 换 DIP
  $sc = $script:Scale
  $pwa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  return @{
    x    = [Math]::Max(0.0, [double]$pwa.Right / $sc - $wDip - $m)
    y    = [Math]::Max(0.0, [double]$pwa.Bottom / $sc - $hDip - $m)
    area = @{ left = 0.0; top = 0.0; right = [double]$pwa.Right / $sc; bottom = [double]$pwa.Bottom / $sc; dpi = [double]$script:Dpi }
  }
}

# Host 给的 app.window（物理像素）→ 校验 → 输出最终 DIP 位置
function Resolve-WindowPosDip($geom, [double]$wDip, [double]$hDip) {
  $def = Get-DefaultPosDip $wDip $hDip
  if ($null -eq $geom) { return $def }

  # 缺 x/y、非数字、NaN/Inf → 当作「没有保存过位置」，走默认位置
  $xr = $null; $yr = $null
  try {
    if ($null -ne $geom.x -and $null -ne $geom.y) {
      $xv = [double]$geom.x; $yv = [double]$geom.y
      if (-not [double]::IsNaN($xv) -and -not [double]::IsInfinity($xv) -and -not [double]::IsNaN($yv) -and -not [double]::IsInfinity($yv)) {
        $xr = $xv; $yr = $yv
      }
    }
  } catch { }
  if ($null -eq $xr) { return $def }

  # 物理像素 → DIP（按该点所在屏的 DPI）
  $dpi = Get-DpiForPoint ([int][Math]::Round($xr)) ([int][Math]::Round($yr))
  $sc = $dpi / 96.0
  if ($sc -le 0.1) { $sc = 1.0 }
  $xd = $xr / $sc
  $yd = $yr / $sc

  # 与某块屏工作区交集 ≥ 80×60 才采用（拔屏 / 改分辨率后旧坐标不能把窗口丢到屏幕外）
  $best = $null; $bestArea = 0.0
  foreach ($a in @(Get-WorkAreasDip)) {
    $ovW = [Math]::Min($xd + $wDip, [double]$a.right) - [Math]::Max($xd, [double]$a.left)
    $ovH = [Math]::Min($yd + $hDip, [double]$a.bottom) - [Math]::Max($yd, [double]$a.top)
    if ($ovW -ge 80 -and $ovH -ge 60) {
      $ar = $ovW * $ovH
      if ($ar -gt $bestArea) { $bestArea = $ar; $best = $a }
    }
  }
  if ($null -eq $best) { return $def }

  # clamp 进该工作区
  $x = [Math]::Min([Math]::Max($xd, [double]$best.left + 2), [Math]::Max([double]$best.left + 2, [double]$best.right - $wDip - 2))
  $y = [Math]::Min([Math]::Max($yd, [double]$best.top + 2), [Math]::Max([double]$best.top + 2, [double]$best.bottom - $hDip - 2))
  return @{ x = $x; y = $y; area = $best }
}

$firstState = $null
try { $firstState = Invoke-GetState } catch { Log "pre-show poll failed: $($_.Exception.Message)" }

if ($null -ne $firstState) {
  try { Apply-State $firstState } catch { Log "pre-show apply failed: $($_.Exception.Message)" }
}

$geom = $null
if ($null -ne $firstState -and $null -ne $firstState.app -and $null -ne $firstState.app.window) {
  $geom = $firstState.app.window
}
if ($null -ne $geom -and [bool]$geom.collapsed) { $script:collapsed = $true }

$wDips = [double]$script:BaseWidth
$firstRows = 0
$firstAsk = $false
if ($null -ne $firstState) {
  foreach ($s in @($firstState.sessions)) { if ($null -ne $s) { $firstRows++ } }
  if ($null -ne $firstState.ask -and (Safe-Str $firstState.ask.id '')) { $firstAsk = $true }
}
$hDips = Compute-DesiredHeight $firstRows $firstAsk $script:offline $script:collapsed

$placement = Resolve-WindowPosDip $geom $wDips $hDips
$placeDpi = [double]$placement.area.dpi
if ($placeDpi -le 0) { $placeDpi = [double]$script:Dpi }
$script:targetPhys = @{
  x = [int][Math]::Round([double]$placement.x * $placeDpi / 96.0)
  y = [int][Math]::Round([double]$placement.y * $placeDpi / 96.0)
}

$script:window.Width = $wDips
$script:window.Height = $hDips
$script:window.Left = [double]$placement.x
$script:window.Top = [double]$placement.y

Log ("pre-show: dip={0},{1} -> phys={2},{3} dpi={4} collapsed={5} hasGeom={6} hasXY={7}" -f `
    [int]$placement.x, [int]$placement.y, $script:targetPhys.x, $script:targetPhys.y, $placeDpi, `
    $script:collapsed, ($null -ne $geom), ($null -ne $geom -and $null -ne $geom.x))

Apply-Chrome
Update-Footer
if ($script:collapsed) { Set-CountsText; Update-Pulse }

$script:pollTimer.Start()
$script:footTimer.Start()

try {
  [void]$script:window.ShowDialog()
} catch {
  Log "fatal: show failed: $($_.Exception.Message)"
  [Environment]::Exit(4)
}

try { $script:pollTimer.Stop() } catch { }
try { $script:footTimer.Stop() } catch { }
Log 'exit'
[Environment]::Exit(0)
