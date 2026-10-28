#!/usr/bin/env node
/**
 * build-catalog.mjs —— 生成社区插件市场的索引源文件。
 *
 * 产出两个文件（都会被 .github/workflows/pages.yml 发布到 GitHub Pages）：
 *   catalog/catalog-source.json   索引源清单（provider 元数据 + transport 端点）
 *   catalog/v1/plugins.json       插件市场索引格式 1 的正文
 *
 * 元数据来源：pkg/package.json（name / version / description / repository）。
 * 仓库地址优先取 `git remote get-url origin`，没有 remote 时回退到 package.json 的 repository.url。
 * publishTimestamp 优先取 npm registry 上该版本的真实发布时间，取不到（还没发布）就用当前时间。
 *
 * 用法：node scripts/build-catalog.mjs [--dry]
 */
import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const PKG_DIR = join(ROOT, 'pkg')
const pkg = JSON.parse(readFileSync(join(PKG_DIR, 'package.json'), 'utf8'))

const dry = process.argv.includes('--dry')

/** 从 git remote / package.json 里推出 { owner, repo }。 */
function resolveRepo() {
  const fromPkg = pkg.repository
  const rawUrl = typeof fromPkg === 'string' ? fromPkg : fromPkg?.url ?? ''
  let url = rawUrl
  if (!url) {
    try {
      url = execFileSync('git', ['remote', 'get-url', 'origin'], { cwd: ROOT, encoding: 'utf8' }).trim()
    } catch {
      url = ''
    }
  }
  const match = /github\.com[/:]([^/]+)\/([^/#]+?)(?:\.git)?$/u.exec(url.trim())
  if (match) return { owner: match[1], repo: match[2].replace(/\.git$/u, '') }
  return { owner: 'OWNER', repo: 'dsh-taskbox' }
}

const { owner, repo } = resolveRepo()
const repoUrl = `https://github.com/${owner}/${repo}`
const pagesBase = `https://${owner}.github.io/${repo}`
const iconUrl = `${pagesBase}/icon.svg`

const zhTitle = '桌面任务浮窗'
const zhSummary = '在 Windows 桌面置顶一个小方框：实时看各对话在跑什么、几个在等确认，需要授权或选择时直接在小窗里点选，点一下把主窗口唤回前台。'
const enTitle = 'Desktop Task Box'
const enSummary = 'Pins a small always-on-top box to the Windows desktop: live status for every conversation, inline answers for pending approvals and questions, and one click to bring the main window back.'

/** npm 上该版本的真实发布时间（Unix 秒）；没发布过就返回 null。 */
async function npmPublishTime(name, version) {
  try {
    const res = await fetch(`https://registry.npmjs.org/${name.replace('/', '%2F')}`, {
      signal: AbortSignal.timeout(8000),
      headers: { accept: 'application/json' },
    })
    if (!res.ok) return null
    const doc = await res.json()
    const iso = doc?.time?.[version]
    if (typeof iso !== 'string') return null
    const t = Date.parse(iso)
    return Number.isFinite(t) ? Math.floor(t / 1000) : null
  } catch {
    return null
  }
}

const publishTimestamp = (await npmPublishTime(pkg.name, pkg.version)) ?? Math.floor(Date.now() / 1000)

const catalogSource = {
  manifestVersion: '1.0.0',
  providerId: `io.github.${owner}.${repo}`,
  name: pkg.name,
  description: enSummary,
  homepage: repoUrl,
  attribution: { name: owner, url: `https://github.com/${owner}` },
  transport: { kind: 'https-json', endpoint: `${pagesBase}/v1/plugins.json`, method: 'GET' },
  query: { supported: ['q', 'category', 'cursor', 'limit'], defaultLimit: 50, maxLimit: 50, sorts: [] },
}

const index = {
  format: 1,
  title: { en: enTitle, zh: zhTitle },
  description: { en: enSummary, zh: zhSummary },
  metadata: {
    categories: {
      desktop: { title: { en: 'Desktop', zh: '桌面' } },
      productivity: { title: { en: 'Productivity', zh: '效率' } },
    },
    labels: {},
    sortKeys: {},
  },
  plugins: [
    {
      name: pkg.name,
      title: { en: enTitle, zh: zhTitle },
      description: { en: enSummary, zh: zhSummary },
      icon: iconUrl,
      author: owner,
      homepage: repoUrl,
      repository: { url: repoUrl, directory: 'pkg' },
      metadata: {
        category: 'desktop',
        keywords: ['dsh', 'dsh-plugin', 'deepseek-harness', 'desktop', 'widget', 'approval', 'windows'],
      },
      versions: [
        {
          version: pkg.version,
          publishTimestamp,
          source: { type: 'npm' },
        },
      ],
    },
  ],
}

const sourcePath = join(ROOT, 'catalog', 'catalog-source.json')
const indexPath = join(ROOT, 'catalog', 'v1', 'plugins.json')
const sourceText = `${JSON.stringify(catalogSource, null, 2)}\n`
const indexText = `${JSON.stringify(index, null, 2)}\n`

if (dry) {
  console.log(sourceText)
  console.log(indexText)
} else {
  mkdirSync(dirname(indexPath), { recursive: true })
  writeFileSync(sourcePath, sourceText, 'utf8')
  writeFileSync(indexPath, indexText, 'utf8')
  console.log(`catalog-source.json -> ${sourcePath}`)
  console.log(`v1/plugins.json     -> ${indexPath}`)
  console.log(`plugin ${pkg.name}@${pkg.version}, publishTimestamp=${publishTimestamp}`)
  console.log(`index url: ${pagesBase}/v1/plugins.json`)
}
