# 桌面任务浮窗 —— Host ↔ 小窗 协议 v1

本文件是 **DeepSeek Harness 插件 `dsh-taskbox`** 的两个半区之间的唯一契约：

- **Host 半区** `pkg/lib/index.js`：跑在 DSH Host（Node）进程里，聚合会话/任务/待确认状态，起一个只监听 `127.0.0.1` 的小 HTTP 服务。
- **桌面小窗** `pkg/assets/minibox/minibox.ps1`：由 Host 拉起的一个独立 PowerShell + WPF 置顶窗口进程。它不 import 任何 DSH 代码，只通过本文件的 HTTP 协议读写 Host。

任何一半的改动都必须先改本文件。协议版本号 `v1`。

---

## 1. 拉起参数

Host 用 `child_process.spawn` 拉起小窗（`windowsHide: true`，不显示控制台）：

```
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass \
  -File "<pkgDir>\assets\minibox\minibox.ps1" \
  -Port <port> -Token <token> -AssetDir "<pkgDir>\assets\minibox"
```

| 参数 | 说明 |
|---|---|
| `-Port` | Host 的本地 HTTP 端口（`127.0.0.1` 上，0 以外的具体端口） |
| `-Token` | 每次 Host 启动随机生成的字符串；所有请求都要带上 |
| `-AssetDir` | 小窗自己所在目录，用于 `icon.png` 等资源 |

小窗进程是独立进程：Host 退出时应由 Host 主动 kill；Host 崩溃时小窗会进入「离线」态并继续重试，直到用户点关闭。

**小窗必须做的事**（进程级）：在创建任何窗口之前调用
`SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)`，保证高 DPI 下不模糊。

---

## 2. HTTP 端点

所有端点只监听 `127.0.0.1`。鉴权：

- 请求头 `x-taskbox-token: <token>`，**或** 查询参数 `?t=<token>`。

| 方法 | 路径 | 说明 |
|---|---|---|
| `GET` | `/state` | 取完整状态快照（小窗每 1000ms 轮询一次） |
| `POST` | `/action` | 小窗上的一次用户操作（回答确认 / 打开主窗 / 聚焦会话） |
| `POST` | `/window` | 小窗上报自己的生命周期与几何信息（Host 记住位置） |
| `GET` | `/ping` | 存活探测，返回 `{"ok":true}` |

响应一律 UTF-8 JSON。`GET /state` 在 Host 还没准备好时也必须返回 200 + 合法 envelope（`sessions: []`, `ask: null`），不能 5xx。

### 2.1 `GET /state` 响应

```jsonc
{
  "ok": true,
  "protocol": 1,
  "rev": 128,                       // 单调递增；内容没变就不涨。小窗 rev 未变时跳过重绘
  "now": 1761723000123,             // Host 当前时间（epoch ms）
  "app": {
    "url": "http://127.0.0.1:50285", // DSH Web GUI 地址
    "title": "DeepSeek Harness",
    "online": true
  },
  "counts": { "sessions": 6, "running": 1, "waiting": 1 },
  "sessions": [
    {
      "id": "01JABCDEF...",
      "title": "写一个桌面浮窗插件",   // 会话标题，可能为空 —— 小窗显示「未命名对话」
      "status": "running",            // running | waiting | idle
      "activity": "bash · npm test",  // 当前步骤短语，没有就 ""
      "updatedAt": 1761722990000,     // epoch ms，用于相对时间
      "workspace": "dsh插件"          // 工作区短名，可为空
    }
  ],
  "ask": {                            // 没有待确认时为 null
    "id": "a-3",                      // 稳定 id；同一次待确认轮询之间不变
    "kind": "approval",               // approval | question
    "sessionId": "01JABCDEF...",
    "sessionTitle": "写一个桌面浮窗插件",
    "title": "需要授权",              // approval: 需要授权 / question: 需要选择
    "detail": "允许执行以下命令吗？\nrm -rf dist && npm run build",
    "meta": "cwd=E:\\dsh插件",        // 次要信息，单行，可为空
    "options": [
      { "id": "allow", "label": "允许", "style": "primary" },
      { "id": "deny",  "label": "拒绝", "style": "danger" }
    ],
    "multiSelect": false,             // true 时小窗画复选框 + 「提交」
    "createdAt": 1761722990000,
    "defaultOptionId": "deny"         // 可空；小窗把它画成默认/强调
  },
  "notice": null                       // 可空；一行临时提示（如「主窗已切到该对话」）
}
```

- `sessions` 已由 Host 排好序：`waiting` → `running` → `idle`，同组内 `updatedAt` 降序。
- `sessions` 最多 20 条；`counts.sessions` 是**全部会话数**（`sessionController.list()` 的 items.length，
  可能远大于列表条数），`running` / `waiting` 是当前列表里的计数。
- 会话 `id` 对同一次 DSH 运行稳定，小窗只用来发动作，不要展示。
- `title` 不要含换行；`detail` 可以含 `\n`（小窗最多显示 4 行 + 省略）。
- `app.url` 是 DSH Web GUI 的地址（可能缺省，小窗不依赖它）。

### 2.2 `POST /action` 请求

```jsonc
{ "type": "answer", "askId": "a-3", "optionIds": ["allow"] }
{ "type": "focus",  "sessionId": "01JABCDEF..." }   // 聚焦主窗并切到该会话
{ "type": "open-main" }                              // 只把主窗唤到前台
{ "type": "close" }                                  // 小窗即将关闭（Host 清 pid）
```

响应：`{ "ok": true }` 或 `{ "ok": false, "error": "..." }`（HTTP 状态仍为 200，除非 token 不对 → 401）。

动作语义：

- `answer`：Host 把它当作对挂起确认的选择。`optionIds` 在 `multiSelect: false` 时只有 1 个。成功后 Host 必须在 ≤200ms 内让该 `ask` 从 `/state` 消失。
- `focus`：Host 记录「请主窗切到 sessionId」的待处理请求，并唤醒主窗（焦点移动由小窗本地 Win32 完成）。主窗侧最迟 1.5s 内轮询/推送到达。
- 小窗对任何失败都只做轻量提示（底栏一行红字 1.5s），**不弹窗**。

### 2.3 `POST /window` 请求

```jsonc
{ "type": "ready" }
{ "type": "moved", "x": 1200, "y": 760, "w": 320, "h": 360, "collapsed": false }
{ "type": "collapsed", "collapsed": true }
```

Host 持久化 `x/y/w/h/collapsed`（`$DSH_HOME/task-box/window.json`），下次拉起小窗时通过 `/state` 的 `app.window` 下发（字段可缺省，小窗用默认值）：

```jsonc
"app": { "window": { "x": 1200, "y": 760, "collapsed": false } }
```

> 坐标口径：**物理像素（屏幕绝对坐标，多显示器时为虚拟屏幕坐标）**，Host 只做原样存取，不做 DPI 换算。
> 小窗拿到后按 `x / dpiScale` 落到 WPF 的 DIP 坐标；由小窗负责与自己的缩放保持一致。

---

## 3. 小窗行为规格

默认尺寸 **320 × 360**，折叠后 **320 × 44**。无边框、圆角、半透明深色、始终置顶、不占任务栏。

布局（自上而下）：

1. **标题栏（44px，可拖拽）**：左侧状态点 + 「任务」+ `counts` 摘要（如 `3 对话 · 1 进行中`）；右侧两个极小图标按钮：`⤢` 打开主窗、`✕` 关闭。双击标题栏折叠/展开。
2. **会话列表**（可滚动，行高 34px）：状态点 + 标题（超长省略）+ 右侧相对时间或 `activity` 短语。`waiting` 行整行带琥珀色左边条。
3. **待确认卡片**（有 `ask` 时固定贴底，无则隐藏）：标题、`detail`、`meta`、选项按钮行（`multiSelect` 时改为复选列表 + 「提交」）。

交互细节：

- 窗口出现/新 `ask` 到来：卡片淡入 160ms，**不抢焦点、不响铃**。
- 点会话行：`POST /action {type:focus}` → 小窗本地把 DSH 主窗 `ShowWindow(SW_RESTORE)` + `SetForegroundWindow`。
- 点 `⤢`：`POST /action {type:"open-main"}` + 同上唤醒主窗。
- 拖拽移动：松手时 `POST /window {type:"moved",...}`。
- 离线（连续 2 次 `/state` 失败）：标题栏状态点变灰、标题变成「离线」、列表保留最后一次数据并在顶部加一行「连接中断，正在重试…」；恢复后自动清掉。
- **连续离线 60 次（约 60 秒）后进程自行退出**：Host 重启后旧小窗不能变成孤儿窗口（新 Host 会拉起新窗，
  旧的必须自己走掉）。退出前把当前几何 `POST /window` 尽力上报一次。
- 关闭：`POST /action {type:"close"}`，进程退出。

---

## 4. 验收判据

- `curl -H "x-taskbox-token: <t>" http://127.0.0.1:<p>/state` 返回合法 JSON。
- mock（`mock/mock-host.mjs`）能驱动出：空列表 / 纯 idle / 有 running / approval 确认 / 单选 question / 多选 question 六种画面。
- 点「允许」后 mock 记录到 `answer` 动作，且画面在 1s 内推进到下一状态。
- 小窗置顶：当其他窗口最大化在前时仍可见；拖动后位置被记住。

---

## 5. v1.1 增补：一次确认里的多个问题（契约不变，只增字段）

`ask_user_question` 一次可以问 1–4 个问题，所以 `ask` 增加了权威的 `items` 数组；
`options` / `multiSelect` 退化为「第一个 item 的快捷别名」，只认旧形状的小窗照样能用。

```jsonc
"ask": {
  "id": "ask-3",
  "kind": "question",
  "sessionId": "01J...",
  "sessionTitle": "写一个桌面浮窗插件",
  "title": "需要选择",
  "detail": "……第一个问题的 detail……",
  "meta": "头部 · 2 个问题",
  "note": "",                       // 非空时小窗要显示这行提示（例：需要输入文字，请回主窗口）
  "items": [
    {
      "id": "q-id-1",               // DSH 的问题 id；作答时原样回传
      "header": "停靠位置",          // 可为 ""
      "question": "浮窗默认停在哪？",
      "detail": "",
      "multiSelect": false,
      "options": [
        { "id": "o1", "label": "右下角", "style": "primary", "description": "" },
        { "id": "o2", "label": "左下角", "style": "default" }
      ]
    }
  ],
  "options": [ /* = items[0].options，兼容别名 */ ],
  "multiSelect": false
}
```

作答动作：

```jsonc
// 只有一个 item 时（最常见）：
{ "type": "answer", "askId": "ask-3", "optionIds": ["o1"] }
// 多个 item 时：每个 item 都必须给出选择，key 是 item.id
{ "type": "answer", "askId": "ask-3",
  "selections": { "q-id-1": ["o1"], "q-id-2": ["o7", "o9"] } }
```

小窗渲染建议：

- `items.length === 1`：与 v1 完全一致（标题 + detail + 一排选项）。
- `items.length > 1`：每项一组（题干 + 各自的选项/复选框），全部有选择后「提交」才可用；
  卡片内部滚动，不要撑大窗口。
- 工具授权的 `ask` 也走 `items`（1 项，`id` 固定为 `approval`），选项 id 为 `allow` / `deny`。
- `note` 非空时不显示选项（或把它下面的选项置灰），主按钮改成「去主窗口回答」（只发 `focus`）。

