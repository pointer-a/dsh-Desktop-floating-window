#!/usr/bin/env node
/**
 * race-selftest.mjs —— 专测「小窗优先、宽限期后才转发给浏览器」的竞速逻辑。
 *
 * 这组用例覆盖本次真机发现的缺陷：如果先转发给浏览器、随后又在小窗里作答，
 * 浏览器那张确认卡就成了孤儿（"小窗答完了、主窗口选择还在"）。
 *
 * 用法：node test/race-selftest.mjs
 */
import assert from 'node:assert/strict'
import { createCtx } from './fake-ctx.mjs'
import { AskRegistry } from '../pkg/lib/asks.js'
import { interceptApprovals, interceptQuestions } from '../pkg/lib/dsh-adapters.js'

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
let failures = 0
async function check(name, fn) {
  try {
    await fn()
    console.log(`  \u2713 ${name}`)
  } catch (err) {
    failures += 1
    console.log(`  \u2717 ${name}\n      ${String(err?.message ?? err).split('\n').join('\n      ')}`)
  }
}

function makeStore() {
  return {
    calls: 0,
    titleOf: () => '测试对话',
    markWaiting: () => {},
    clearWaiting: () => {},
    describeCall: () => 'bash · pnpm test',
  }
}

function setup(hasWindow, delayMs) {
  process.env.DSH_TASKBOX_FORWARD_DELAY_MS = String(delayMs)
  const ctx = createCtx()
  const log = () => {}
  const bump = () => {}
  const asks = new AskRegistry({ logger: log, bump })
  const store = makeStore()
  const deps = { ctx, asks, store, log, hasWindow }
  const disposeApprovals = interceptApprovals(deps)
  const disposeQuestions = interceptQuestions(deps)
  return { ctx, asks, deps, dispose: () => { disposeApprovals?.(); disposeQuestions?.() } }
}

const approvalReq = (signal) => ({ agent: { id: 's-1' }, toolName: 'bash', callId: 'c-1', reason: '需要授权', signal })

function dispatchApproval(ctx, req) {
  const trace = { nextCalls: 0, resolveBrowser: null }
  const promise = ctx.waterfall('approval/request', [req], () => {
    trace.nextCalls += 1
    return new Promise((resolve) => { trace.resolveBrowser = resolve })
  })
  return { promise, trace }
}

async function main() {
  console.log('授权：小窗在宽限期内作答 → 完全不转发给浏览器')
  await check('next() 不被调用，返回 allowed-once', async () => {
    const { ctx, asks, dispose } = setup(() => true, 300)
    try {
      const { promise, trace } = dispatchApproval(ctx, approvalReq(new AbortController().signal))
      await sleep(80)
      assert.equal(trace.nextCalls, 0, '宽限期内不应转发')
      const ask = asks.current()
      assert.ok(ask && ask.kind === 'approval')
      assert.equal(asks.answer(ask.id, { optionIds: ['allow'] }).ok, true)
      assert.equal(await promise, 'allowed-once')
      assert.equal(trace.nextCalls, 0, '小窗作答后仍然不应转发（否则浏览器留下孤儿卡）')
    } finally {
      dispose()
    }
  })

  console.log('授权：宽限期过后才转发 → 浏览器作答生效')
  await check('next() 被调用，采用浏览器的 rejected', async () => {
    const { ctx, dispose } = setup(() => true, 150)
    try {
      const { promise, trace } = dispatchApproval(ctx, approvalReq(new AbortController().signal))
      await sleep(60)
      assert.equal(trace.nextCalls, 0)
      await sleep(200)
      assert.equal(trace.nextCalls, 1, '宽限期后必须转发')
      trace.resolveBrowser('rejected')
      assert.equal(await promise, 'rejected')
    } finally {
      dispose()
    }
  })

  console.log('授权：转发之后小窗再答 → 以先到的为准')
  await check('小窗在转发后作答仍然生效', async () => {
    const { ctx, asks, dispose } = setup(() => true, 120)
    try {
      const { promise, trace } = dispatchApproval(ctx, approvalReq(new AbortController().signal))
      await sleep(240)
      assert.equal(trace.nextCalls, 1)
      const ask = asks.current()
      assert.ok(ask, '转发后卡片仍应显示（两边都能答）')
      asks.answer(ask.id, { optionIds: ['deny'] })
      assert.equal(await promise, 'rejected')
    } finally {
      dispose()
    }
  })

  console.log('授权：小窗没在跑 → 立刻转发（不拖慢主窗口体验）')
  await check('next() 在 50ms 内被调用', async () => {
    const { ctx, dispose } = setup(() => false, 6000)
    try {
      const { promise, trace } = dispatchApproval(ctx, approvalReq(new AbortController().signal))
      await sleep(30)
      assert.equal(trace.nextCalls, 1)
      trace.resolveBrowser('allowed-once')
      assert.equal(await promise, 'allowed-once')
    } finally {
      dispose()
    }
  })

  console.log('授权：请求被 abort（用户在主窗口取消/轮次结束）')
  await check('返回 cancelled，且不转发', async () => {
    const { ctx, dispose } = setup(() => true, 5000)
    try {
      const controller = new AbortController()
      const { promise, trace } = dispatchApproval(ctx, approvalReq(controller.signal))
      await sleep(60)
      controller.abort()
      assert.equal(await promise, 'cancelled')
      assert.equal(trace.nextCalls, 0)
    } finally {
      dispose()
    }
  })

  console.log('提问：小窗内作答 → answers[].selected 是 label')
  await check('不转发，返回正确答案形状', async () => {
    const { ctx, asks, dispose } = setup(() => true, 400)
    try {
      const request = {
        agent: { id: 's-1' },
        signal: new AbortController().signal,
        questions: [
          { id: 'q1', question: '停在哪？', options: [{ label: '右下角' }, { label: '左下角' }] },
          { id: 'q2', question: '补什么？', multiSelect: true, options: [{ label: 'README' }, { label: '截图' }] },
        ],
      }
      let nextCalls = 0
      const promise = ctx.waterfall('user-questions/request', [request], () => {
        nextCalls += 1
        return new Promise(() => {})
      })
      await sleep(80)
      assert.equal(nextCalls, 0)
      const ask = asks.current()
      const selections = {}
      selections[ask.items[0].id] = [ask.items[0].options[1].id]
      selections[ask.items[1].id] = [ask.items[1].options[0].id, ask.items[1].options[1].id]
      assert.equal(asks.answer(ask.id, { selections }).ok, true)
      assert.deepEqual(await promise, {
        answers: [
          { id: 'q1', selected: ['左下角'] },
          { id: 'q2', selected: ['README', '截图'] },
        ],
      })
      assert.equal(nextCalls, 0)
    } finally {
      dispose()
    }
  })

  console.log('提问：需要文字输入（没有选项）→ 卡片带 note')
  await check('note 提示回主窗口，且宽限期内不转发', async () => {
    const { ctx, asks, dispose } = setup(() => true, 300)
    try {
      const request = {
        agent: { id: 's-1' },
        signal: new AbortController().signal,
        questions: [{ id: 'q-free', question: '报错原文是什么？' }],
      }
      const promise = ctx.waterfall('user-questions/request', [request], () => new Promise(() => {}))
      await sleep(60)
      const ask = asks.current()
      assert.ok(ask)
      assert.match(ask.note, /主窗口/)
      assert.deepEqual(ask.items[0].options, [])
      void promise
    } finally {
      dispose()
    }
  })

  console.log('')
  if (failures > 0) {
    console.log(`FAILED: ${failures} 项`)
    process.exit(1)
  }
  console.log('ALL PASS')
  process.exit(0)
}

const bomb = setTimeout(() => {
  console.log('TIMEOUT: 超过 30s')
  process.exit(1)
}, 30_000)
bomb.unref?.()

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
