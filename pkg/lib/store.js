/**
 * store.js —— 会话 / 任务状态聚合。
 *
 * 只依赖 Host 的公开事件与可选服务，所有读取都 try/catch：任何一个 API 缺失或形状
 * 变化都只能让某一列降级，绝不能让 Host 抛异常（那会把用户的桌面端带崩）。
 *
 * 数据来源（按可靠性排序）：
 *   1. `sessionController.list()`：全量会话（含未加载的冷会话），用于列表与总数
 *   2. `ctx.agents` 服务：live agent 名册 + `agent/status` 事件 → running / idle
 *   3. `session/event`：`turn/start|end`、`tool/call`、`session/title` → 活动短语与标题
 *   4. `sessionTitle` 服务：折叠日志里的权威标题（含插件启动前写入的）
 *   5. `workingDirectory` 服务：会话当前目录 → 工作区短名
 *   6. `api-session/added|removed|status|activity`：可见会话增删与活动时间
 */

const MAX_SESSIONS = 20
const ACTIVITY_TTL_MS = 5 * 60 * 1000
const HYDRATE_INTERVAL_MS = 120_000

/** 从路径取最后一段（兼容 / 与 \）。 */
export function baseName(p) {
  const s = String(p ?? '')
  if (!s) return ''
  const parts = s.split(/[\\/]+/).filter(Boolean)
  return parts.length > 0 ? parts[parts.length - 1] : s
}

/** 事件里的工具名 → 简短活动短语。 */
function activityFromToolCall(data) {
  const name = String(data?.name ?? data?.toolName ?? '').trim()
  if (!name) return ''
  const args = data?.arguments ?? data?.args ?? data?.input ?? null
  const hint = toolHint(name, args)
  return hint ? `${name} · ${hint}` : name
}

/** 给常见工具挑一个能看懂的次要信息。 */
function toolHint(name, args) {
  if (!args || typeof args !== 'object') return ''
  const pick = (v) => {
    if (typeof v !== 'string') return ''
    const s = v.replace(/\s+/g, ' ').trim()
    if (!s) return ''
    return s.length > 46 ? `${s.slice(0, 46)}…` : s
  }
  switch (name) {
    case 'bash':
    case 'pwsh':
    case 'terminal_open':
      return pick(args.command ?? args.cmd ?? args.description)
    case 'read':
    case 'write':
    case 'edit':
      return pick(baseName(args.file_path ?? args.path))
    case 'grep':
    case 'glob':
      return pick(args.pattern)
    case 'web_search':
    case 'web_fetch':
      return pick(args.query ?? args.url)
    case 'subagent':
    case 'spawn_teammate':
      return pick(args.description ?? args.name)
    case 'skill':
      return pick(args.name)
    case 'todo_write':
      return '更新任务清单'
    default:
      return pick(args.description ?? args.command ?? args.path ?? args.query ?? args.name)
  }
}

export class StateStore {
  /**
   * @param {object} ctx Cordis Host 上下文
   * @param {object} hooks `{ logger, bump }`
   */
  constructor(ctx, hooks = {}) {
    this.ctx = ctx
    this.log = hooks.logger ?? (() => {})
    this.bump = hooks.bump ?? (() => {})
    /** @type {Map<string, object>} */
    this.sessions = new Map()
    /** @type {Map<string, object>} */
    this.sessionRefs = new Map()
    /** 最近若干次 tool/call 的短语，给授权提示补一句"到底在跑什么"。@type {Map<string, {text:string, at:number}>} */
    this.calls = new Map()
    /** 全量会话条数（`sessionController.list()` 的 items.length；拿不到时为 null）。 */
    this.totalSessions = null
    this.disposers = []
    this.abort = new AbortController()
    this.hydrateTimer = null
  }

  /** 挂上所有监听；返回清理函数。 */
  attach() {
    this.#listen('agent/status', (payload) => {
      const agent = payload?.agent
      const status = String(payload?.status ?? '')
      this.#upsert(agent?.id ?? agent?.sessionId, (s) => {
        if (status === 'running') s.status = s.status === 'waiting' ? 'waiting' : 'running'
        else if (s.status === 'running') s.status = 'idle'
      })
      if (status === 'running') {
        this.#upsert(agent?.id ?? agent?.sessionId, (s) => { s.live = true })
      }
    })

    this.#listen('session/created', (session) => {
      this.#touchSession(session, (s) => {
        if (s.status !== 'waiting') s.status = 'idle'
      })
    })

    this.#listen('session/disposed', (session) => {
      const id = String(session?.id ?? '')
      if (id && this.sessions.has(id)) {
        this.sessions.delete(id)
        this.sessionRefs.delete(id)
        this.bump()
      }
    })

    this.#listen('session/event', (session, event) => this.#onSessionEvent(session, event))

    // 可选：更"官方"的可见会话名册（老宿主没有这些事件就跳过）
    this.#listen('api-session/added', (summary) => this.#onApiSummary(summary))
    this.#listen('api-session/removed', (sessionId) => {
      const id = String(sessionId ?? '')
      if (id && !this.#agentById(id)) {
        this.sessions.delete(id)
        this.sessionRefs.delete(id)
        this.bump()
      }
    })
    this.#listen('api-session/status', (sessionId, running) => {
      this.#upsert(sessionId, (s) => {
        s.status = running ? (s.status === 'waiting' ? 'waiting' : 'running') : (s.status === 'waiting' ? 'waiting' : 'idle')
      })
    })
    this.#listen('api-session/activity', (sessionId, updatedAt) => {
      this.#upsert(sessionId, (s) => {
        const ts = Number(updatedAt)
        if (Number.isFinite(ts) && ts > 0) s.updatedAt = ts > 1e12 ? ts : ts * 1000
        else s.updatedAt = Date.now()
      })
    })

    // 初始名册：插件热加载进一个已经在跑的 Host 时，事件都已经发生过了
    this.reconcile()
    this.#kickHydrate()
    return () => {
      this.abort.abort()
      if (this.hydrateTimer) clearInterval(this.hydrateTimer)
      for (const dispose of this.disposers.splice(0)) {
        try { dispose() } catch { /* 忽略 */ }
      }
    }
  }

  /**
   * 用官方 `sessionController.list()` 拉一次全量会话（含未加载的冷会话）。
   * 只做"补齐列表与计数"，不激活 Agent；拿不到这个服务（老宿主）就静默跳过。
   */
  async hydrate() {
    try {
      const svc = this.ctx.get('sessionController')
      if (!svc || typeof svc.list !== 'function') return
      const result = await svc.list({}, this.abort.signal)
      const items = Array.isArray(result?.items) ? result.items : []
      if (this.abort.signal.aborted) return
      this.totalSessions = items.length
      for (const summary of items) {
        if (!summary || typeof summary !== 'object') continue
        const id = String(summary.sessionId ?? summary.id ?? '')
        if (!id) continue
        const subagent = summary.origin === 'subagent' || Boolean(summary.parentSessionId)
        // 子智能体的会话不是"用户的对话"：只有它正在跑的时候才值得占一行
        if (subagent && summary.running !== true) continue
        const projections = summary.projections?.values ?? {}
        const title = String(projections.title ?? projections.name ?? '').trim()
        const cwd = String(summary.cwd ?? '').trim()
        const ts = Number(summary.updatedAt)
        this.#upsert(id, (s) => {
          s.subagent = s.subagent || subagent
          if (title && !s.title) s.title = title.slice(0, 160)
          if (cwd && !s.workspace) s.workspace = baseName(cwd)
          if (Number.isFinite(ts) && ts > 0) s.updatedAt = ts > 1e12 ? ts : ts * 1000
          if (typeof summary.running === 'boolean') {
            if (summary.running) s.status = s.status === 'waiting' ? 'waiting' : 'running'
            else if (s.status !== 'waiting') s.status = 'idle'
          }
        })
      }
      this.bump()
    } catch (err) {
      this.log('hydrate failed', err)
    }
  }

  #kickHydrate() {
    // 放到下一轮事件循环：绝不在 Host 启动路径上同步等 I/O
    const kick = () => { void this.hydrate() }
    try { setTimeout(kick, 0).unref?.() } catch { kick() }
    try {
      this.hydrateTimer = setInterval(kick, HYDRATE_INTERVAL_MS)
      this.hydrateTimer.unref?.()
    } catch { /* 忽略 */ }
  }

  /** 每秒对一次账：live agent 名册是 running 状态最可靠的来源。 */
  reconcile() {
    try {
      const agents = this.ctx.get('agents')
      const list = typeof agents?.list === 'function' ? agents.list() : []
      const alive = new Set()
      for (const agent of list) {
        const id = String(agent?.id ?? agent?.sessionId ?? '')
        if (!id) continue
        alive.add(id)
        const running = String(agent?.status ?? '') === 'running'
        this.#upsert(id, (s) => {
          s.live = true
          s.status = running ? (s.status === 'waiting' ? 'waiting' : 'running') : (s.status === 'waiting' ? 'waiting' : 'idle')
        })
        const session = agent?.session
        if (session && typeof session === 'object') {
          this.sessionRefs.set(id, session)
          this.#fillTitle(id, session)
          this.#fillWorkspace(id, session)
        }
      }
      // 已不在名册里的 live 会话降级为 idle（不删，用户可能还要看它的最后状态）
      for (const [id, s] of this.sessions) {
        if (s.live && !alive.has(id)) {
          s.live = false
          if (s.status !== 'waiting') s.status = 'idle'
        }
      }
    } catch (err) {
      this.log('reconcile failed', err)
    }
  }

  /** 当前快照（已排序、已截断）。 */
  snapshot() {
    const now = Date.now()
    const rows = []
    for (const s of this.sessions.values()) {
      // 子智能体的会话不是"用户的对话"：只有正在跑的时候才展示
      if (s.subagent && s.status !== 'running' && s.status !== 'waiting') continue
      // 太久没动静又不 live 的行不必一直占位
      if (!s.live && s.status === 'idle' && now - s.updatedAt > 6 * 60 * 60 * 1000) continue
      // 连标题都没有的空会话（新建未聊 / 只有冷 header）：不占位
      if (!s.title && s.status === 'idle' && now - s.updatedAt > 60 * 60 * 1000) continue
      rows.push({
        id: s.id,
        title: s.title || '',
        status: s.status,
        activity: s.status === 'idle' ? '' : (now - s.activityAt > ACTIVITY_TTL_MS ? '' : s.activity),
        updatedAt: s.updatedAt,
        workspace: s.workspace || '',
      })
    }
    const rank = { waiting: 0, running: 1, idle: 2 }
    rows.sort((a, b) => {
      const d = (rank[a.status] ?? 3) - (rank[b.status] ?? 3)
      if (d !== 0) return d
      return (b.updatedAt ?? 0) - (a.updatedAt ?? 0)
    })
    return {
      list: rows.slice(0, MAX_SESSIONS),
      counts: {
        sessions: Math.max(this.totalSessions ?? 0, rows.length),
        running: rows.filter((r) => r.status === 'running').length,
        waiting: rows.filter((r) => r.status === 'waiting').length,
      },
    }
  }

  /** 把某个会话标记为「等待确认」。 */
  markWaiting(sessionId) {
    this.#upsert(sessionId, (s) => { s.status = 'waiting' })
  }

  /** 清掉等待标记，恢复成 running/idle。 */
  clearWaiting(sessionId) {
    const s = this.sessions.get(String(sessionId ?? ''))
    if (!s) return
    if (s.status !== 'waiting') return
    s.status = s.live ? 'running' : 'idle'
    s.activity = ''
    s.activityAt = 0
    this.bump()
  }

  /** 会话标题（给待确认卡片用）。 */
  titleOf(sessionId) {
    const s = this.sessions.get(String(sessionId ?? ''))
    return s?.title ?? ''
  }

  /** 某次工具调用当时的短语（`bash · rm -rf dist`），授权卡片用它补上下文。 */
  describeCall(callId) {
    const key = String(callId ?? '')
    if (!key) return ''
    const hit = this.calls.get(key)
    if (!hit) return ''
    if (Date.now() - hit.at > 10 * 60 * 1000) {
      this.calls.delete(key)
      return ''
    }
    return hit.text
  }

  // ---------------------------------------------------------------- 内部

  #rememberCall(callId, text) {
    if (this.calls.size > 200) {
      const oldest = this.calls.keys().next().value
      if (oldest !== undefined) this.calls.delete(oldest)
    }
    this.calls.set(callId, { text, at: Date.now() })
  }

  #listen(event, handler) {
    try {
      const dispose = this.ctx.on(event, handler)
      if (typeof dispose === 'function') this.disposers.push(dispose)
    } catch (err) {
      this.log(`listen ${event} failed`, err)
    }
  }

  #agentById(id) {
    try {
      const agents = this.ctx.get('agents')
      const list = typeof agents?.list === 'function' ? agents.list() : []
      return list.some((a) => String(a?.id ?? a?.sessionId ?? '') === String(id))
    } catch {
      return false
    }
  }

  #upsert(id, mutate) {
    const sid = String(id ?? '')
    if (!sid) return
    let s = this.sessions.get(sid)
    if (!s) {
      s = {
        id: sid,
        title: '',
        status: 'idle',
        activity: '',
        activityAt: 0,
        updatedAt: Date.now(),
        workspace: '',
        live: false,
        subagent: false,
      }
      this.sessions.set(sid, s)
    }
    const before = `${s.status}|${s.title}|${s.activity}|${s.updatedAt}|${s.live}`
    try { mutate(s) } catch (err) { this.log('mutate session failed', err) }
    const after = `${s.status}|${s.title}|${s.activity}|${s.updatedAt}|${s.live}`
    if (before !== after) this.bump()
  }

  #touchSession(session, mutate) {
    const id = String(session?.id ?? '')
    if (!id) return
    this.sessionRefs.set(id, session)
    this.#upsert(id, (s) => {
      s.live = true
      mutate?.(s)
    })
    this.#fillTitle(id, session)
    this.#fillWorkspace(id, session)
  }

  #onSessionEvent(session, event) {
    try {
      const id = String(session?.id ?? '')
      if (!id || !event || typeof event !== 'object') return
      const type = String(event.type ?? '')
      const data = event.data && typeof event.data === 'object' ? event.data : {}
      this.sessionRefs.set(id, session)

      if (type === 'session/title') {
        const title = String(data.title ?? '').trim()
        if (title) this.#upsert(id, (s) => { s.title = title.slice(0, 160) })
        return
      }

      if (type === 'turn/start') {
        this.#upsert(id, (s) => {
          s.live = true
          s.status = s.status === 'waiting' ? 'waiting' : 'running'
          s.activity = ''
          s.activityAt = 0
          s.updatedAt = Date.now()
        })
        this.#fillTitle(id, session)
        return
      }

      if (type === 'turn/end') {
        this.#upsert(id, (s) => {
          if (s.status !== 'waiting') s.status = s.live ? 'running' : 'idle'
          if (s.status === 'idle') {
            s.activity = ''
            s.activityAt = 0
          }
          s.updatedAt = Date.now()
        })
        return
      }

      if (type === 'tool/call') {
        const activity = activityFromToolCall(data)
        const callId = String(data.callId ?? data.toolCallId ?? data.tool_call_id ?? '')
        if (callId && activity) this.#rememberCall(callId, activity)
        this.#upsert(id, (s) => {
          s.live = true
          if (s.status !== 'waiting') s.status = 'running'
          if (activity) {
            s.activity = activity
            s.activityAt = Date.now()
          }
          s.updatedAt = Date.now()
        })
        this.#fillTitle(id, session)
        return
      }

      if (type === 'assistant/message' || type === 'user/message') {
        this.#upsert(id, (s) => { s.updatedAt = Date.now() })
        return
      }
    } catch (err) {
      this.log('session event failed', err)
    }
  }

  #onApiSummary(summary) {
    try {
      if (!summary || typeof summary !== 'object') return
      const id = String(summary.sessionId ?? summary.id ?? '')
      if (!id) return
      const subagent = summary.origin === 'subagent' || Boolean(summary.parentSessionId)
      if (subagent && summary.running !== true) return
      this.#upsert(id, (s) => {
        s.subagent = s.subagent || subagent
        const projections = summary.projections?.values ?? {}
        const title = String(projections.title ?? summary.title ?? summary.name ?? '').trim()
        if (title && !s.title) s.title = title.slice(0, 160)
        const cwd = String(summary.cwd ?? '').trim()
        if (cwd && !s.workspace) s.workspace = baseName(cwd)
        if (summary.agentAvailable === true) s.live = true
        if (typeof summary.running === 'boolean') {
          s.status = summary.running ? (s.status === 'waiting' ? 'waiting' : 'running') : (s.status === 'waiting' ? 'waiting' : 'idle')
        }
        const ts = Number(summary.updatedAt ?? summary.activityAt)
        if (Number.isFinite(ts) && ts > 0) s.updatedAt = ts > 1e12 ? ts : ts * 1000
      })
    } catch (err) {
      this.log('api summary failed', err)
    }
  }

  #fillTitle(id, session) {
    try {
      const s = this.sessions.get(id)
      if (!s || s.title) return
      const svc = this.ctx.get('sessionTitle')
      if (!svc || typeof svc.get !== 'function' || !session) return
      const snap = svc.get(session)
      const title = typeof snap === 'string' ? snap : (snap?.title ?? snap?.text ?? '')
      const clean = String(title ?? '').trim()
      if (clean) this.#upsert(id, (row) => { row.title = clean.slice(0, 160) })
    } catch (err) {
      this.log('title lookup failed', err)
    }
  }

  #fillWorkspace(id, session) {
    try {
      const s = this.sessions.get(id)
      if (!s || s.workspace) return
      const svc = this.ctx.get('workingDirectory')
      if (!svc || typeof svc.get !== 'function') return
      const dir = svc.get(session)
      const name = baseName(dir)
      if (name) this.#upsert(id, (row) => { row.workspace = name })
    } catch (err) {
      this.log('workspace lookup failed', err)
    }
  }
}
