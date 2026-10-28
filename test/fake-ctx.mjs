/**
 * fake-ctx.mjs —— 最小 Cordis 上下文替身，让 Host 半区可以脱离 DSH 单独跑。
 *
 * 只实现插件真正用到的部分：`on`（含 prepend）/ `effect` / `get` / 事件派发 / waterfall。
 * 自检（host-selftest.mjs）与真实开窗联调（live-window.mjs）共用。
 */
export function createCtx() {
  const hooks = new Map()
  const services = new Map()
  const ctx = {
    services,
    hooks,
    on(name, listener, options) {
      const list = hooks.get(name) ?? []
      const hook = { listener }
      if (options && typeof options === 'object' && options.prepend) list.unshift(hook)
      else list.push(hook)
      hooks.set(name, list)
      return () => {
        const index = list.indexOf(hook)
        if (index >= 0) list.splice(index, 1)
      }
    },
    effect(fn) {
      const disposer = fn()
      return () => { if (typeof disposer === 'function') disposer() }
    },
    get(name) { return services.get(name) },
    /** 局部依赖注入：服务都在就立即回调（真实 cordis 会在服务出现时回调，这里只测即时分支）。 */
    inject(names, callback) {
      if (!Array.isArray(names) || !names.every((name) => services.has(name))) return false
      const injected = Object.create(ctx)
      for (const [key, value] of services) injected[key] = value
      injected.effect = ctx.effect
      callback(injected)
      return true
    },
    emit(name, ...args) {
      for (const hook of [...(hooks.get(name) ?? [])]) hook.listener(...args)
    },
    /** 按 cordis 的水位语义派发：最外层先跑，`next` 由我们注入为最后一个实参。 */
    waterfall(name, args, inner) {
      const chain = (hooks.get(name) ?? []).map((hook) => hook.listener)
      const next = () => {
        const cb = chain.shift() ?? inner
        return cb(...args, next)
      }
      return next()
    },
  }
  return ctx
}
