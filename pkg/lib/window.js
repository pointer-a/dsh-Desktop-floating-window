/**
 * window.js —— 小窗进程管理。
 *
 * 小窗是一个**独立**的 PowerShell + WPF 进程，本模块只负责：定位脚本、拉起、回收、
 * 把几何/折叠状态落到 `$DSH_HOME/task-box/window.json`，以及把子进程输出写进日志
 * （`$DSH_HOME/task-box/minibox.log`，排障时的第一现场）。
 *
 * 设计约束：
 * - 绝不因为拉起失败而抛异常：桌面端（无 PowerShell / 无桌面会话）只降级为"没有浮窗"。
 * - **stdout/stderr 直接接文件描述符**，不用管道：管道会引入 backpressure 与命名管道依赖
 *   （在被沙箱限制的进程里 spawn 带管道的子进程会直接 EPERM），日志文件也更好排障。
 * - 连续失败要退避，不能每秒重试把日志刷爆：5s → 15s → 60s → 300s，满 5 次不再重试。
 * - Host 正常退出时杀掉子进程；Host 崩溃时小窗自己发现连不上并退出（协议约定）。
 */
import { spawn } from 'node:child_process'
import { appendFileSync, closeSync, mkdirSync, openSync, readFileSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const MAX_LOG_BYTES = 256 * 1024
const BACKOFF_MS = [5_000, 15_000, 60_000, 300_000]
const MAX_FAILURES = 5

/** `$DSH_HOME/task-box`（跟随 DSH_HOME 环境变量，缺省 `~/.dsh`）。 */
export function stateDir() {
  const home = process.env.DSH_HOME && process.env.DSH_HOME.trim() ? process.env.DSH_HOME.trim() : join(homedir(), '.dsh')
  return join(home, 'task-box')
}

export class MiniBoxWindow {
  /**
   * @param {object} deps `{ logger, port, token }`
   */
  constructor(deps) {
    this.log = deps.logger ?? (() => {})
    this.port = deps.port
    this.token = deps.token
    this.child = null
    this.geometry = null
    this.startedAt = 0
    this.failures = 0
    this.nextRetryAt = 0
    this.dir = stateDir()
  }

  get scriptPath() {
    return join(dirname(dirname(fileURLToPath(import.meta.url))), 'assets', 'minibox', 'minibox.ps1')
  }

  get running() {
    return Boolean(this.child && this.child.exitCode === null && !this.child.killed)
  }

  /** 现在允许尝试拉起吗（退避窗口内不允许）。 */
  get canRetry() {
    if (this.failures >= MAX_FAILURES) return false
    return Date.now() >= this.nextRetryAt
  }

  /** 读上次的几何（进程重启后小窗回到原来的屏幕位置）。 */
  loadGeometry() {
    try {
      const raw = readFileSync(join(this.dir, 'window.json'), 'utf8')
      const doc = JSON.parse(raw)
      if (doc && typeof doc.x === 'number' && typeof doc.y === 'number') {
        this.geometry = {
          x: Math.round(doc.x),
          y: Math.round(doc.y),
          collapsed: Boolean(doc.collapsed),
        }
      }
    } catch { /* 首次启动没有这个文件 */ }
    return this.geometry
  }

  /** 记录小窗上报的几何。 */
  saveGeometry(patch) {
    try {
      const next = { ...(this.geometry ?? {}) }
      if (typeof patch.x === 'number') next.x = Math.round(patch.x)
      if (typeof patch.y === 'number') next.y = Math.round(patch.y)
      if (typeof patch.collapsed === 'boolean') next.collapsed = patch.collapsed
      if (typeof patch.w === 'number') next.w = Math.round(patch.w)
      if (typeof patch.h === 'number') next.h = Math.round(patch.h)
      this.geometry = next
      mkdirSync(this.dir, { recursive: true })
      writeFileSync(join(this.dir, 'window.json'), JSON.stringify(next, null, 2), 'utf8')
    } catch (err) {
      this.log('saveGeometry failed', err)
    }
  }

  /** 拉起小窗；已在跑、退避中或已放弃则什么都不做。返回是否（重新）拉起。 */
  open() {
    if (this.running) return false
    if (!this.canRetry) {
      if (this.failures >= MAX_FAILURES) this.log('minibox disabled after repeated failures')
      return false
    }
    const script = this.scriptPath
    let fd = null
    try {
      mkdirSync(this.dir, { recursive: true })
      const logPath = join(this.dir, 'minibox.log')
      this.#rotateLog(logPath)
      this.#appendRaw(logPath, `\n===== ${new Date().toISOString()} spawn port=${this.port} =====\n`)
      fd = openSync(logPath, 'a')
      const child = spawn(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-STA',
          '-ExecutionPolicy', 'Bypass',
          '-WindowStyle', 'Hidden',
          '-File', script,
          '-Port', String(this.port),
          '-Token', String(this.token),
          '-AssetDir', dirname(script),
        ],
        { windowsHide: true, stdio: ['ignore', fd, fd], detached: false },
      )
      this.child = child
      this.startedAt = Date.now()
      child.on('error', (err) => {
        this.log('minibox spawn error', err)
        this.#appendRaw(logPath, `[spawn-error] ${String(err?.message ?? err)}\n`)
        if (this.child === child) this.child = null
        this.#noteFailure(`spawn: ${String(err?.message ?? err)}`)
      })
      child.on('exit', (code, signal) => {
        this.#appendRaw(logPath, `[exit] code=${code} signal=${signal} after ${Date.now() - this.startedAt}ms\n`)
        const wasChild = this.child === child
        if (wasChild) this.child = null
        // 活过一个心跳周期就不算"起不来"，退避计数清零；启动即退（如参数错）才计失败
        if (Date.now() - this.startedAt > 3000) {
          this.failures = 0
          this.nextRetryAt = 0
          return
        }
        this.#noteFailure(`exit code=${code}`)
      })
      this.log(`minibox spawned pid=${child.pid}`)
      return true
    } catch (err) {
      this.log('minibox open failed', err)
      try { this.#appendRaw(join(this.dir, 'minibox.log'), `[open-failed] ${String(err?.message ?? err)}\n`) } catch { /* 忽略 */ }
      this.child = null
      this.#noteFailure(`open: ${String(err?.message ?? err)}`)
      return false
    } finally {
      if (fd !== null) {
        try { closeSync(fd) } catch { /* 子进程已持有句柄 */ }
      }
    }
  }

  /** 关掉小窗进程（Host 退出/禁用插件时）。 */
  close() {
    const child = this.child
    if (!child) return
    this.child = null
    try {
      if (child.exitCode === null) child.kill()
    } catch (err) {
      this.log('minibox close failed', err)
    }
  }

  /** 最近 N 行日志（给自检/排障用）。 */
  tailLog(lines = 40) {
    try {
      const raw = readFileSync(join(this.dir, 'minibox.log'), 'utf8')
      return raw.split('\n').slice(-lines).join('\n')
    } catch {
      return ''
    }
  }

  #noteFailure(reason) {
    this.failures += 1
    const wait = BACKOFF_MS[Math.min(this.failures - 1, BACKOFF_MS.length - 1)]
    this.nextRetryAt = Date.now() + wait
    this.log(`minibox start failed (${this.failures}/${MAX_FAILURES}): ${reason}; retry in ${Math.round(wait / 1000)}s`)
  }

  #rotateLog(path) {
    try {
      const st = readFileSync(path)
      if (st.length > MAX_LOG_BYTES) writeFileSync(path, '', 'utf8')
    } catch { /* 文件还不存在 */ }
  }

  #appendRaw(path, text) {
    try {
      appendFileSync(path, text, 'utf8')
    } catch { /* 日志失败不影响主流程 */ }
  }
}
