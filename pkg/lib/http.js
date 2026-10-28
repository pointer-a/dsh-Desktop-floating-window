/**
 * http.js —— 只监听 127.0.0.1 的小 HTTP 服务（小窗 ↔ Host 的唯一通道）。
 *
 * 为什么不用 `ctx.webServer.register`：那条路要求请求带 DSH 的会话凭据（浏览器信任栅栏），
 * 而独立的小窗进程没有 Cookie。这里另起一个临时端口 + 每次启动随机 token，只绑回环地址。
 */
import { createServer } from 'node:http'
import { randomBytes, timingSafeEqual } from 'node:crypto'

const MAX_BODY_BYTES = 64 * 1024

function json(res, code, value) {
  res.writeHead(code, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
  })
  res.end(JSON.stringify(value))
}

function readBody(req) {
  return new Promise((resolve) => {
    let raw = ''
    req.on('data', (chunk) => {
      raw += chunk
      if (raw.length > MAX_BODY_BYTES) raw = raw.slice(0, MAX_BODY_BYTES)
    })
    req.on('end', () => {
      try { resolve(raw ? JSON.parse(raw) : {}) } catch { resolve({}) }
    })
    req.on('error', () => resolve({}))
  })
}

/** 常量时间比较，避免 token 被逐字符试探。 */
function tokenMatches(expected, actual) {
  const a = Buffer.from(String(expected ?? ''), 'utf8')
  const b = Buffer.from(String(actual ?? ''), 'utf8')
  if (a.length === 0 || a.length !== b.length) return false
  try { return timingSafeEqual(a, b) } catch { return false }
}

/**
 * @param {object} deps `{ logger, getState, onAction, onWindow, token }`
 * @returns {Promise<{port:number, close:()=>void, requests:object}>}
 */
export function startLocalServer(deps) {
  const log = deps.logger ?? (() => {})
  const token = deps.token ?? randomBytes(16).toString('hex')
  const stats = { requests: 0, actions: 0, lastActionAt: 0, lastError: '', lastPollAt: 0 }

  const server = createServer(async (req, res) => {
    const started = Date.now()
    try {
      stats.requests += 1
      const url = new URL(req.url ?? '/', 'http://127.0.0.1')
      const supplied = req.headers['x-taskbox-token'] ?? url.searchParams.get('t') ?? ''
      if (!tokenMatches(token, supplied)) {
        json(res, 401, { ok: false, error: 'unauthorized' })
        return
      }
      if (req.method === 'GET' && url.pathname === '/ping') {
        json(res, 200, { ok: true })
        return
      }
      if (req.method === 'GET' && url.pathname === '/state') {
        stats.lastPollAt = Date.now()
        json(res, 200, deps.getState())
        return
      }
      if (req.method === 'POST' && url.pathname === '/action') {
        const body = await readBody(req)
        stats.actions += 1
        stats.lastActionAt = Date.now()
        const result = await deps.onAction(body)
        json(res, 200, result ?? { ok: true })
        return
      }
      if (req.method === 'POST' && url.pathname === '/window') {
        const body = await readBody(req)
        deps.onWindow(body)
        json(res, 200, { ok: true })
        return
      }
      json(res, 404, { ok: false, error: 'not found' })
    } catch (err) {
      stats.lastError = String(err?.message ?? err)
      log('http request failed', err)
      try { json(res, 200, { ok: false, error: stats.lastError }) } catch { /* 连接已断 */ }
    } finally {
      void started
    }
  })

  return new Promise((resolve, reject) => {
    server.once('error', (err) => reject(err))
    server.listen(0, '127.0.0.1', () => {
      const addr = server.address()
      const port = typeof addr === 'object' && addr ? addr.port : 0
      resolve({
        port,
        token,
        stats,
        close: () => {
          try { server.close() } catch { /* 已关闭 */ }
        },
      })
    })
  })
}
