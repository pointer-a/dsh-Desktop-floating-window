/**
 * dsh-taskbox —— Host 半区。
 *
 * 把「DSH 里正在发生什么」压缩成一份 1 秒刷新的状态快照，交给一个独立的小窗进程：
 * 会话列表 / 运行中 / 等待确认 / 待确认的那一条（授权或提问），并把小窗上的点击
 * 送回 DSH（作答、唤回主窗）。
 *
 * 边界：
 * - 这里跑在 Host 进程里，任何未捕获异常都影响用户桌面端 → 全部入口 try/catch。
 * - 小窗是独立进程，只通过 127.0.0.1 + 随机 token 的 HTTP 与本插件通信（docs/PROTOCOL.md）。
 */
import { appendFileSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { AskRegistry } from './asks.js'
import { interceptApprovals, interceptQuestions } from './dsh-adapters.js'
import { startLocalServer } from './http.js'
import { StateStore } from './store.js'
import { MiniBoxWindow, stateDir } from './window.js'

export const name = 'dsh-taskbox'

const PROTOCOL = 1
const TICK_MS = 1000
const LOG_MAX_BYTES = 256 * 1024

/** 环境变量开关（不引入 Config，减少激活期的失败面）。 */
function envFlag(key, fallback) {
  const raw = process.env[key]
  if (raw === undefined || raw === '') return fallback
  return !/^(0|false|off|no)$/i.test(raw.trim())
}

/** 带文件的日志：安装后排查「小窗没起来」时第一现场。 */
function makeLogger() {
  const dir = stateDir()
  const path = join(dir, 'host.log')
  let last = 0
  return (...args) => {
    const text = args.map((a) => (a instanceof Error ? `${a.message}\n${a.stack ?? ''}` : typeof a === 'string' ? a : safeJson(a))).join(' ')
    const line = `[${new Date().toISOString()}] ${text}\n`
    if (process.env.DSH_TASKBOX_DEBUG) console.log('[dsh-taskbox]', text)
    const now = Date.now()
    if (now - last < 50) return
    last = now
    try {
      mkdirSync(dir, { recursive: true })
      try {
        if (readFileSync(path).length > LOG_MAX_BYTES) writeFileSync(path, '', 'utf8')
      } catch { /* 首次 */ }
      appendFileSync(path, line, 'utf8')
    } catch { /* 日志失败不影响主流程 */ }
  }
}

function safeJson(value) {
  try { return JSON.stringify(value) } catch { return String(value) }
}

/** 给用户看的短句（失败时的底栏提示）。 */
function shortError(err) {
  const text = String(err?.message ?? err ?? '')
  return text.replace(/\s+/g, ' ').trim().slice(0, 80) || '操作失败'
}

export function apply(ctx) {
  const log = makeLogger()
  try {
    boot(ctx, log)
  } catch (err) {
    log('boot failed', err)
    console.error('[dsh-taskbox] boot failed:', err)
  }
}

function boot(ctx, log) {
  const autoStart = envFlag('DSH_TASKBOX_AUTOSTART', true)
  const state = {
    rev: 1,
    notice: null,
    noticeAt: 0,
    pendingFocus: null,
    userClosed: false,
    restarts: [],
    appUrl: '',
  }
  const bump = () => { state.rev += 1 }
  const setNotice = (text) => {
    state.notice = text
    state.noticeAt = Date.now()
    bump()
  }

  const store = new StateStore(ctx, { logger: log, bump })
  store.attach()

  const asks = new AskRegistry({ logger: log, bump })
  let windowRef = null
  let serverRef = null

  /** `/state` 的完整 envelope；任何一步失败都退回最小合法结构（小窗不能因此报红）。 */
  function getState() {
    let snap = { list: [], counts: { sessions: 0, running: 0, waiting: 0 } }
    try {
      snap = store.snapshot()
    } catch (err) {
      log('snapshot failed', err)
    }
    let ask = null
    try {
      ask = asks.current()
    } catch (err) {
      log('ask snapshot failed', err)
    }
    const notice = state.notice && Date.now() - state.noticeAt < 6000 ? state.notice : null
    if (!notice) state.notice = null
    const geometry = windowRef?.geometry ?? null
    const hasPosition = Boolean(geometry && Number.isFinite(geometry.x) && Number.isFinite(geometry.y))
    const total = Math.max(snap.counts.sessions, snap.list.length)
    return {
      ok: true,
      protocol: PROTOCOL,
      rev: state.rev,
      now: Date.now(),
      app: {
        title: 'DeepSeek Harness',
        online: true,
        ...(state.appUrl ? { url: state.appUrl } : {}),
        // 只有真有坐标时才下发；缺 x/y 时小窗必须用自己的默认位置（右下角），不能当 (0,0)
        ...(hasPosition ? { window: { x: geometry.x, y: geometry.y, collapsed: Boolean(geometry.collapsed) } } : {}),
      },
      counts: {
        sessions: total,
        running: snap.counts.running,
        waiting: ask ? Math.max(1, snap.counts.waiting) : snap.counts.waiting,
      },
      sessions: snap.list,
      ask,
      notice,
    }
  }

  async function onAction(body) {
    const type = String(body?.type ?? '')
    try {
      if (type === 'answer') {
        const pendingAsk = asks.current()
        const result = asks.answer(body.askId, { optionIds: body.optionIds, selections: body.selections })
        if (result.ok) {
          const sid = String(body.sessionId ?? pendingAsk?.sessionId ?? '')
          if (sid) store.clearWaiting(sid)
          setNotice('已提交确认')
        }
        return result
      }
      if (type === 'focus') {
        const sessionId = String(body.sessionId ?? '')
        state.pendingFocus = sessionId ? { sessionId, at: Date.now() } : null
        setNotice(sessionId ? '已定位到主窗口' : '主窗口在后台')
        return { ok: true }
      }
      if (type === 'open-main') {
        state.pendingFocus = { sessionId: null, at: Date.now() }
        setNotice('已唤回主窗口')
        return { ok: true }
      }
      if (type === 'close') {
        state.userClosed = true
        windowRef?.close()
        log('minibox closed by user')
        return { ok: true }
      }
      return { ok: false, error: `未知动作：${type}` }
    } catch (err) {
      log(`action ${type} failed`, err)
      return { ok: false, error: shortError(err) }
    }
  }

  function onWindow(body) {
    try {
      const type = String(body?.type ?? '')
      if (type === 'ready') {
        log('minibox ready')
        return
      }
      windowRef?.saveGeometry(body ?? {})
    } catch (err) {
      log('window report failed', err)
    }
  }

  // ---------------------------------------------------------------- 待确认：授权 / 提问
  // 两个拦截器都 `prepend` 注册（必须排在浏览器应答者之前，否则我们根本收不到请求）。
  // 浏览器每连接一次都会重新注册它自己的 forwarder，若它也用 prepend，就会抢到我们前面 ——
  // 所以空闲时定期"重新压到队首"：只在没有挂起确认时重排，避免打断正在等答案的那一条。
  const adapterDeps = {
    ctx,
    asks,
    store,
    log,
    bump,
    setNotice,
    // 小窗「现在能答题」以及「刚起来还在冷启动」的两种判断，决定确认先留在小窗多久
    hasWindow: () => {
      try {
        if (windowRef?.running) return true
        const started = Number(windowRef?.startedAt ?? 0)
        return started > 0 && !state.userClosed && Date.now() - started < 15_000
      } catch {
        return false
      }
    },
    polledRecently: () => {
      const at = Number(serverRef?.stats?.lastPollAt ?? 0)
      return at > 0 && Date.now() - at < 3000
    },
  }
  const interceptors = { approval: null, question: null }
  const armInterceptors = () => {
    try {
      interceptors.approval?.()
      interceptors.approval = interceptApprovals(adapterDeps) ?? null
    } catch (err) {
      log('approval interception unavailable', err)
    }
    try {
      interceptors.question?.()
      interceptors.question = interceptQuestions(adapterDeps) ?? null
    } catch (err) {
      log('question interception unavailable', err)
    }
  }
  armInterceptors()
  ctx.effect(() => {
    const timer = setInterval(() => {
      try {
        if (asks.current()) return
        armInterceptors()
      } catch (err) {
        log('re-arm failed', err)
      }
    }, 15_000)
    timer.unref?.()
    return () => {
      clearInterval(timer)
      for (const key of Object.keys(interceptors)) {
        try { interceptors[key]?.() } catch { /* 忽略 */ }
        interceptors[key] = null
      }
    }
  })

  // ---------------------------------------------------------------- 可选服务：GUI 地址 / 命令
  // 局部 inject：等服务出现再注册，绝不用对象级 inject 拖晚整个 apply（那会让启动期的
  // 一次性注入收集漏掉本插件）。
  try {
    ctx.inject(['webServer'], (injected) => {
      try {
        const origin = injected.webServer.getOrigin()
        if (typeof origin === 'string' && origin) {
          state.appUrl = origin
          bump()
        }
      } catch (err) {
        log('webServer origin unavailable', err)
      }
    })
  } catch (err) {
    log('webServer inject unavailable', err)
  }

  try {
    ctx.inject(['commands'], (injected) => {
      injected.effect(() => injected.commands.register({
        name: 'taskbox',
        description: '打开 / 唤回桌面任务浮窗',
        input: { hint: '（无需参数）' },
        handler: () => {
          state.userClosed = false
          const opened = windowRef?.open() ?? false
          if (!windowRef) return { kind: 'error', text: '任务浮窗还没准备好，请稍后再试' }
          return { kind: 'success', text: opened ? '已唤回桌面任务浮窗' : '桌面任务浮窗已在运行' }
        },
      }))
    })
  } catch (err) {
    log('commands inject unavailable', err)
  }

  // ---------------------------------------------------------------- 本地服务 + 小窗
  ctx.effect(() => {
    let disposed = false
    startLocalServer({
      logger: log,
      getState,
      onAction,
      onWindow,
    })
      .then((server) => {
        if (disposed) {
          server.close()
          return
        }
        serverRef = server
        windowRef = new MiniBoxWindow({ logger: log, port: server.port, token: server.token })
        windowRef.loadGeometry()
        log(`local server on 127.0.0.1:${server.port}`)
        // 落一份 server.json：小窗/自检/排障时可以直接从这里拿到端口与 token
        try {
          mkdirSync(stateDir(), { recursive: true })
          writeFileSync(
            join(stateDir(), 'server.json'),
            JSON.stringify({ port: server.port, token: server.token, pid: process.pid, startedAt: Date.now() }, null, 2),
            'utf8',
          )
        } catch (err) {
          log('write server.json failed', err)
        }
        if (autoStart) windowRef.open()
      })
      .catch((err) => log('local server failed', err))
    return () => {
      disposed = true
      try { windowRef?.close() } catch { /* 忽略 */ }
      try { serverRef?.close() } catch { /* 忽略 */ }
      try { rmSync(join(stateDir(), 'server.json'), { force: true }) } catch { /* 忽略 */ }
    }
  })

  // ---------------------------------------------------------------- 心跳
  ctx.effect(() => {
    const timer = setInterval(() => {
      try {
        store.reconcile()
        // 用户主动关掉小窗后不再打扰；但如果有新的待确认出现，说明"必须让人看见"，重新拉起
        const ask = asks.current()
        if (!state.userClosed && autoStart && windowRef && !windowRef.running) {
          const recent = state.restarts.filter((at) => Date.now() - at < 60_000)
          if (recent.length < 3) {
            state.restarts = [...recent, Date.now()]
            windowRef.open()
            log('minibox respawned (unexpected exit)')
          }
        } else if (state.userClosed && ask && autoStart && windowRef && !windowRef.running) {
          state.userClosed = false
          windowRef.open()
          log('minibox reopened for a pending confirmation')
        }
        // 待确认的会话要稳定显示为 waiting
        if (ask) store.markWaiting(ask.sessionId)
        if (state.notice && Date.now() - state.noticeAt > 6000) {
          state.notice = null
          bump()
        }
      } catch (err) {
        log('tick failed', err)
      }
    }, TICK_MS)
    timer.unref?.()
    return () => clearInterval(timer)
  })

  log(`booted (autoStart=${autoStart})`)
}

/** 自检用：把内部状态以文本形式吐出来（开发期 / 排障）。 */
export function describeLog(lines = 40) {
  try {
    const raw = readFileSync(join(stateDir(), 'host.log'), 'utf8')
    return raw.split('\n').slice(-lines).join('\n')
  } catch {
    return ''
  }
}
