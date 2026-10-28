/**
 * dsh-adapters.js —— 与 DSH 版本契约相关的唯一一块：怎么"拦到"一次待确认，
 * 以及怎么把用户的选择"交回"给 DSH。
 *
 * 依据（host Event 契约，dsh 0.2.x）：
 * - `approval/request`(waterfall)  (this: Scoped<Agent>, req: ApprovalRequestEvent, next)
 *     req = { agent: { id }, toolName, callId?, reason?, displayReason?: { en, [locale] }, signal? }
 *     返回 ApprovalOutcome = 'allowed-once' | 'rejected' | 'cancelled' | 'unavailable'
 *     —— 返回一个结果即"认领"该请求，否则调用 next() 交给后续应答者（浏览器 UI）。
 * - `user-questions/request`(waterfall) (this: Scoped<Agent>, request, next)
 *     request = { questions: AskUserQuestionItem[], agent?: { id }, signal?, wait?: { callId, timed? } }
 *     item   = { id, question, detail?, header?, options?: [{ label, description? }], multiSelect?, intent? }
 *     返回 AskUserQuestionAnswer = { answers: [{ id, selected: string[], custom? }] }
 *     `selected` 里放的是**选项文字（label）**，不是下标。
 *
 * ⚠️ 关键时序（踩过的坑）：浏览器那边的确认卡片是"一次转发下来的请求"，只有在它自己那次
 * RPC 结算后才会消失。如果我们先调用 next() 把请求转发给浏览器、随后又在小窗里作答，
 * 浏览器那张卡片就成了孤儿（用户看到"小窗答完了、主窗口选择还在"）。
 * 所以策略是 **小窗优先**：
 *   1. 小窗进程在跑 → 先只等小窗，宽限期内（默认 6s）作答就**根本不转发**给浏览器；
 *   2. 宽限期到 / 小窗没在跑 → 再调用 next() 交给浏览器，两边谁先答都算数。
 *
 * 两个拦截器都 `prepend` 注册：必须排在浏览器应答者之前。
 * 任何内部异常都被就地吞掉并退回 next()，绝不把审批变成 `unavailable`（那等于自动拒绝）。
 */
import { normalizeOptions } from './asks.js'

const APPROVAL_OPTIONS = [
  { id: 'allow', label: '允许一次', style: 'primary' },
  { id: 'deny', label: '拒绝', style: 'danger' },
]

const FORWARD_DELAY_DEFAULT_MS = 20_000
const COLD_START_EXTRA_MS = 8_000

/** 宽限期：小窗在跑时先独占多久再转发给浏览器（可用环境变量覆盖，0 = 立刻转发）。 */
function forwardDelayMs() {
  const raw = Number(process.env.DSH_TASKBOX_FORWARD_DELAY_MS)
  return Number.isFinite(raw) && raw >= 0 ? Math.min(raw, 300_000) : FORWARD_DELAY_DEFAULT_MS
}

/**
 * 本请求愿意"扣住"多久不去打扰浏览器。
 * - 小窗没在跑（也没在启动）→ 0：立刻转发，就是普通浏览器确认。
 * - 小窗在跑但还没开始轮询（冷启动 4–6s）→ 宽限期再加 8s，否则人还没看到卡片就被转发了。
 */
function graceMsFor({ hasWindow, polledRecently }) {
  try {
    if (!hasWindow?.()) return 0
  } catch {
    return 0
  }
  const base = forwardDelayMs()
  let polled = true
  try { polled = polledRecently?.() !== false } catch { polled = true }
  return polled ? base : base + COLD_START_EXTRA_MS
}

/** displayReason 是 `{ en, [locale] }` 映射；优先中文，其次英文。 */
function pickLocalized(reason) {
  if (!reason || typeof reason !== 'object') return ''
  const keys = Object.keys(reason)
  const zh = keys.find((key) => /^zh/i.test(key))
  const en = keys.find((key) => /^en/i.test(key))
  const value = reason[zh ?? en ?? keys[0]]
  return typeof value === 'string' ? value.trim() : ''
}

/**
 * 小窗优先的竞速。
 * @returns {Promise<{from:'widget', selection:object} | {from:'upstream', value:any} | {from:'abort'}>}
 */
async function raceWidgetFirst({ record, next, hasWindow, polledRecently, signal, log, label }) {
  const widget = record.done.then((selection) => ({ from: 'widget', selection }))
  let aborted = null
  let onAbort = null
  if (signal && typeof signal.addEventListener === 'function') {
    aborted = new Promise((resolve) => {
      onAbort = () => resolve({ from: 'abort' })
      signal.addEventListener('abort', onAbort, { once: true })
    })
  }
  let forwardTimer = null
  try {
    // ---- 阶段 1：只等小窗（宽限期内）
    const wait = graceMsFor({ hasWindow, polledRecently })
    if (wait > 0) {
      const gate = new Promise((resolve) => { forwardTimer = setTimeout(() => resolve({ from: 'gate' }), wait) })
      const first = await Promise.race([widget, gate, ...(aborted ? [aborted] : [])])
      if (first.from === 'widget') {
        log?.(`${label} answered from taskbox without forwarding to the browser`)
        return first
      }
      if (first.from === 'abort') return first
      log?.(`${label} forwarded to the browser after ${wait}ms (no taskbox answer)`)
    }

    // ---- 阶段 2：转发给后续应答者，两边继续竞速
    let upstream
    try {
      upstream = Promise.resolve(next())
    } catch (err) {
      throw err
    }
    upstream.catch(() => {})
    return await Promise.race([
      widget,
      upstream.then(
        (value) => ({ from: 'upstream', value }),
        () => ({ from: 'upstream', value: undefined }),
      ),
      ...(aborted ? [aborted] : []),
    ])
  } finally {
    if (forwardTimer) clearTimeout(forwardTimer)
    if (onAbort) {
      try { signal.removeEventListener('abort', onAbort) } catch { /* 忽略 */ }
    }
  }
}

function describeApproval(req, store) {
  const toolName = String(req?.toolName ?? '').trim()
  const reason = pickLocalized(req?.displayReason) || String(req?.reason ?? '').trim()
  const callHint = store?.describeCall?.(req?.callId) ?? ''
  const question = reason || (toolName ? `允许执行 ${toolName} 吗？` : '这个操作需要你的授权')
  const detail = [question, callHint && !question.includes(callHint) ? `执行：${callHint}` : ''].filter(Boolean).join('\n')
  const items = [
    {
      id: 'approval',
      header: toolName ? `工具 · ${toolName}` : '工具授权',
      question,
      detail: callHint,
      multiSelect: false,
      options: normalizeOptions(APPROVAL_OPTIONS, 'ap'),
    },
  ]
  return {
    kind: 'approval',
    sessionId: String(req?.agent?.id ?? ''),
    title: '需要授权',
    detail,
    meta: toolName || '',
    items,
    defaultOptionId: items[0].options[0]?.id ?? null,
  }
}

function outcomeFor(selection) {
  const picked = Object.values(selection ?? {})[0] ?? []
  const first = String(picked[0] ?? '')
  const option = APPROVAL_OPTIONS.find((entry) => entry.id === first)
  if (!option) return 'cancelled'
  return option.id === 'allow' ? 'allowed-once' : 'rejected'
}

/**
 * 拦截工具授权。返回 disposer。
 * @param {object} deps `{ ctx, asks, store, log, hasWindow }`
 */
export function interceptApprovals(deps) {
  const { ctx, asks, store, log, hasWindow, polledRecently } = deps
  const handler = async function (req, next) {
    let record = null
    try {
      const entry = describeApproval(req, store)
      if (entry.sessionId) {
        entry.sessionTitle = store.titleOf?.(entry.sessionId) ?? ''
        store.markWaiting?.(entry.sessionId)
      }
      record = asks.add(entry)
      const winner = await raceWidgetFirst({
        record,
        next,
        hasWindow,
        polledRecently,
        signal: req?.signal,
        log,
        label: 'approval',
      })
      if (winner.from === 'widget') return outcomeFor(winner.selection)
      if (winner.from === 'abort') return 'cancelled'
      return winner.value ?? 'unavailable'
    } catch (err) {
      log('approval interception failed (delegating)', err)
      // 兜底：至少要把请求放给后续应答者，不能因为我们的 bug 把用户卡住
      try { return await next() } catch { return 'unavailable' }
    } finally {
      if (record) record.dispose()
      if (req?.agent?.id) store.clearWaiting?.(req.agent.id)
    }
  }
  return ctx.on('approval/request', handler, { prepend: true })
}

function describeQuestions(request, store) {
  const questions = Array.isArray(request?.questions) ? request.questions : []
  if (questions.length === 0) return null
  const items = questions.map((item, index) => {
    const options = normalizeOptions(item?.options, `q${index}`)
    return {
      id: String(item?.id ?? `q${index}`),
      header: String(item?.header ?? '').slice(0, 60),
      question: String(item?.question ?? '').slice(0, 400),
      detail: String(item?.detail ?? '').slice(0, 600),
      multiSelect: Boolean(item?.multiSelect),
      options,
    }
  })
  const first = items[0]
  const note = items.some((item) => item.options.length === 0)
    ? '这道题需要输入文字，请在 DSH 主窗口回答'
    : ''
  return {
    kind: 'question',
    sessionId: String(request?.agent?.id ?? ''),
    title: '需要选择',
    detail: first?.detail || first?.question || '',
    meta: [first?.header, questions.length > 1 ? `${questions.length} 个问题` : ''].filter(Boolean).join(' · '),
    items,
    note,
    defaultOptionId: first?.options[0]?.id ?? null,
  }
}

function answerFor(recordItems, selection) {
  const answers = recordItems.map((item) => {
    const ids = Array.isArray(selection?.[item.id]) ? selection[item.id] : []
    const labels = []
    for (const id of ids) {
      const option = item.options.find((candidate) => candidate.id === id)
      if (option) labels.push(option.label)
    }
    return { id: item.id, selected: labels }
  })
  return { answers }
}

/**
 * 拦截 ask_user_question。返回 disposer。
 * @param {object} deps `{ ctx, asks, store, log, hasWindow }`
 */
export function interceptQuestions(deps) {
  const { ctx, asks, store, log, hasWindow, polledRecently } = deps
  const handler = async function (request, next) {
    let record = null
    let shownItems = null
    try {
      const entry = describeQuestions(request, store)
      if (!entry) {
        // 描述不出来（例如没有 questions）就完全交回原链路
        return await next()
      }
      if (entry.sessionId) {
        entry.sessionTitle = store.titleOf?.(entry.sessionId) ?? ''
        store.markWaiting?.(entry.sessionId)
      }
      shownItems = entry.items
      record = asks.add(entry)
      const winner = await raceWidgetFirst({
        record,
        next,
        hasWindow,
        polledRecently,
        signal: request?.signal,
        log,
        label: 'question',
      })
      if (winner.from === 'widget') return answerFor(shownItems, winner.selection)
      if (winner.from === 'abort') return await next()
      return winner.value
    } catch (err) {
      log('question interception failed (delegating)', err)
      try { return await next() } catch { return { answers: [] } }
    } finally {
      if (record) record.dispose()
      if (request?.agent?.id) store.clearWaiting?.(request.agent.id)
    }
  }
  return ctx.on('user-questions/request', handler, { prepend: true })
}
