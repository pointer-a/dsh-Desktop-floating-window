# dsh-taskbox 小窗自测记录（minibox.ps1）

- 版本：minibox 1.1.0（PowerShell 5.1 + WPF，单文件，无第三方依赖）
- 机器：Windows 11 26100，主屏 2560×1440 @125%（120 DPI，工作区 2540×1380 物理）；系统主题浅色
- 联调对端：`mock/mock-host.mjs`（v1 + v1.1 增补）＋ Host 半区真机联调
- 正片：`docs/shots/v3-*.png`、`v4-default-placement.png`、`v5-compact-dark.png`、`v5-card-dark.png`；开发脚手架在 `docs/dev/`

## 1. 启动与参数

```
powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -WindowStyle Hidden \
  -File pkg\assets\minibox\minibox.ps1 -Port <port> -Token <token> -AssetDir <dir> [-Theme auto|dark|light]
```

- `-Theme` 仅调试/截图用；Host 不传 = 跟随 `HKCU\...\Personalize\AppsUseLightTheme`。
- 参数非法（Port ∉ 1–65535、Token 为空）→ stderr 明确报错 + 退出码 2。
- stderr 第一行打印日志落点：`minibox: log file: <path>`；日志三级回退
  `$DSH_HOME\task-box` → `%USERPROFILE%\.dsh\task-box` → `%TEMP%\dsh-taskbox`。

## 2. 位置（默认 / 记忆 / 校验）

- **默认位置**：`[System.Windows.SystemParameters]::WorkArea`（WPF 的 DIP 值，已排除任务栏）
  → `Left = max(wa.Left, wa.Right - 320 - 16)`、`Top = max(wa.Top, wa.Bottom - H - 16)`，
  即主屏工作区右下角留 16 DIP（125% 下 = 20 物理像素）。
- **Host 给的 `app.window`**（`x/y` 口径 = 物理像素）：
  - 缺 `x`/`y`、非数字、NaN/Inf → 视为「没有保存位置」，走默认位置（不会当 (0,0)）；
  - 有 `x/y` → 按该点所在显示器的有效 DPI（`GetDpiForMonitor`）换算成 DIP；
  - 与某块屏工作区交集 ≥ 80×60 DIP 才采用，否则回默认位置；采用时 clamp 进该工作区；
  - 折算成物理目标后，`Loaded` 时用 `SetWindowPos` 再校正一次（消除多屏 DPI 换算误差）。
- **实测**（工作区右下 2560×1380 物理，期望窗口 right≈2540、bottom≈1360）：

| 用例 | 输入 | 结果 |
|---|---|---|
| A | mock 不给 `app.window` | `2140,910..2540,1360` → 距工作区右下各 20px **PASS** |
| B | `app.window={x:9000,y:9000}`（离谱坐标） | 同 A，回默认右下角 **PASS** |
| C | `app.window={collapsed:false}`（无 x/y） | 同 A，**PASS**（不再是 24,24） |

- 全景截图：`docs/shots/v4-default-placement.png`。

## 3. 高度自适应

- 高度 = `44(标题栏) + 36×min(行数,6) + 10(底部内边距)`，下限 132、上限 360；行数 > 6 锁 360，列表内部滚动。
- **有待确认卡片时固定 360**（卡片优先）；卡片消失后自动收回紧凑高度。
- 宽度 320 不变；**顶边为锚点**（`Top` 不动，只改 `Height`）。长高时若底边会越出工作区，先把 `Top` 上移最小距离，保证卡片不出屏。
- 不裁切的顺序保证：长高前先按本帧「行数 + 是否有卡片」算好目标高度并先长高，再渲染内容；
  缩小在内容隐藏后走 120ms `DoubleAnimation`（`Height`，CubicEase EaseOut），完成回调落定基础值。
- 折叠态 44 不变；拖拽记忆位置仍走 `app.window`，与自适应无关。

实测（125%）：

| 场景 | 行数/卡片 | 实测高度 |
|---|---|---|
| `empty` | 0 行 | 165px（132 DIP）PASS |
| `idle` | 3 行 | 203px（162.4 DIP）PASS |
| `running` | 4 行 | 248px（198.4 DIP）PASS |
| `approval` / `multi` | 有卡片 | 450px（360 DIP）PASS |
| 同一实例：卡片态 → 答两次 → 卡片消失 | 3 行 | 450→203px（162.4 DIP），`Top` 保持 910 不变 PASS |

截图：`docs/shots/v5-compact-dark.png`（3 行紧凑态 400×203）、`docs/shots/v5-card-dark.png`（卡片态 400×450）。

## 4. 场景截图

| 场景 | 结果 | 截图 |
|---|---|---|
| `approval` 工具授权（深色） | waiting 行琥珀底 + 3px 左条 + 右侧「等待授权」；贴底面板「需要授权 · bash」chip、自然语言题干、等宽命令块、允许（品牌蓝）/拒绝（ghost 红）；按钮底沿距窗口下沿 21px | `v3-approval-dark.png` |
| `approval` 工具授权（浅色） | 浅色一套；**底板纯不透明 `#F7F8FA`**、waiting 底 `.10`、chip `#A56410` / `rgba(245,166,35,.12)`、描边 `#0000001A`、次级文字 `#6B7280`、命令块 `#F1F3F6`/`#111827`/`#0000000F` | `v3-approval-light.png` |
| 折叠态 | 400×55（=320×44 @125%），只留标题栏 + 一行紧凑摘要「1 待确认」，有待确认时琥珀呼吸描边 | `v3-collapsed-dark.png` |
| `multi` 多问题（v1.1） | 卡片定高 236 DIP：头部 + 可滚动问题区 + **提交行钉底常驻**（提交按钮 y=391–430）；未选满 42% +「还差 N 项」；列表保留 2 行 | `v3-multi-dark.png` |
| `empty` / `idle` / `running` | 空态文案；灰点+次级灰+相对时间；蓝点+白标题+activity；标题栏分段计数 | `v3-empty-dark.png` 等 |
| `question` 单选 | 「需要选择 · 停靠位置」chip、题干 + 补充说明、三行选项 | `v3-question-dark.png` |
| `note` 需输入文字 | 选项区隐藏 + note 提示行 + 主按钮「去主窗口回答」（只发 `focus`） | `v3-note-dark.png` |
| 离线 | 标题「离线」、灰点、顶部「连接中断，正在重试…」、保留最后数据 | `v3-offline-dark.png` |

## 5. 真机联调（Host 半区）

- 拉起参数 / 进程 / HTTP 全通；轮询到真实会话；点「允许一次」→ Host `approval/request` 收到 `allowed-once`；`/action close` 后干净退出。
- 真机浅色主题反馈已修：卡片底部内边距 14 DIP + 卡片总高硬上限（单组 240 / 多组 236）保证
  `标题栏 44 + ≥2 行会话 + 卡片 ≤ 360`；浅色对比度；waiting 行右侧改状态语；浅色底板改纯不透明。
- 真机「只有 1 个对话时下方大片空白」→ 已做高度自适应（§3）。

## 6. 生命周期

- `POST /window {"type":"ready"}`：窗口 Loaded 后一次。
- `POST /window {"type":"moved",x,y,w,h,collapsed}`：拖动松手、折叠/展开后发送。
- `POST /window {"type":"collapsed"}`：双击标题栏后发送（本机沙箱禁输入注入，折叠正片走 Host 记忆的
  `app.window.collapsed=true` 重启窗口拍，高度实测 55 物理像素）。
- 离线自退：连续 60 次 `/state` 失败 → 先 `POST /window moved` 上报几何 → 自行退出（实测进程退出）。
- 关闭：`POST /action close` → `Window.Close()` → `ShowDialog` 返回 → `[Environment]::Exit(0)`。

## 7. 视觉/实现要点

- DPI：创建窗口前 `SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)`，失败退 DPI_AWARE / System Aware。
- 主题：深色面板 97% 不透明；浅色面板**纯不透明** `#F7F8FA` + `#0000001A` 描边；圆角 14、1px 描边；
  状态色 running `#2B7FFF` / waiting `#F5A623`（浅色 `#A56410`）/ idle `#8A8A8E`。
- 图标全部 `Path` 几何自绘（16px，1.35 描边），无 emoji、无字符图标。
- 会话行：高 34 + 2px 间隔；waiting 行整行琥珀底（深 `.08` / 浅 `.10`）+ 3px 左条 + 半粗标题 +
  右侧状态语（琥珀，不显示 activity/相对时间）；非 waiting = activity → 相对时间。
- 标题栏计数三段上色（待确认琥珀 / 进行中品牌蓝 / 对话数次级灰），分隔符 60%。
- 刷新：`rev`/内容签名未变只更新相对时间与 waiting 状态语，不重建行与卡片；结构变化才重建并保留滚动位置。
- 确认卡片：贴底停靠（1px 分隔线）；题干 14px sans 与「原文」等宽块分开排；chip 整条同色、分隔符 60%；
  多组 = 头部 + 可滚动问题区 + 提交行钉底；提交反馈 = 按钮「已提交…」灰态 + 整卡 120ms 淡出。
- 失败只在底栏红字 1.5s，不弹窗。

## 8. 遗留项 / 未覆盖

1. 本机沙箱禁止输入注入（`SetCursorPos`/`mouse_event` 返回 False，`PostMessage`/`SendMessage` 触发不了 WPF 输入），
   双击折叠/选项选中态未能本地模拟点击验证；折叠正片走 Host 记忆的 collapsed 状态拍摄，点击/作答由真机联调验证；
   高度自适应里的「答两次让卡片消失」用直接 POST mock `/action` 触发状态推进验证。选中态视觉已实现。
2. 混合 DPI 多显示器未实机验证（本机单屏 125%）；代码按「该点所在屏 DPI」换算并做工作区交集校验。
3. 启动耗时：PowerShell + Add-Type + WPF 冷启动约 4–6s（首帧前完成首次 `/state` 拉取）。
4. 折叠态呼吸描边是 1px 琥珀 1.1s 往返 Opacity 动画，截图可能落在低透明度相位（真机可见）。

## 9. 需要 Host 半区配合 / 协议口径

- `ask` 只给 `items` 即可；`options`/`multiSelect` 作为 items[0] 别名也兼容。
- 多 item 作答：`{"type":"answer","askId":...,"selections":{itemId:[optionId...]}}`；单 item 仍走 `optionIds`。
- `ask.note` 非空：选项区隐藏 + 主按钮「去主窗口回答」→ 只发 `{"type":"focus","sessionId":...}`。
- 工具授权选项 id 固定 `allow`/`deny`，按 `style` 上色（primary 实心品牌蓝、danger ghost 红）。
- `counts.sessions` 是真实总数（「N 对话」），列表行数来自 `sessions.length`（高度自适应也用 `sessions.length`）。
- `app.window` 的 `x/y` 口径 = **物理像素**；`collapsed` 布尔。小窗侧负责 DIP 换算、屏幕外校验与 clamp。
- `ask.detail` 约定：第一行自然语言，其余原文（按 `\n` 拆；单行 detail 时 approval 视为原文进等宽块，question 视为补充说明）。
- waiting 会话右侧优先显示状态语：当前 ask 命中该会话时按 kind/note 生成，否则用 activity（以「等待」开头时）或「等待中」。

## 10. 文件清单

```
pkg/assets/minibox/minibox.ps1      # 全部实现（单文件）
pkg/assets/minibox/SELFTEST.md      # 本文件
docs/shots/v3-*.png                 # 场景正片
docs/shots/v4-default-placement.png # 默认右下角位置全景（贴边 20px）
docs/shots/v5-compact-dark.png      # 高度自适应：3 行紧凑态（400×203）
docs/shots/v5-card-dark.png         # 高度自适应：有卡片 360（400×450）
docs/dev/                           # 开发脚手架（run-*.ps1、test-*.ps1、cap-*.ps1、mock-mini.mjs、_mock-*.log），不属于插件包
```
