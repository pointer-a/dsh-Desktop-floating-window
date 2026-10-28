# DSH Host 侧 API 契约笔记（api-researcher）

> 环境：DSH 安装目录 `D:\DSH\resources\app.asar`（调研期用临时脚本解包到工作区 `_ref/app/`，该临时目录已删除，脚本思路见本文件「给 Host 实现的建议」）；desktop profile `C:\Users\14578\.dsh\profiles\desktop`
> 出处标注：`[inspect]` = `cordis_inspect_query` 返回值；`[d.ts]`/`[src:行]` = asar 内包源码（`@deepseek-ai/<pkg>/lib/...`）；`未确认` = 无直接来源，附猜测+验证法。
> 本轮按 lead 的收口要求：**A(Q1) / B(Q6) / C(Q7) 写全；Q2/Q5 各给一句话结论；Q3/Q4 保留契约+链路（lead 已定案，这里只补“浏览器链路/race 风险”）**。

---

### Q1 结论：全量会话列表用 Host 服务 `ctx.get('sessionController').list({}, signal)`，返回 `{ items: SessionSummary[] }`（能读到未加载的冷会话，不激活 Agent）；`api-session/*` 事件由同一个包 `@deepseek-ai/dsh-api-session-controller` 发出；`ctx.agents.list()` 只给“进程内存里已加载的 agent”。

- **出处**
  - `[inspect]` host Service `sessionController`：`@Remote('list') async list(_request: SessionListRequest, signal: AbortSignal): Promise<SessionListValue>`；`SessionListRequest = { cursor?: string }`；`SessionListValue = { items: readonly SessionSummary[] }`。同一服务还有 `inspect(sessionId, signal)`、`resolveAgent(sessionId)` 等。
  - `[inspect]` host Event `api-session/added`：`'api-session/added'(summary: SessionSummary): void`，description 原文 “Consumers upsert the summary and replace its current running and availability state.”
  - `[src]` `dsh-api-session-controller/lib/index.js:2980-3004`：`session/created` → `api-session/added`，`session/disposed` → `api-session/removed`，`agent/created|disposed` → 再发一次 `api-session/added`，`agent/status` → `api-session/status(agent.id, status==='running')`，`agent/error` → `api-session/error`，`session/event` 的 `user/message`(source.kind==='user') → `api-session/activity`。
  - `[src]` `dsh-api-session-controller/lib/index.js:1959-2003`（`ApiSessionList.list/summarizeCold`）：冷会话用 `sessionQuery.listSessions()` 读持久 header + projection cache，**不打开会话 body、不激活 Agent**；结果按 `updatedAt` 倒序。README 原文（`dsh-api-session-controller/README.md:34`）："List reads only stored headers and projection-cache rows: it never calls per-session stat or opens a cold Session body."
  - `[src]` `dsh-api-session-controller/lib/index.js:1940-1952`（`summaryFor`）：`running: this.ctx.agents.get(session.id)?.status === 'running'`，`agentAvailable: this.ctx.agents.get(session.id)?.session === session`。
  - AgentStatus 取值：`[inspect]` host Event `agent/status` → `AgentStatus = 'idle' | 'running'`。

- **契约**
  - `SessionSummary`（`[inspect]` event `api-session/added` 的 referencedTypes 原文）：
    ```ts
    interface SessionSummary {
      readonly agentAvailable: boolean
      readonly formatStatus?: 'current' | 'migration-required'
      readonly sessionId: SessionId
      readonly updatedAt: number          // epoch ms
      readonly running: boolean
      readonly blank: boolean
      readonly parentSessionId?: SessionId
      readonly origin?: 'subagent'
      readonly cwd?: string               // 绝对路径，冷会话也有
      readonly projections?: SessionProjectionHints // { kind:'cached'|'sequenced', asOfSeq, values }
    }
    ```
    **注意：`SessionSummary` 里没有 title、没有 workspaceId**（标题见 Q2；工作区归属要靠 workspaceRegistry / workspace.json）。
  - 事件签名（`[inspect]` host Event 目录）：
    ```ts
    'api-session/added'(summary: SessionSummary): void
    'api-session/removed'(sessionId: SessionId): void
    'api-session/status'(sessionId: SessionId, running: boolean): void
    'api-session/activity'(sessionId: SessionId, updatedAt: number): void
    'api-session/error'(sessionId: SessionId, message: string): void
    'session/event'(this: Scoped<Session>, session: Session, event: SessionEvent): void
    'agent/status'(this: Scoped<Agent>, payload: { agent: Agent; status: 'idle' | 'running' }): void
    ```
  - “会话总数” = `items.length`；`api-session/added` 是 **upsert 语义**（同一 session 会因 agent 创建/销毁重复发），不要当“新会话”计数。
  - **running / 等待确认 / idle 的判定**（三层组合，推荐）：
    1. `running`：直接信 `summary.running`（或 `agent/status`）。
    2. **等待确认**：不改任何 waterfall，只旁听 `session/event`（见下面代码）：
       - `approval/asked`（`[src]` `dsh-user-approval/lib/index.js:132-137` append 的 data：`{ id, toolName, callId?, reason? }`）→ 进入“待授权”；
       - 任何 `approval/decided`（`[src]` 同文件 139-142，data `{ id, outcome }`）或 `turn/start|end` → 清除；
       - `tool/call` 且 `data.name === 'ask_user_question'` → 进入“待回答”（id 用 `data.callId`），`tool/result`（`data.message.toolCallId`）或 `turn/*` → 清除。
       - 这套判定与线上插件 `dsh-whale-widget/lib/index.js:1039-1087`（`notePendingEvent`）完全一致，可视为已在真机验证过的路径。
    3. 其余 `running=false` 且无 pending → idle。
  - `ctx.agents.list()`：`[inspect]` host Service `agents`：`list(): Agent[]`（“All live agents, in registration order”）、`roots()`、`get(id)`。**只包含已加载/已恢复的运行时 agent，不含冷会话**；返回数 ≠ 会话总数。Agent 可确认存在的字段：`id`、`session`（`dsh-user-approval/lib/index.js:129`）、`status`（`api-session-controller/lib/index.js:1948`）、`inbox`/`steer()`/`inject()`（`dsh-user-questions/lib/types/index.js:173-213`）。`[inspect]` 里 `Agent` 只声明 `{ readonly id: SessionId }`（接口是跨包合并的，字段以源码用法为准）。

- **可照抄代码（订阅 + 初次全量 + pending 状态 + 清理，Host 侧）**
  ```js
  // dsh-taskbox Host 半区；apply 是 Cordis 插件体（可为 sync 或 async）
  export function apply(ctx) {
    /** sessionId -> SessionSummary（upsert） */
    const sessions = new Map()
    /** sessionId -> { kind: 'approval'|'question', id, toolName?, since } */
    const pending = new Map()
    /** 订阅开始后已被事件更新过的 id，避免初始全量把新状态覆盖回旧值 */
    const touched = new Set()

    const ac = new AbortController()
    ctx.effect(() => () => ac.abort(), 'taskbox: abort list/broadcast')

    const publish = () => { /* 把 { sessions: [...sessions.values()], pending: [...pending] } 推给浮窗（HTTP/WS/子进程） */ }

    // 1) 先订阅，保证不吃丢事件
    ctx.effect(() => ctx.on('api-session/added', (summary) => {
      touched.add(summary.sessionId)
      sessions.set(summary.sessionId, summary)   // upsert：整行替换，running/agentAvailable 以最新为准
      publish()
    }), 'taskbox: api-session/added')
    ctx.effect(() => ctx.on('api-session/removed', (sessionId) => {
      touched.add(sessionId); sessions.delete(sessionId); pending.delete(sessionId); publish()
    }), 'taskbox: api-session/removed')
    ctx.effect(() => ctx.on('api-session/status', (sessionId, running) => {
      touched.add(sessionId)
      const cur = sessions.get(sessionId)
      if (cur) sessions.set(sessionId, { ...cur, running })
      publish()
    }), 'taskbox: api-session/status')
    ctx.effect(() => ctx.on('api-session/activity', (sessionId, updatedAt) => {
      touched.add(sessionId)
      const cur = sessions.get(sessionId)
      if (cur) sessions.set(sessionId, { ...cur, updatedAt })
      publish()
    }), 'taskbox: api-session/activity')

    // 2) 待确认状态：旁听会话日志事件（不认领任何 waterfall）
    ctx.effect(() => ctx.on('session/event', (session, event) => {
      const sid = session?.id
      if (!sid) return
      const d = event?.data || {}
      switch (event.type) {
        case 'approval/asked':
          pending.set(sid, { kind: 'approval', id: String(d.id || ''), toolName: String(d.toolName || ''), since: Date.now() }); break
        case 'approval/decided':
          if (pending.get(sid)?.kind === 'approval') pending.delete(sid); break
        case 'tool/call':
          if (String(d.name || '') === 'ask_user_question')
            pending.set(sid, { kind: 'question', id: String(d.callId || ''), toolName: 'ask_user_question', since: Date.now() })
          break
        case 'tool/result':
          if (pending.get(sid)?.kind === 'question') pending.delete(sid); break   // 精确匹配可用 d.message?.toolCallId
        case 'turn/start':
        case 'turn/end':
          pending.delete(sid); break
        default: return
      }
      publish()
    }), 'taskbox: pending approvals/questions')

    // 3) 初次全量：先订阅后拉取；不要 await 阻塞 apply（桌面端注入表是启动时一次性收集，见 Q7）
    ctx.effect(() => {
      let alive = true
      ;(async () => {
        const svc = ctx.get('sessionController')          // 可选服务，必须判空
        if (!svc || typeof svc.list !== 'function') return
        const value = await svc.list({}, ac.signal)       // { items: SessionSummary[] }
        if (!alive) return
        for (const item of value.items) {
          if (touched.has(item.sessionId)) continue       // 事件已更新过的，保留事件版本
          sessions.set(item.sessionId, item)
        }
        publish()                                          // 总数 = sessions.size
      })().catch((err) => ctx.logger?.warn?.(`taskbox: initial session list failed: ${String(err)}`))
      return () => { alive = false }
    }, 'taskbox: initial full list')
  }
  ```

- **风险 / 未确认**
  - `sessionController` 是可选服务：`[inspect]` 标注 `access.optional = ctx.get("sessionController")`，必须判空；如果某部署没挂它，退回兜底：读 `%USERPROFILE%\.dsh\storages\workspace.json`（结构见 Q7 末尾）拿 `global.workspaceIds` + `tables.workspaces[*].sessionIds`，但**没有 updatedAt/title/running**，只能拿到“会话 id 全集”。
  - `list()` 会做持久化读（冷会话），可能耗时/被 abort：一定传 `signal`，并放在 try/异步里，绝不能让它抛到 Host 启动路径。
  - `projections` 可能缺失（`[src]` 里 projection 读取失败会打 warn 并“serving the row without it”，`lib/index.js:2097-2099`），所以任何 `summary.projections.values.*` 都要 `?.`。
  - 事件是 `emit`（fire-and-forget），不保证跨 Host 重启重放：初始全量必须自己拉，不能只靠事件。
  - `SessionSummary` **没有 title/workspaceId**（已核对 declaration）；别指望从它拿名字。

---

### Q2 结论：标题权威 = `ctx.get('sessionTitle').get(session)?.title`（只对 live/replayed Session）；冷会话用 `summary.projections.values.title`（或监听 `session/title` 自己缓存）；短名自己 `path.basename()`。

- 出处：`[inspect]` host Service `sessionTitle.get(session): SessionTitleSnapshot | undefined`，`SessionTitleSnapshot = { title, messageSeqs, source, eventSeq, updatedAt }`；`[src]` `dsh-session-title/lib/types/index.js:121-133` 注册投影 `key:'title'`（view 是 `string | null`，由 `session/title` 折叠）；`[src]` `dsh-api-session-controller/lib/index.js:1990-2002` 冷行带 `projections.values`；`[src]` `dsh-working-directory/lib/index.js:76-78` `get(session)` 同步返回有效目录（`sessionProjections.stateOf(session,'workingDirectory') ?? defaultDirectory`）。
- 契约/兜底：
  - 标题优先级：① `sessionTitle.get(liveSession)?.title`（能读启动前写入的标题）→ ② 事件 `session/event` 里 `event.type === 'session/title'` 的 `data.title`（启动后更新，自己缓存，whale-widget 同款做法 `lib/index.js:1050-1053`）→ ③ `summary.projections?.values?.title`（冷会话唯一来源）→ ④ `blank===true` 显示“New Session”。
  - 短名：`workingDirectory.get(liveSession)` 给绝对路径，或冷会话 `summary.cwd`，取 `path.basename()`；工作区名：`ctx.get('workspaceRegistry').list()`/`get(id)` → Workspace（字段 `path`/`title`，见 Q7 workspace.json 同构），或 workspace.json 的 `tables.workspaces[id].title`。
- 未确认：`sessionTitle` 没有把 title 写进 `SessionSummary` 的官方通道（我们是借 projection cache）；如果某会话 projection cache 被禁用，冷标题只能退回 workspace.json/`New Session`。

---

### Q3 结论（lead 已定案，此处只补链路与 race）：浏览器点「允许一次」= 客户端 `ctx.remote.$on('approval/request')` 的监听器返回 `'allowed-once'`，经 Host 的 **api-remotes 转发监听器** 回到 `ctx.approval.request()` 的 waterfall；Host 侧没有任何 `approval.answer()` Remote，唯一应答入口就是 waterfall 监听器的返回值。

- 出处
  - `[src]` `dsh-user-approval/lib/index.js:172-189` `decide()`：`ctx.waterfall(scopeTarget(req.agent, req.agent), 'approval/request', req, () => Promise.resolve('unavailable'))`；signal abort → `'cancelled'`；policy `'never'` 直接 `'rejected'`（在 waterfall 之前）。
  - `[src]` `dsh-api-remotes/lib/index.js:21-139` 的 `API_REMOTE_FORWARDED_EVENTS` 是**编译期白名单**（`approval/request` 为 waterfall 项）；`lib/index.js:165-175` 转发监听器用普通 `ctx.on`（= push 到监听器数组尾部），`lib/index.js:233-250` 把请求排队给客户端，客户端 `delegate` 时调 `next()`。
  - `[src]` `dsh-client-ui-approval/lib/client.js:355-357`：`ctx.remote.$on("approval/request", function(request, next){ return answerApproval(...) })`；`client.js:60-69, 119-135`：点“允许一次” → `pending.answer('allowed-once')` → resolve 该 Remote Event，即 Host waterfall 的返回值。
  - `[inspect]` host Service `approval` 只有 `setPolicy(agent, policy)` / `request(req)` / `overrideOf(session)`——**没有应答方法**。
- 契约（原样）：
  ```ts
  'approval/request'(this: Scoped<Agent>, req: ApprovalRequestEvent, next: () => Promise<ApprovalOutcome>): Promise<ApprovalOutcome>
  ApprovalRequestEvent = { agent: {id: SessionId}, toolName: string, callId?: ToolCallId, reason?: string,
                           displayReason?: { en: string; [locale: string]: string }, signal?: AbortSignal }
  ApprovalOutcome = 'allowed-once' | 'rejected' | 'cancelled' | 'unavailable'
  ```
  写法：`ctx.on('approval/request', async (req, next) => { /* 返回 outcome = 认领 */ return next() /* = 委托给后面（含浏览器） */ }, { prepend: true })`；`this` 被绑成该 Agent 的 `Scoped<Agent>`（`[src]` `cordis/lib/types/events.js:118-127` waterfall 用的是监听器数组顺序，`register()` 用 `options.prepend ? unshift : push` 决定位置，`events.js:137-143`）。
- **race 方案的真实风险**（`Promise.race([next(), 我们等用户点])`）：
  1. 想“既显示在浏览器又能被小窗点”，我们的监听器必须在 api-remotes 转发器**之前** → 只能 `{ prepend: true }`。此时若我们 `await next()` 之前就 hold，浏览器面板根本不会出现（转发器还没跑）；这是“悄悄吞掉原 UI”。
  2. 若先 `const forwarded = next()` 再 race：浏览器面板会出现、也能点；但
     - 小窗先答 → 我们 return 自己的 outcome，`forwarded` 成为**孤儿 pending**：客户端那张审批卡会一直“等待审批”，用户再点会向已 settle 的 dispatch 回结果（被丢弃）；
     - `[src]` `dsh-api-remotes/README.md:79`：“Only scoped waterfalls that are still pending are replayed after reconnection” → 断线重连后可能**把已决定的审批重新弹出来**；
     - 另一侧 win 后，我们的小窗必须能收到 `next()` 的结果并撤销自己的 UI，否则出现“两边都在等”。
  3. 我们 hold 期间，工具调用是**阻塞**的；`req.signal` 被 abort 必须立刻 return `'cancelled'`，否则用户关掉小窗/断线会把这一轮挂死（fail closed 要求）。
- 可照抄（保守版，不破坏浏览器 UI）：只旁听 + `next()`，把“是否允许”留给浏览器：
  ```js
  ctx.on('approval/request', async (req, next) => {
    const id = `${req.agent.id}:${req.callId ?? ''}`
    showInTaskbox({ kind: 'approval', id, toolName: req.toolName, reason: req.displayReason ?? req.reason })
    try { return await next() }                    // 让 api-remotes 转发给浏览器，并拿到最终结果
    finally { hideInTaskbox(id) }
  }, { prepend: true })                            // prepend 只为“能看见”，不认领
  ```
  如果一定要小窗可点，再升级为 `{ prepend: true } + const forwarded = next(); race(本地等待, forwarded)`，并接受上面第 2 条的两个已知副作用（用 `req.signal` 兜底取消本地等待）。

---

### Q4 结论（lead 已定案，补语义）：`ctx.userQuestions.answer()` **只用于 continued（工具调用已返回 pending）的问题**；仍挂着（open）的问题只能由 `user-questions/request` waterfall 监听器返回答案；`askTimed` 超时返回 `{pending:true, callId}` 且只 abort 前台等待、不 abort 整个 Turn。

- 出处
  - `[inspect]` host Event `user-questions/request`：`'user-questions/request'(this: Scoped<Agent>, request: AskUserQuestionRequestEvent, next: () => Promise<AskUserQuestionAnswer>): Promise<AskUserQuestionAnswer>`；`AskUserQuestionRequestEvent = { questions: AskUserQuestionItem[], agent?: Agent, signal?: AbortSignal, wait?: { callId: ToolCallId; timed?: boolean } }`；`AskUserQuestionItem = { id, question, detail?, header?, options?: {label, description?}[], multiSelect?, intent? }`；`AskUserQuestionAnswer = { answers: { id, selected: string[], custom?: string }[] }`（`selected` 是 **option label 文本**）。
  - `[src]` `dsh-user-questions/lib/types/index.js:156-213` `answer(agent, callId, answer): boolean`：先 `assertLiveRoot`，只在 `continued(agent)` 里找 callId；找不到 `return false`；答复以 `user-question-reply` 用户消息 `agent.steer()` 注入；重复排队抛 `REPLY_QUEUED`，批次不完整抛 `BAD_ANSWER`。
  - `[src]` 同文件 `294-338` `ask()`：`ctx.waterfall(scopeTarget(agent, agent), 'user-questions/request', {...request, agent}, noAnswerer)`，无应答者 `NO_PROVIDER`。
  - `[src]` `dsh-user-questions/lib/types/timed-wait.js:43-70`：`attach(signal)` 支持**多个 claim**（`claims` Set），有 claim 时停掉 Host 计时器；claim 全关后才恢复计时。
  - `[src]` 同前 `239-277` `askTimed`：`timeoutMs` 必须 1..2^31-1；超时 catch `ASK_TIMED_OUT` → `return { pending: true, callId }`；`finally` 关 wait。
  - `[src]` `dsh-client-ui-user-questions/lib/client.js:1932`（open 问题走 `$on`）+ `1830`（continued 走 `ctx.remote.userQuestions.answer`）。
- 可照抄（小窗回答 open 问题）：
  ```js
  ctx.on('user-questions/request', async (req, next) => {
    const localWait = waitForTaskboxAnswer(req)   // 返回 { promise, cancel }
    const forwarded = next()                       // 仍让浏览器拿到（可选）
    try {
      return await Promise.race([localWait.promise, forwarded])
    } finally { localWait.cancel() }
  }, { prepend: true })
  // 返回 { answers: [{ id: q.id, selected: [label] }] } 即认领
  ```
- 风险/未确认：与 Q3 相同的“孤儿 Remote Event + 重连重放”问题；`wait.timed === true` 时若小窗想显示倒计时，应同时 `ctx.userQuestions.attachWait(agent, callId, signal)` 占住 claim（多 claim 合法），否则 Host 到点就自己把问题转 pending（`askTimed` 返回 pending，小窗再也答不了）；`answer()` 需要 **live root agent**，子代理不能回答。

---

### Q5 结论（一句话）：`ctx.get('agents').list()` 只列“已加载”的 agent（字段 `id`/`session`/`status:'idle'|'running'`），"在做什么"从 `session/event` 的 `tool/call.data.name` 取（`turn/start|end` 的 data 只有 `{turn}` / `{turn, reason}`）。

- 出处：`[inspect]` host Service `agents.list()`；`[inspect]` Event `agent/status`（`AgentStatus = 'idle' | 'running'`）；`[inspect]` `session/event` 签名；`SessionEventMap`（`[inspect]`）：`'tool/call': { turn, step, callId, name, arguments }`、`'turn/start': {turn}`、`'turn/end': { turn, reason }`。
- 最小代码：`ctx.on('session/event', (session, event) => { if (event.type === 'tool/call') activity.set(session.id, event.data.name) })`；正在跑用 `summary.running`（比 `agents.list()` 全，冷会话也有）。

---

### Q6 结论：`ctx.commands.register(definition)` 收 `CommandDefinition`，handler 收 `CommandInvocation`、返回 `CommandResult`；`/taskbox` 用 `name: 'taskbox'`、`input.hint` 可选；Config 用 schemastery（`~standard` 同步校验），inject 不写也能跑（=无依赖立即 apply）。

- **出处**
  - `[inspect]` host Service `commands`：`register(definition: CommandDefinition): () => void`（返回注销 disposer）；`@Remote list(agent)`、`find(agent, name)`、`execute(agent, line, submittedAttachments, signal)`。
  - `[inspect]` referencedTypes（原文）：
    ```ts
    interface CommandDefinition {
      readonly definitionId?: CommandDefinitionId
      readonly name: string                 // 小写；注册进同一 scope 重名会抛
      readonly description: string
      readonly input?: CommandInputDescriptor   // { hint: string; attachments?: boolean }
      readonly recordInput?: boolean            // 默认 true
      readonly handler: (invocation: CommandInvocation) => CommandResult | Promise<CommandResult>
    }
    interface CommandInvocation {
      readonly commandId: CommandId
      readonly agent: Agent
      readonly rawInput: string
      readonly attachments: readonly (ImageBlock | FileBlock)[]
      readonly signal: AbortSignal
    }
    type CommandResult = { readonly kind: 'success'; readonly text?: string; readonly sourceEventSeq?: SessionSeq }
                       | { readonly kind: 'error'; readonly text: string }
    ```
  - `[src]` `dsh-commands/README.md:30-46`：名字规则“lowercase name containing letters, digits, `_` or `-`”；handler 结果文本由 UI 渲染，不进模型历史；`execute()` 会 append `command/run` / `command/done`（log-only）。
  - Config 校验：`[src]` `cordis/lib/types/fiber.js:35-49` `resolveConfig()` 用 schema 的 `~standard.validate(config)`，**不支持异步校验**；`[src]` `cordis/lib/types/registry.js:196-215` 插件形态可为 function / class / `{apply}` 对象，`Config`/`inject`/`name` 从插件对象读取。
  - schemastery 在 profile 可用：`C:\Users\14578\.dsh\profiles\desktop\node_modules\schemastery`（3.18.0）与 `node_modules\@deepseek-ai\schemastery`（3.18.4）都在（`Get-Content package.json` 实读）。真实插件范例：`E:\CompanyProject\DSH-Night-Dispatch\dispatch-plugin\pkg`（`name` + `apply(ctx)`，无 Config，路由用 `ctx.inject(['webServer'], …)`）。
- **可照抄最小插件（唤起浮窗的 /taskbox）**
  ```js
  // package.json 需要：{ "type":"module", "main":"lib/index.js",
  //   "dsh": { "bundle": { "patch": "./cordis.patch.yml" } } }   // 参考 dsh-whale-widget / @xulei/dsh-night-dispatch
  export const name = 'dsh-taskbox'

  // 可选：Config 用 schemastery；不需要配置就整段删掉（Loader 会把 {} 传进来，不报错）
  import z from 'schemastery'
  export const Config = z.object({
    windowCmd: z.string().default(''),   // 唤起浮窗用的命令行（空 = 不启子进程）
  })

  // 可选：inject 不写 → apply 立即执行；写了 → 等这些服务就绪后才执行 apply
  // export const inject = ['commands', 'webServer']

  export function apply(ctx, config) {
    // 需要命令服务时用局部等待，避免把整个 apply 推迟（见 Q7 的桌面注入表时序）
    ctx.inject(['commands'], (c) => {
      c.effect(() => c.commands.register({
        name: 'taskbox',
        description: '显示/唤回 Taskbox 浮窗',
        input: { hint: '' },
        handler: ({ agent, rawInput }) => {
          // Host 侧动作：置顶/唤起你自己的浮窗（例如已 spawn 的 powershell 子进程 / 发 HTTP 通知给浮窗）
          try {
            revealTaskboxWindow()
            return { kind: 'success', text: 'Taskbox 已唤回' }
          } catch (err) {
            return { kind: 'error', text: `Taskbox 唤回失败：${String(err && err.message || err)}` }
          }
        },
      }), 'taskbox: /taskbox command')
    })
  }
  ```
  - `inject` 结论：**不写可以**（等价于无依赖，`apply` 立即跑）；但你要用 `commands`/`webServer` 时建议用 `ctx.inject([...], cb)` **局部**等待（whale-widget `lib/index.js:723-749` 的注释解释了对象级 inject 会推迟整个 apply，导致桌面端 `webserver/index-inject` 行错过启动时一次性收集）；或用 `ctx.get('xxx')` 做可选读取（`sessionController`/`sessionTitle`/`agents` 都支持 optional access）。
  - 注意：`/taskbox` 的 handler 跑在 **Host**；如果浮窗是浏览器里的客户端 UI，命令结果文本只会显示在浏览器，要真正打开 UI 需要客户端半边自己响应（你现有的 `dsh.client` 双面插件形态，或浮窗自己轮询 Host 路由）。

---

### Q7 结论：`ctx.effect(fn)` 的 fn 可返回 disposer / null / Promise\<disposer\> / 可迭代 disposer；async disposer 在卸载时会被 await；`apply` 可 async；Host 插件里直接 `node:child_process` spawn 可行（已装插件就这么干）；`DSH_HOME` 不保证设置，按 `$DSH_HOME || ~/.dsh` 兜底。

- **出处 / 契约**
  - `[src]` `cordis/lib/types/fiber.js:268-321`（`_execute`）：apply 返回值可以是 `function`（disposer）、nullish、thenable、iterable/generator（逐项 collect）；`:279-291` 明确 `'then' in effect → effect.then(safeCollect)`，所以 **apply 可以是 async 函数**。
  - `[src]` `cordis/lib/types/fiber.js:323-348, 377-414, 451-462`：`ctx.effect(execute, label = 'anonymous')`；dispose 时 `runDisposable(disposable)`，返回值若是 thenable 会串成 `task = task.then(...)` 链 → **async 清理会被等待**；同一 effect 的 disposer 是 single-shot。
  - `[src]` `cordis/lib/types/events.js:169-182`：`ctx.on(name, listener, options)`，`options` 可以是布尔（= prepend）或 `{ prepend }`；监听器随 fiber 卸载自动注销。
  - `[src]` `dsh-host-webserver/README.md:12, 28-37, 59-71`：webServer 本身就是 `node:http`（TLS 时 `node:https`），默认配置示例 `host: 127.0.0.1`；`ctx.webServer.getOrigin()` 返回 `http://127.0.0.1:<port>`（`[inspect]` service `webServer.getOrigin()`）；`register({kind:'exact'|'prefix', path, handler(req,res)})`，**重复 (kind,path) 抛错**；`registerFallback` 只有一个座位；路由 handler 抛错 → 400，不死进程。
  - 同源路由的真机范例：`@xulei/dsh-night-dispatch`（已装在 desktop profile）`pkg/lib/index.js:116-193`：`ctx.inject(['webServer'], (injected) => { injected.effect(() => webServer.register({ kind:'exact', path:'/api/night-dispatch/state', handler })) })`，并且注释明确“插件树的加载顺序不保证 webServer 已就绪，必须用 inject 等”，以及“重复注册 `(kind,path)` 会抛错让启动崩溃，这里就地兜住”。
  - `requestRejection` 信任栅栏：`@xulei/dsh-night-dispatch`? 不，是 `dsh-whale-widget/lib/index.js:803-808, 848-874`：`ctx.get('connection')?.requestRejection(req)`，返回非空即拒绝（fail-closed）；`[inspect]` host Service `connection` 有 `requestRejection(request)`、`admit(request)`、`authenticatedUrl(baseUrl: string): string`、`allowsRemoteAuthorities`。
  - `node:child_process`：`@xulei/dsh-night-dispatch/dispatch-plugin/pkg/lib/queue-core.js:21` `import { spawn, spawnSync } from 'node:child_process'`、`:488` `child = spawn(cmd, args, { windowsHide: true, cwd, env })`（跑 ssh）；插件层没有 DSH 沙箱（沙箱是工具执行层的策略，见 `dsh-sandbox*` 包）；**插件进程本身就是普通 Node 进程**。
  - `DSH_HOME`：`dsh-home-paths/README.md:32-41` 原文 “An explicit configured path wins over the environment variable, which wins over the default under the operating-system home; blank environment values are ignored… `$DSH_HOME`, then the default `~/.dsh`”；两个已装插件都写 `process.env.DSH_HOME || join(os.homedir(), '.dsh')`（whale-widget `lib/index.js:28`、night-dispatch `pkg/lib/index.js:27-29`）。
  - Electron 形态：`dsh-host-webserver/README.md:12` “It serves browsers only; Electron loads dist over `file://` and carries fetch over an IPC bridge.”；whale-widget `lib/index.js:706-721, 4910-4918` 实测注释：桌面壳 index.html 从安装包静态 dist 直出，`tapIndex` 永远不生效，**唯一注入通道是 `webserver/index-inject` 的结构化行，且宿主启动时一次性收集、无刷新路径**；`script-src` 行加载失败会 reject 掉 `__DSH_BOOT_READY__` 让应用起不来（所以用内联 script 行 + 自己吞 onerror）。
- **结论细节**
  1. 自己起 `node:http` 监听 127.0.0.1：**技术上可行**（Host 插件就是普通 Node ESM，能 spawn/读盘/联网；已装插件都有先例），但没有现成约束强制你走 `ctx.webServer.register`；代价是：绕过 DSH 的监听器生命周期管理、绕过 `connection.requestRejection` 信任栅栏、页面跨端口/来源还要自己处理认证与 CORS；且 Electron 形态下页面可能根本不是从 Host HTTP 加载的（见上），自定义端口未必可达。→ **建议一律 `ctx.inject(['webServer'], …)` + `register`，把 handler 包一层 `connection.requestRejection`**（whale-widget 同款）。
  2. `/state.app.url`：用 `ctx.webServer.getOrigin()`（`http://127.0.0.1:<port>`）；`ctx.get('connection')?.authenticatedUrl(origin)` 是带鉴权 URL 的入口（签名已确认，**语义未确认**，猜测是给外部客户端/二维码用的、把认证 token 拼进 URL）；另有 `[inspect]` host Service `webApp.getAdvertisedUrl(): string`（"The Web GUI this process serves"），可作候选；真实 GUI 端口现场是 `http://127.0.0.1:50285`（本会话 runtime 提供）。
  3. `ctx.effect` 清理：`ctx.effect(() => { const timer = setInterval(...); return () => clearInterval(timer) }, 'taskbox: timer')`；async 清理：`ctx.effect(() => () => stopChildProcesses(), 'taskbox: child procs')`，`stopChildProcesses` 返回 Promise 也会被 await。
  4. `DSH_HOME`：**不建议假设已设置**。写数据用：
     ```js
     import os from 'node:os'; import path from 'node:path'
     const DSH_HOME = process.env.DSH_HOME || path.join(os.homedir(), '.dsh')
     const DATA_DIR = path.join(DSH_HOME, 'task-box')   // 需要自己 mkdirSync(recursive)
     ```
     （若要严格对齐 DSH，可声明依赖并用 `@deepseek-ai/dsh-home-paths` 的 `resolveDshHome()`/`dshHomePath()`；但 profile 的 node_modules 里**没有**这个包，只有 `schemastery`/`@deepseek-ai/schemastery`/`cosmokit`，所以直接用环境变量兜底最省事。）
  5. **置顶浮窗的现实约束（未确认但很重要）**：Host 插件不能创建 OS 级窗口；Electron 的 BrowserWindow 只有桌面壳能建。可行路径：(a) 客户端半边在页面里做浮层（做不到“置顶于其他应用之上”）；(b) Host `spawn` 一个 powershell/WinForms（或独立 Electron）进程做真正置顶窗，再由该窗口轮询/WS 连 Host 的 `/api/taskbox/state` 路由；(c) 若只需要“在 DSH 窗口最上层”，用客户端浮层即可。这三条里只有 (b) 能跨应用置顶，但要自己管进程生命周期（`ctx.effect` 里 kill 进程树，`windowsHide: true`，避免孤儿窗口）。
- **兜底：`%USERPROFILE%\.dsh\storages\workspace.json` 真实结构**（实读 9195 bytes，已脱敏；unit.name=`workspace`，version=`2`）：
  ```json
  {
    "unit": { "name": "workspace", "version": 2 },
    "global": {
      "initialized": true,
      "workspaceIds": ["<workspace-uuid>", "…共 12 个"],
      "archivedSessionIds": ["session-8eb70c8d-…", "…共 10 个"],
      "pinnedSessionIds": []
    },
    "tables": {
      "workspaces": {
        "<workspace-uuid>": {
          "path": "E:\\<项目目录>",              // 真实值含用户路径，已遮蔽
          "title": "deepseek-login",             // 工作区显示名 = Q2 要的“短名”权威来源之一
          "sessionIds": ["session-8eb70c8d-0666-4f04-9562-9233cb714f74", "…"],
          "createdAt": "2026-08-17T03:13:56.364Z",  // ISO 字符串（不是 epoch）
          "updatedAt": "2026-09-29T12:01:42.278Z"
        }
      }
    }
  }
  ```
  用途：拿“全部 workspace + 其 sessionIds + 工作区 title”，但**没有标题/运行态/更新时间**（按 session 的时间得去 session 日志）。只适合当 `sessionController` 不可用时的 id 全集兜底。

---

## 给 Host 实现的建议（最容易写崩的 3 个点）

1. **别阻塞/拖挂 Host 启动路径。** `sessionController.list()` 要做冷会话持久化读，`apply` 里必须异步（或 `ctx.inject` 回调里）拉、包 try/catch、带 AbortSignal；桌面端 `webserver/index-inject` 行是**宿主启动时一次性收集**的（whale-widget 实测注释），你的注入行/路由注册要尽早，别被 `await list()` 或对象级 `inject` 推迟 —— 推晚的结果是浮窗永远不出现（不是报错，更难查）。
2. **waterfall 只旁听，先别认领。** `{prepend:true}` + `return await next()` 可以稳定地“看到”审批/提问并让浏览器照常作答；一旦改成 `Promise.race([next(), 本地等待])` 并本地先答，原浏览器面板会变成永远 pending 的孤儿卡，重连还会被重放（`api-remotes/README.md:79`），而且你 hold 期间工具调用是阻塞的，`req.signal` abort 没兜住就会挂死一轮。先做“显示 + 跳转”，点选作答放到第二阶段并加超时。
3. **一切注册都要可回滚、可重复加载。** `webServer.register` 重复 `(kind,path)` 会**抛错让 Host 启动失败**（night-dispatch 注释实测）；`commands.register` 同 scope 重名也抛；spawn 出来的 powershell/浮窗进程不在 `ctx.effect` 里 kill 就会在插件热重载后变孤儿（且占着端口/窗口）。把“路由注册、命令注册、child_process、定时器、AbortController”全部塞进 `ctx.effect` 的 disposer，并给重复注册做就地兜底（try/catch + 打日志，别让启动失败）。
