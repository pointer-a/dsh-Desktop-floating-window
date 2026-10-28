#!/usr/bin/env node
/**
 * mock-host.mjs — 桌面任务浮窗（dsh-taskbox）的 Host 行为模拟器。
 *
 * 只用于开发与联调，不属于插件包。它实现的正是 docs/PROTOCOL.md v1：
 *   GET  /state   返回脚本化状态
 *   POST /action  记录小窗动作并按剧本推进
 *   POST /window  记录小窗几何
 *
 * 用法：
 *   node mock/mock-host.mjs                         # 默认端口，剧本 approval
 *   node mock/mock-host.mjs --scenario multi --spawn
 *   node mock/mock-host.mjs --port 41730 --token dev --spawn
 *
 * 剧本 --scenario：
 *   empty     空对话列表
 *   idle      3 个空闲会话
 *   running   2 个进行中 + 2 个空闲
 *   approval  1 个会话卡在「授权」→ 点允许/拒绝后进入 question 单选 → 再答完清空
 *   question  直接进入 question 单选
 *   multi     question 多选（3 选 2）
 */
import { createServer } from 'node:http'
import { spawn } from 'node:child_process'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { existsSync } from 'node:fs'
import { randomBytes } from 'node:crypto'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = resolve(HERE, '..')

function parseArgs(argv) {
  const out = { port: 41730, token: 'dev', scenario: 'approval', spawn: false, verbose: true }
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i]
    if (a === '--spawn') out.spawn = true
    else if (a === '--quiet') out.verbose = false
    else if (a === '--port') out.port = Number(argv[++i])
    else if (a === '--token') out.token = String(argv[++i])
    else if (a === '--scenario') out.scenario = String(argv[++i])
  }
  return out
}

const args = parseArgs(process.argv)
const T0 = Date.now()
const sessions = []
function addSession(o) {
  sessions.push({
    id: o.id,
    title: o.title ?? '未命名对话',
    status: o.status ?? 'idle',
    activity: o.activity ?? '',
    updatedAt: o.updatedAt ?? Date.now() - (o.ageMs ?? 0),
    workspace: o.workspace ?? 'dsh插件',
  })
}

const SANDBOX = {
  id: 's-01j9kpt3m2',
  title: '写一个桌面任务浮窗插件',
  status: 'running',
  activity: 'bash · npm run build',
  workspace: 'dsh插件',
  ageMs: 2000,
}
const REVIEW = {
  id: 's-01j9kpt3n7',
  title: '离线包签名校验失败排查',
  status: 'idle',
  activity: '',
  workspace: 'CompanyProject',
  ageMs: 1000 * 60 * 12,
}
const NOTES = {
  id: 's-01j9kpt3p1',
  title: '整理 OpenViking 记忆条目',
  status: 'idle',
  activity: '',
  workspace: 'CompanyProject',
  ageMs: 1000 * 60 * 48,
}

let ask = null
let phase = 0

function approveItem(question, command) {
  return [{
    id: 'approval',
    header: '工具 · bash',
    question,
    detail: command,
    multiSelect: false,
    options: [
      { id: 'allow', label: '允许一次', style: 'primary' },
      { id: 'deny', label: '拒绝', style: 'danger' },
    ],
  }]
}

function approvalAsk() {
  return {
    id: 'a-17',
    kind: 'approval',
    sessionId: SANDBOX.id,
    sessionTitle: SANDBOX.title,
    title: '需要授权',
    detail: '允许执行以下命令吗？\nrm -rf dist && pnpm build && pnpm test --filter taskbox',
    meta: 'bash',
    items: approveItem('允许执行以下命令吗？', 'bash · rm -rf dist && pnpm build && pnpm test --filter taskbox'),
    options: [],
    multiSelect: false,
    createdAt: Date.now(),
    defaultOptionId: 'allow',
  }
}

function questionAsk() {
  const items = [{
    id: 'q-plan',
    header: '停靠位置',
    question: '浮窗默认停在哪？',
    detail: '之后可以在小窗里拖动，这个只是初始位置。',
    multiSelect: false,
    options: [
      { id: 'br', label: '屏幕右下角', style: 'primary' },
      { id: 'bl', label: '屏幕左下角', style: 'default' },
      { id: 'tr', label: '屏幕右上角', style: 'default' },
    ],
  }]
  return {
    id: 'q-18',
    kind: 'question',
    sessionId: SANDBOX.id,
    sessionTitle: SANDBOX.title,
    title: '需要选择',
    detail: '浮窗默认停在哪？',
    meta: '停靠位置',
    items,
    options: items[0].options,
    multiSelect: false,
    createdAt: Date.now(),
    defaultOptionId: 'br',
  }
}

function multiAsk() {
  const items = [
    {
      id: 'q-plan',
      header: '停靠位置',
      question: '浮窗默认停在哪？',
      multiSelect: false,
      options: [
        { id: 'br', label: '屏幕右下角', style: 'primary' },
        { id: 'bl', label: '屏幕左下角', style: 'default' },
      ],
    },
    {
      id: 'q-tags',
      header: '上线清单',
      question: '上线前先补哪些东西？',
      detail: '可多选。',
      multiSelect: true,
      options: [
        { id: 'readme', label: 'README 安装说明', style: 'default' },
        { id: 'shot', label: '界面截图', style: 'default' },
        { id: 'e2e', label: '端到端自检脚本', style: 'default' },
      ],
    },
  ]
  return {
    id: 'q-19',
    kind: 'question',
    sessionId: SANDBOX.id,
    sessionTitle: SANDBOX.title,
    title: '需要选择',
    detail: items[0].question,
    meta: '停靠位置 · 2 个问题',
    items,
    options: items[0].options,
    multiSelect: true,
    createdAt: Date.now(),
    defaultOptionId: 'br',
  }
}

function noteAsk() {
  const items = [{
    id: 'q-note',
    header: '补充说明',
    question: '请描述一下你在离线包签名里看到的报错原文。',
    multiSelect: false,
    options: [],
  }]
  return {
    id: 'q-20',
    kind: 'question',
    sessionId: SANDBOX.id,
    sessionTitle: SANDBOX.title,
    title: '需要输入',
    detail: items[0].question,
    meta: '补充说明',
    note: '这道题需要输入文字，请在 DSH 主窗口回答',
    items,
    options: [],
    multiSelect: false,
    createdAt: Date.now(),
    defaultOptionId: null,
  }
}

function buildSessions() {
  sessions.length = 0
  switch (args.scenario) {
    case 'empty':
      break
    case 'idle':
      addSession(NOTES)
      addSession(REVIEW)
      addSession({ ...SANDBOX, status: 'idle', activity: '', ageMs: 1000 * 60 * 90 })
      break
    case 'running':
      addSession(SANDBOX)
      addSession({ ...REVIEW, status: 'running', activity: 'grep · approval/asked', ageMs: 800 })
      addSession(NOTES)
      addSession({ id: 's-01j9kpt3q9', title: '币安行情工具 · 加个止盈档位', status: 'idle', activity: '', workspace: 'select_coin_trade' })
      break
    case 'question':
      addSession({ ...SANDBOX, status: 'waiting', activity: '等待选择' })
      addSession(REVIEW)
      addSession(NOTES)
      ask = questionAsk()
      break
    case 'multi':
      addSession({ ...SANDBOX, status: 'waiting', activity: '等待选择' })
      addSession(REVIEW)
      ask = multiAsk()
      break
    case 'note':
      addSession({ ...SANDBOX, status: 'waiting', activity: '等待输入' })
      addSession(REVIEW)
      ask = noteAsk()
      break
    case 'approval':
    default:
      addSession({ ...SANDBOX, status: 'waiting', activity: '等待授权' })
      addSession(REVIEW)
      addSession(NOTES)
      ask = approvalAsk()
      break
  }
  phase = 0
}

buildSessions()

let rev = 1
let notice = null
let windowGeom = null
let focusRequest = null
const log = (...a) => { if (args.verbose) console.log('[mock]', ...a) }

function sortSessions() {
  const rank = { waiting: 0, running: 1, idle: 2 }
  sessions.sort((a, b) => (rank[a.status] - rank[b.status]) || (b.updatedAt - a.updatedAt))
}

function stateJson() {
  sortSessions()
  const running = sessions.filter((s) => s.status === 'running').length
  const waiting = sessions.filter((s) => s.status === 'waiting').length
  return {
    ok: true,
    protocol: 1,
    rev,
    now: Date.now(),
    app: {
      url: 'http://127.0.0.1:50285',
      title: 'DeepSeek Harness',
      online: true,
      ...(windowGeom ? { window: windowGeom } : {}),
    },
    counts: { sessions: sessions.length, running, waiting },
    sessions: sessions.slice(0, 20),
    ask,
    notice,
  }
}

function bump() { rev += 1 }

function handleAction(body) {
  log('action', JSON.stringify(body))
  const type = String(body?.type ?? '')
  if (type === 'answer') {
    if (!ask || String(body.askId) !== ask.id) return { ok: false, error: '该确认已失效' }
    const picked = Array.isArray(body.optionIds) ? body.optionIds.map(String) : []
    const selections = body.selections && typeof body.selections === 'object' ? body.selections : null
    const chosen = selections ? Object.values(selections).flat().map(String) : picked
    if (!chosen.length) return { ok: false, error: '没有选中任何选项' }
    log('answer options:', JSON.stringify(selections ?? picked))
    ask = null
    bump()
    // 剧本推进：approval → question → 结束
    setTimeout(() => {
      if (args.scenario === 'approval' && phase === 0) {
        phase = 1
        ask = questionAsk()
        const s = sessions.find((x) => x.id === SANDBOX.id)
        if (s) { s.status = 'waiting'; s.activity = '等待选择' }
        notice = `已${chosen[0] === 'allow' ? '允许' : '拒绝'}，下一项是单选确认`
        bump()
      } else {
        notice = '确认已提交，任务继续'
        const s = sessions.find((x) => x.id === SANDBOX.id)
        if (s) { s.status = 'running'; s.activity = 'bash · pnpm test' }
        bump()
      }
    }, 900)
    return { ok: true }
  }
  if (type === 'focus') {
    focusRequest = String(body.sessionId ?? '')
    log('focus ->', focusRequest)
    return { ok: true }
  }
  if (type === 'open-main') {
    log('open-main')
    return { ok: true }
  }
  if (type === 'close') {
    log('window closing')
    return { ok: true }
  }
  return { ok: false, error: `unknown action: ${type}` }
}

const server = createServer((req, res) => {
  const url = new URL(req.url ?? '/', `http://127.0.0.1:${args.port}`)
  res.setHeader('access-control-allow-origin', '*')
  res.setHeader('access-control-allow-headers', 'content-type,x-taskbox-token')
  res.setHeader('access-control-allow-methods', 'GET,POST,OPTIONS')
  if (req.method === 'OPTIONS') { res.statusCode = 204; res.end(); return }
  const token = req.headers['x-taskbox-token'] ?? url.searchParams.get('t')
  if (token !== args.token) {
    res.statusCode = 401
    res.setHeader('content-type', 'application/json; charset=utf-8')
    res.end(JSON.stringify({ ok: false, error: 'bad token' }))
    return
  }
  const send = (obj) => {
    res.statusCode = 200
    res.setHeader('content-type', 'application/json; charset=utf-8')
    res.setHeader('cache-control', 'no-store')
    res.end(JSON.stringify(obj))
  }
  if (req.method === 'GET' && url.pathname === '/ping') return send({ ok: true })
  if (req.method === 'GET' && url.pathname === '/state') return send(stateJson())
  if (req.method === 'POST' && (url.pathname === '/action' || url.pathname === '/window')) {
    let raw = ''
    req.on('data', (c) => { raw += c })
    req.on('end', () => {
      let body = {}
      try { body = raw ? JSON.parse(raw) : {} } catch { body = {} }
      if (url.pathname === '/window') {
        if (body && typeof body.x === 'number') windowGeom = { x: body.x, y: body.y, collapsed: !!body.collapsed }
        log('window', JSON.stringify(body))
        return send({ ok: true })
      }
      send(handleAction(body))
    })
    return
  }
  res.statusCode = 404
  res.end('not found')
})

server.listen(args.port, '127.0.0.1', () => {
  const token = args.token || randomBytes(8).toString('hex')
  console.log(`[mock] listening http://127.0.0.1:${args.port}  token=${token}  scenario=${args.scenario}`)
  console.log(`[mock] state: curl -H "x-taskbox-token: ${token}" http://127.0.0.1:${args.port}/state`)
  if (args.spawn) {
    const script = join(ROOT, 'pkg', 'assets', 'minibox', 'minibox.ps1')
    if (!existsSync(script)) {
      console.error(`[mock] --spawn 需要 ${script}`)
      return
    }
    const child = spawn('powershell.exe', [
      '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
      '-File', script, '-Port', String(args.port), '-Token', token,
      '-AssetDir', dirname(script),
    ], { stdio: 'inherit', windowsHide: true })
    console.log(`[mock] spawned minibox pid=${child.pid}`)
    child.on('exit', (code) => { console.log(`[mock] minibox exited code=${code}`); server.close() })
  }
})

// 每 10 秒让 running 会话的 activity 变化，验证增量刷新不闪
setInterval(() => {
  const running = sessions.find((s) => s.status === 'running')
  if (running) {
    const steps = ['bash · pnpm test', 'read · lib/index.js', 'grep · approval', 'edit · client.js', 'web_search · wpf topmost']
    running.activity = steps[Math.floor((Date.now() - T0) / 10000) % steps.length]
    running.updatedAt = Date.now()
    bump()
  }
}, 10000).unref()
