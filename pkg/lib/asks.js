/**
 * asks.js —— 「需要确认」登记簿。
 *
 * 一份待确认 = 一次挂起的工具授权（approval）或一次 ask_user_question（question）。
 * 登记簿只做三件事：排队（可能同时有多条）、给 `/state` 提供当前展示用的那一条、
 * 把用户在小窗里的点击校验并解析回对应的 Promise。
 *
 * 一条待确认由 1..N 个 item 组成（ask_user_question 一次可以问最多 4 个问题；
 * 工具授权固定是 1 个 item）。每个 item 有自己的一组选项，选项 id 由 Host 生成。
 *
 * 与 DSH 版本相关的「怎么拦到、怎么交回」在 dsh-adapters.js 里，本文件不认识 DSH。
 */

const ASK_TTL_MS = 30 * 60 * 1000
const MAX_SELECTED = 16

let optionSeq = 0

/** 把外部选项定义归一成协议形状（id 由 Host 生成，稳定且不暴露原始 label）。 */
export function normalizeOptions(options, prefix) {
  const list = Array.isArray(options) ? options : []
  return list.map((option, index) => {
    const label = typeof option === 'string' ? option : String(option?.label ?? '')
    const givenId = typeof option?.id === 'string' && option.id.trim() ? option.id.trim() : ''
    const item = {
      id: givenId || `${prefix}o${++optionSeq}_${index}`,
      label: label.slice(0, 120),
      style: String(option?.style ?? (index === 0 ? 'primary' : 'default')),
    }
    const description = typeof option?.description === 'string' ? option.description.trim() : ''
    if (description) item.description = description.slice(0, 240)
    return item
  })
}

export class AskRegistry {
  constructor(hooks = {}) {
    this.log = hooks.logger ?? (() => {})
    this.bump = hooks.bump ?? (() => {})
    /** @type {Map<string, object>} */
    this.map = new Map()
    this.seq = 0
  }

  /**
   * 登记一条待确认。
   * @param {object} entry `{ kind, sessionId, title, detail, meta, items, defaultOptionId }`
   * @returns {{id:string, done:Promise<object>, dispose:()=>void}}
   *   `done` 解析为 `{ [itemId]: string[] }`（每个 item 选中的选项 id）。
   */
  add(entry) {
    const id = `ask-${++this.seq}`
    let resolveDone = () => {}
    const done = new Promise((resolve) => { resolveDone = resolve })
    const items = (Array.isArray(entry.items) ? entry.items : []).map((item, index) => ({
      id: String(item.id ?? `item-${index}`),
      header: String(item.header ?? '').slice(0, 60),
      question: String(item.question ?? '').slice(0, 400),
      detail: String(item.detail ?? '').slice(0, 600),
      multiSelect: Boolean(item.multiSelect),
      options: Array.isArray(item.options) ? item.options : [],
    }))
    const record = {
      id,
      kind: entry.kind,
      sessionId: String(entry.sessionId ?? ''),
      sessionTitle: entry.sessionTitle ?? '',
      title: entry.title ?? '需要确认',
      detail: entry.detail ?? '',
      meta: entry.meta ?? '',
      note: entry.note ?? '',
      items,
      defaultOptionId: entry.defaultOptionId ?? null,
      createdAt: Date.now(),
      resolveDone,
      disposed: false,
    }
    this.map.set(id, record)
    this.bump()
    return {
      id,
      done,
      dispose: () => this.remove(id),
    }
  }

  /** `/state.ask` 用的公开形状（最早的一条）。 */
  current() {
    let oldest = null
    for (const record of this.map.values()) {
      if (!oldest || record.createdAt < oldest.createdAt) oldest = record
    }
    if (!oldest) return null
    if (Date.now() - oldest.createdAt > ASK_TTL_MS) return null
    const first = oldest.items[0]
    return {
      id: oldest.id,
      kind: oldest.kind,
      sessionId: oldest.sessionId,
      sessionTitle: oldest.sessionTitle,
      title: oldest.title,
      detail: oldest.detail,
      meta: oldest.meta,
      note: oldest.note,
      // items 是权威形状；options/multiSelect 保留给只认单一选项组的旧版小窗
      items: oldest.items,
      options: first?.options ?? [],
      multiSelect: oldest.items.some((item) => item.multiSelect),
      createdAt: oldest.createdAt,
      defaultOptionId: oldest.defaultOptionId,
    }
  }

  /** 是否还在等这个会话的确认。 */
  waiting(sessionId) {
    const sid = String(sessionId ?? '')
    for (const record of this.map.values()) {
      if (record.sessionId === sid) return true
    }
    return false
  }

  /**
   * 小窗点击 → 解析对应 Promise。
   * @param {string} askId
   * @param {object} payload `{ optionIds?: string[], selections?: Record<string, string[]> }`
   */
  answer(askId, payload) {
    const record = this.map.get(String(askId ?? ''))
    if (!record) return { ok: false, error: '这条确认已经失效' }
    const selections = this.#validate(record, payload)
    if (!selections.ok) return selections
    this.map.delete(record.id)
    record.disposed = true
    record.resolveDone(selections.value)
    this.bump()
    this.log(`ask ${record.id} answered: ${JSON.stringify(selections.value)}`)
    return { ok: true }
  }

  remove(askId) {
    const record = this.map.get(String(askId ?? ''))
    if (!record) return
    this.map.delete(record.id)
    record.disposed = true
    this.bump()
  }

  clear() {
    for (const record of this.map.values()) record.disposed = true
    this.map.clear()
    this.bump()
  }

  #validate(record, payload) {
    const raw = payload ?? {}
    /** @type {Record<string, string[]>} */
    const out = {}
    if (raw.selections && typeof raw.selections === 'object' && !Array.isArray(raw.selections)) {
      for (const item of record.items) {
        const chosen = raw.selections[item.id]
        const ids = Array.isArray(chosen) ? chosen.map(String).filter(Boolean) : []
        const checked = this.#checkItem(item, ids)
        if (!checked.ok) return checked
        out[item.id] = checked.value
      }
      return { ok: true, value: out }
    }
    // 兼容只发一个选项组的旧形状
    const ids = Array.isArray(raw.optionIds) ? raw.optionIds.map(String).filter(Boolean) : []
    if (record.items.length !== 1) return { ok: false, error: '这条确认有多个问题，需要逐项选择' }
    const checked = this.#checkItem(record.items[0], ids)
    if (!checked.ok) return checked
    out[record.items[0].id] = checked.value
    return { ok: true, value: out }
  }

  #checkItem(item, ids) {
    if (ids.length === 0) return { ok: false, error: `「${item.question.slice(0, 20) || '问题'}」还没有选择` }
    if (ids.length > MAX_SELECTED) return { ok: false, error: '选项过多' }
    if (!item.multiSelect && ids.length > 1) return { ok: false, error: '这道题只能选一项' }
    const known = new Set(item.options.map((option) => String(option.id)))
    for (const id of ids) {
      if (!known.has(id)) return { ok: false, error: '选项无效' }
    }
    return { ok: true, value: [...new Set(ids)] }
  }
}
