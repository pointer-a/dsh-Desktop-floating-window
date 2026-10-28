#!/usr/bin/env node
/**
 * host-selftest.mjs —— Host 半区离线自检（不需要安装插件，也不碰 DSH）。
 *
 * 用一个假的 Cordis ctx 跑 `pkg/lib/index.js`，验证：
 *   1. 模块能被 import、apply 不抛异常
 *   2. 本地 HTTP 服务起来了，token 鉴权生效
 *   3. session 事件 → /state 的会话列表、运行状态、活动短语
 *   4. approval/request waterfall 的「认领」链路（小窗点允许 → 返回 allowed-once）
 *   5. user-questions/request waterfall 的作答形状（answers[].selected 是 label）
 *   6. 浏览器先作答时，待确认会从 /state 消失
 *
 * 用法：node test/host-selftest.mjs
 */
import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createCtx } from './fake-ctx.mjs'

const HOME = mkdtempSync(join(tmpdir(), 'taskbox-selftest-'))
process.env.DSH_HOME = HOME
process.env.DSH_TASKBOX_AUTOSTART = '0'

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
let failures = 0
function check(name, fn) {
  try {
    fn()
    console.log(`  \u2713 ${name}`)
  } catch (err) {
    failures += 1
    console.log(`  \u2717 ${name}\n      ${String(err?.message ?? err).split('\n').join('\n      ')}`)
  }
}
async function checkAsync(name, fn) {
  try {
    await fn()
    console.log(`  \u2713 ${name}`)
  } catch (err) {
    failures += 1
    console.log(`  \u2717 ${name}\n      ${String(err?.message ?? err).split('\n').join('\n      ')}`)
  }
}

async function main() {
  console.log(`selftest home: ${HOME}`)
  const ctx = createCtx()
  // 可选服务的替身：GUI 地址 + 命令注册表（插件用局部 inject 消费）
  const commands = []
  ctx.services.set('webServer', { getOrigin: () => 'http://127.0.0.1:50285' })
  ctx.services.set('commands', {
    register(definition) {
      commands.push(definition)
      return () => {
        const index = commands.indexOf(definition)
        if (index >= 0) commands.splice(index, 1)
      }
    },
  })
  const store = await import('../pkg/lib/index.js')
  check('module exports apply()', () => assert.equal(typeof store.apply, 'function'))
  store.apply(ctx)
  await sleep(400)

  const info = JSON.parse(readFileSync(join(HOME, 'task-box', 'server.json'), 'utf8'))
  const base = `http://127.0.0.1:${info.port}`
  const auth = { 'x-taskbox-token': info.token }
  const getState = async () => {
    const res = await fetch(`${base}/state`, { headers: auth })
    assert.equal(res.status, 200)
    return res.json()
  }
  const act = async (body) => {
    const res = await fetch(`${base}/action`, {
      method: 'POST',
      headers: { ...auth, 'content-type': 'application/json' },
      body: JSON.stringify(body),
    })
    assert.equal(res.status, 200)
    return res.json()
  }

  console.log('HTTP / 鉴权')
  await checkAsync('GET /state 无 token → 401', async () => {
    const res = await fetch(`${base}/state`)
    assert.equal(res.status, 401)
  })
  await checkAsync('GET /state 带 token → 合法空 envelope', async () => {
    const state = await getState()
    assert.equal(state.ok, true)
    assert.equal(state.protocol, 1)
    assert.deepEqual(state.sessions, [])
    assert.equal(state.ask, null)
    assert.equal(typeof state.rev, 'number')
  })

  console.log('会话列表 / 状态')
  const sessionA = { id: 's-1' }
  const sessionB = { id: 's-2' }
  ctx.emit('session/created', sessionA)
  ctx.emit('session/created', sessionB)
  ctx.services.set('sessionTitle', { get: (session) => ({ title: session.id === 's-1' ? '写一个桌面浮窗插件' : '离线包签名排查' }) })
  ctx.services.set('workingDirectory', { get: () => 'E:\\dsh插件' })
  ctx.services.set('agents', { list: () => [{ id: 's-1', status: 'running', session: sessionA }, { id: 's-2', status: 'idle', session: sessionB }] })
  ctx.emit('session/event', sessionA, { type: 'turn/start', data: {} })
  ctx.emit('session/event', sessionA, { type: 'tool/call', data: { name: 'bash', callId: 'c-9', arguments: { command: 'pnpm test' } } })
  await sleep(1200) // 让 1s 心跳完成一次 reconcile

  await checkAsync('会话进入列表，带标题/状态/活动短语/工作区', async () => {
    const state = await getState()
    assert.equal(state.sessions.length, 2)
    assert.equal(state.counts.sessions, 2)
    const first = state.sessions[0]
    assert.equal(first.id, 's-1')
    assert.equal(first.status, 'running')
    assert.equal(first.title, '写一个桌面浮窗插件')
    assert.equal(first.activity, 'bash · pnpm test')
    assert.equal(first.workspace, 'dsh插件')
    assert.equal(state.sessions[1].status, 'idle')
  })

  console.log('授权确认（approval/request）')
  const controller = new AbortController()
  let browserAnswer
  const approvalPromise = ctx.waterfall(
    'approval/request',
    [{ agent: { id: 's-1' }, toolName: 'bash', callId: 'c-9', reason: '需要允许在沙箱外执行命令', signal: controller.signal }],
    () => new Promise((resolve) => { browserAnswer = resolve }),
  )
  await sleep(50)
  let askId = null
  await checkAsync('/state 出现授权卡片，且详情带上了那次工具调用', async () => {
    const state = await getState()
    assert.ok(state.ask, 'state.ask 应为对象')
    assert.equal(state.ask.kind, 'approval')
    assert.equal(state.ask.sessionTitle, '写一个桌面浮窗插件')
    assert.match(state.ask.detail, /沙箱外执行命令/)
    assert.match(state.ask.detail, /bash · pnpm test/)
    assert.equal(state.ask.meta, 'bash')
    const ids = state.ask.items[0].options.map((option) => option.id)
    assert.deepEqual(ids, ['allow', 'deny'])
    askId = state.ask.id
    assert.equal(state.sessions[0].status, 'waiting')
  })
  await checkAsync('小窗点「允许」→ waterfall 返回 allowed-once', async () => {
    const result = await act({ type: 'answer', askId, optionIds: ['allow'] })
    assert.equal(result.ok, true)
    const outcome = await approvalPromise
    assert.equal(outcome, 'allowed-once')
  })
  await checkAsync('作答后 /state 不再显示确认', async () => {
    const state = await getState()
    assert.equal(state.ask, null)
  })

  console.log('授权确认：拒绝 + 浏览器先答')
  let rejectId = null
  const rejectPrompt = ctx.waterfall(
    'approval/request',
    [{ agent: { id: 's-2' }, toolName: 'pwsh', reason: '需要允许删除目录', signal: new AbortController().signal }],
    () => new Promise(() => {}),
  )
  await sleep(50)
  rejectId = (await getState()).ask.id
  await checkAsync('小窗点「拒绝」→ rejected', async () => {
    await act({ type: 'answer', askId: rejectId, optionIds: ['deny'] })
    assert.equal(await rejectPrompt, 'rejected')
  })

  const browserFirst = ctx.waterfall(
    'approval/request',
    [{ agent: { id: 's-1' }, toolName: 'write', reason: '需要允许写文件', signal: new AbortController().signal }],
    async () => 'allowed-once',
  )
  await checkAsync('浏览器先作答 → waterfall 直接通过，/state 不残留', async () => {
    assert.equal(await browserFirst, 'allowed-once')
    await sleep(30)
    assert.equal((await getState()).ask, null)
  })

  console.log('提问确认（user-questions/request）')
  const questionRequest = {
    agent: { id: 's-1' },
    signal: new AbortController().signal,
    questions: [
      {
        id: 'q-plan',
        header: '停靠位置',
        question: '浮窗默认停在哪？',
        options: [{ label: '右下角' }, { label: '左下角' }],
      },
      {
        id: 'q-tags',
        question: '上线前补哪些东西？',
        multiSelect: true,
        options: [{ label: 'README' }, { label: '截图' }, { label: '自检脚本' }],
      },
    ],
  }
  let questionAnswer
  const questionPromise = ctx.waterfall('user-questions/request', [questionRequest], () => new Promise((resolve) => { questionAnswer = resolve }))
  await sleep(50)
  await checkAsync('/state 出现两项问题、多选题标记正确', async () => {
    const state = await getState()
    assert.ok(state.ask)
    assert.equal(state.ask.kind, 'question')
    assert.equal(state.ask.items.length, 2)
    assert.equal(state.ask.items[1].multiSelect, true)
    assert.equal(state.ask.multiSelect, true)
    assert.equal(state.ask.items[0].options.length, 2)
  })
  const questionAsk = (await getState()).ask
  await checkAsync('多 item 作答 → selected 里是 label 文本', async () => {
    const selections = {}
    selections[questionAsk.items[0].id] = [questionAsk.items[0].options[0].id]
    selections[questionAsk.items[1].id] = [questionAsk.items[1].options[1].id, questionAsk.items[1].options[2].id]
    const result = await act({ type: 'answer', askId: questionAsk.id, selections })
    assert.equal(result.ok, true)
    assert.deepEqual(await questionPromise, {
      answers: [
        { id: 'q-plan', selected: ['右下角'] },
        { id: 'q-tags', selected: ['截图', '自检脚本'] },
      ],
    })
  })

  console.log('可选服务（局部 inject）')
  await checkAsync('/state.app.url 来自 webServer.getOrigin()', async () => {
    const state = await getState()
    assert.equal(state.app.url, 'http://127.0.0.1:50285')
  })
  await checkAsync('/taskbox 命令已注册，description 面向用户', () => {
    const def = commands.find((entry) => entry.name === 'taskbox')
    assert.ok(def, '应注册 taskbox 命令（手动唤回小窗的入口）')
    assert.match(String(def.description), /浮窗/)
    assert.equal(typeof def.handler, 'function')
  })

  console.log('错误动作')
  await checkAsync('未选择任何选项 → ok:false 且有中文提示', async () => {
    const result = await act({ type: 'answer', askId: 'ask-404', optionIds: ['allow'] })
    assert.equal(result.ok, false)
    assert.match(result.error, /失效/)
  })
  await checkAsync('POST /window 记录几何', async () => {
    const res = await fetch(`${base}/window`, {
      method: 'POST',
      headers: { ...auth, 'content-type': 'application/json' },
      body: JSON.stringify({ type: 'moved', x: 1200, y: 700, collapsed: false }),
    })
    assert.equal(res.status, 200)
    await sleep(30)
    const saved = JSON.parse(readFileSync(join(HOME, 'task-box', 'window.json'), 'utf8'))
    assert.equal(saved.x, 1200)
  })
  await checkAsync('/state.app.window 下发布局', async () => {
    const state = await getState()
    assert.equal(state.app.window.x, 1200)
  })

  console.log('')
  rmSync(HOME, { recursive: true, force: true })
  if (failures > 0) {
    console.log(`FAILED: ${failures} 项`)
    process.exit(1)
  }
  console.log('ALL PASS')
  process.exit(0)
}

// 兜底：任何路径都不许把自检挂成僵尸进程
const bomb = setTimeout(() => {
  console.log('TIMEOUT: 自检超过 40s 未结束')
  process.exit(1)
}, 40_000)
bomb.unref?.()

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
