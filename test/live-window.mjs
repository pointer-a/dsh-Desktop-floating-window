#!/usr/bin/env node
/**
 * live-window.mjs —— 真实开窗联调：跑真正的 Host 半区（假 ctx），拉起真正的 WPF 小窗。
 *
 * 验证的是「Host 拉起参数 + 小窗进程 + HTTP 协议 + 截图」这一整条链路，
 * 不需要安装插件、也不碰 DSH 本体。
 *
 * 用法：
 *   node test/live-window.mjs            # 授权场景：开窗 → 截图 → 作答 → 再截图 → 关窗
 *   node test/live-window.mjs --keep 30  # 截完图后保留窗口 30 秒（人工看）
 */
import { spawn } from 'node:child_process'
import { mkdtempSync, readFileSync, existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createCtx } from './fake-ctx.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = resolve(HERE, '..')
const HOME = mkdtempSync(join(tmpdir(), 'taskbox-live-'))
process.env.DSH_HOME = HOME
process.env.DSH_TASKBOX_AUTOSTART = '1'

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function waitFor(read, timeoutMs, label) {
  const started = Date.now()
  for (;;) {
    const value = await read()
    if (value) return value
    if (Date.now() - started > timeoutMs) throw new Error(`等待超时：${label}`)
    await sleep(150)
  }
}

/** 截当前小窗（不经管道：沙箱下带管道的子进程 spawn 会 EPERM）。 */
function capture(name) {
  const out = join(ROOT, 'docs', 'shots', name)
  return new Promise((resolveCapture) => {
    const child = spawn('powershell.exe', [
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', join(HERE, 'capture.ps1'),
      '-Out', out, '-TitleLike', 'DeepSeek',
    ], { stdio: 'ignore', windowsHide: true })
    child.on('error', (err) => {
      console.log(`  capture spawn failed: ${err.message}`)
      resolveCapture(null)
    })
    child.on('exit', (code) => {
      const ok = existsSync(out)
      console.log(`  capture ${ok ? 'ok' : 'failed'} (exit=${code}) -> ${out}`)
      resolveCapture(ok ? out : null)
    })
  })
}

async function main() {
  const keepMs = Number(process.argv.includes('--keep') ? process.argv[process.argv.indexOf('--keep') + 1] : 0) * 1000
  const ctx = createCtx()
  const plugin = await import('../pkg/lib/index.js')
  plugin.apply(ctx)
  const info = await waitFor(() => {
    const path = join(HOME, 'task-box', 'server.json')
    if (!existsSync(path)) return null
    try { return JSON.parse(readFileSync(path, 'utf8')) } catch { return null }
  }, 5000, 'server.json')
  const base = `http://127.0.0.1:${info.port}`
  const auth = { 'x-taskbox-token': info.token }
  const getState = async () => (await fetch(`${base}/state`, { headers: auth })).json()
  console.log(`local server: ${base}`)

  // 造三个会话 + 一个待授权
  const a = { id: 's-a' }
  const b = { id: 's-b' }
  const c = { id: 's-c' }
  const titles = { 's-a': '写一个桌面任务浮窗插件', 's-b': '离线包签名校验失败排查', 's-c': '整理 OpenViking 记忆条目' }
  ctx.services.set('sessionTitle', { get: (session) => ({ title: titles[session.id] ?? '' }) })
  ctx.services.set('workingDirectory', { get: (session) => (session.id === 's-a' ? 'E:\\dsh插件' : 'E:\\CompanyProject') })
  ctx.services.set('sessionController', {
    list: async () => ({
      items: [
        { sessionId: 's-a', updatedAt: Date.now(), running: true, agentAvailable: true },
        { sessionId: 's-b', updatedAt: Date.now() - 12 * 60e3, running: false },
        { sessionId: 's-c', updatedAt: Date.now() - 48 * 60e3, running: false },
      ],
    }),
  })
  ctx.services.set('agents', { list: () => [{ id: 's-a', status: 'running', session: a }] })
  for (const session of [a, b, c]) ctx.emit('session/created', session)
  ctx.emit('session/event', a, { type: 'tool/call', data: { name: 'bash', callId: 'c-live', arguments: { command: 'pnpm build && pnpm test' } } })
  await sleep(1200)

  const approval = ctx.waterfall(
    'approval/request',
    [{ agent: { id: 's-a' }, toolName: 'bash', callId: 'c-live', reason: '允许执行以下命令吗？', signal: new AbortController().signal }],
    () => new Promise(() => {}),
  )
  let askId = null
  await waitFor(async () => {
    const state = await getState()
    askId = state.ask?.id ?? null
    return askId
  }, 4000, '/state.ask')
  console.log(`ask: ${askId}`)

  await sleep(3500)
  const shot1 = await capture('live-approval-dark.png')
  const state = await getState()
  console.log(`state: sessions=${state.counts.sessions} running=${state.counts.running} waiting=${state.counts.waiting} ask=${state.ask?.kind}`)

  const answer = await fetch(`${base}/action`, {
    method: 'POST',
    headers: { ...auth, 'content-type': 'application/json' },
    body: JSON.stringify({ type: 'answer', askId, optionIds: ['allow'] }),
  }).then((r) => r.json())
  console.log(`answer -> ${JSON.stringify(answer)}`)
  console.log(`waterfall outcome -> ${await approval}`)
  await sleep(2500)
  const shot2 = await capture('live-after-answer-dark.png')

  if (keepMs > 0) {
    console.log(`保留窗口 ${keepMs / 1000}s ...`)
    await sleep(keepMs)
  }
  await fetch(`${base}/action`, {
    method: 'POST',
    headers: { ...auth, 'content-type': 'application/json' },
    body: JSON.stringify({ type: 'close' }),
  }).catch(() => {})
  await sleep(500)
  console.log('')
  console.log(`minibox log: ${join(HOME, 'task-box', 'minibox.log')}`)
  try {
    console.log(readFileSync(join(HOME, 'task-box', 'minibox.log'), 'utf8').split('\n').slice(-12).join('\n'))
  } catch { /* 没有日志 */ }
  console.log(`shots: ${shot1} ${shot2}`)
  process.exit(0)
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
