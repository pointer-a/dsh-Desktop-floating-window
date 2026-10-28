#!/usr/bin/env node
/**
 * validate-catalog.mjs —— 按 DSH 插件市场索引「格式 1」的规则校验 catalog/v1/plugins.json。
 *
 * 真源是 DSH 自带的 @deepseek-ai/dsh-plugin-market-index（parseMarketIndex）。那份实现没有作为
 * 公开 npm 包发布，所以这里按它读取的规则做一份等价校验，用于 CI 与本地发布前自检；
 * 规则与官方实现不一致时以官方为准。
 *
 * 用法：node scripts/validate-catalog.mjs
 */
import { readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const INDEX_PATH = join(ROOT, 'catalog', 'v1', 'plugins.json')

const LANGUAGE_ID = /^[a-z]{2,8}(?:-[a-z0-9]{1,8})*$/u
const PACKAGE_NAME = /^(?:@[a-z0-9][a-z0-9._~-]*\/)?[a-z0-9][a-z0-9._~-]*$/u
const SEMVER = /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-(?:(?:0|[1-9]\d*)|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:(?:0|[1-9]\d*)|\d*[a-zA-Z-][0-9a-zA-Z-]*))*)?(?:\+[0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*)?$/u
const COMMIT = /^[0-9a-f]{40}$/u
const DATA_ICON = /^data:(?:image\/svg\+xml|image\/png|image\/jpeg|image\/webp);base64,([A-Za-z0-9+/]*={0,2})$/u
const PATH_SEGMENT = /^[A-Za-z0-9._@+-]+$/u
const MAX_PUBLISH_TIMESTAMP = 1e11

const problems = []
function fail(path, reason) {
  problems.push(`${path} ${reason}`)
}
function isObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
function requireObject(value, path) {
  if (!isObject(value)) { fail(path, 'must be an object'); return {} }
  return value
}
function requireString(value, path) {
  if (typeof value !== 'string' || value.trim() === '') { fail(path, 'must be a non-empty string'); return '' }
  return value
}
function checkLocalized(value, path) {
  if (typeof value === 'string') return
  const object = requireObject(value, path)
  const keys = Object.keys(object)
  for (const key of keys) {
    if (!LANGUAGE_ID.test(key)) fail(`${path}.${key}`, 'must be a lowercase language id')
    requireString(object[key], `${path}.${key}`)
  }
  if (!Object.hasOwn(object, 'en')) fail(path, 'must contain en')
}
function checkDeclarations(value, path, withOrder) {
  const object = requireObject(value, path)
  for (const [id, entry] of Object.entries(object)) {
    if (id === '') fail(path, 'must not declare an empty id')
    const declaration = requireObject(entry, `${path}.${id}`)
    checkLocalized(declaration.title, `${path}.${id}.title`)
    if (withOrder && declaration.order !== 'asc' && declaration.order !== 'desc') {
      fail(`${path}.${id}.order`, 'must be "asc" or "desc"')
    }
  }
  return new Set(Object.keys(object))
}
function checkUrl(value, path, protocols, { allowQuery = false } = {}) {
  const text = requireString(value, path)
  let url
  try {
    url = new URL(text)
  } catch {
    fail(path, 'must be an absolute URL')
    return ''
  }
  if (!protocols.includes(url.protocol)) fail(path, `must use ${protocols.join(' or ')}`)
  if (url.username !== '' || url.password !== '') fail(path, 'must not contain credentials')
  if (!allowQuery && (url.href.includes('?') || url.href.includes('#'))) fail(path, 'must not contain a query or fragment')
  return url
}

function main() {
  const raw = readFileSync(INDEX_PATH, 'utf8')
  let doc
  try {
    doc = JSON.parse(raw)
  } catch (err) {
    console.error(`catalog/v1/plugins.json is not valid JSON: ${err.message}`)
    process.exit(1)
  }

  const root = requireObject(doc, '$')
  if (root.format !== 1) fail('$.format', 'must be 1')
  checkLocalized(root.title, '$.title')
  if (root.description !== undefined) checkLocalized(root.description, '$.description')

  const metadata = root.metadata === undefined ? {} : requireObject(root.metadata, '$.metadata')
  const categories = metadata.categories === undefined ? new Set() : checkDeclarations(metadata.categories, '$.metadata.categories', false)
  const labels = metadata.labels === undefined ? new Set() : checkDeclarations(metadata.labels, '$.metadata.labels', false)
  const sortKeys = metadata.sortKeys === undefined ? new Set() : checkDeclarations(metadata.sortKeys, '$.metadata.sortKeys', true)

  if (!Array.isArray(root.plugins)) {
    fail('$.plugins', 'must be an array')
  } else {
    const names = new Set()
    root.plugins.forEach((plugin, position) => {
      const path = `$.plugins[${position}]`
      const entry = requireObject(plugin, path)
      const name = requireString(entry.name, `${path}.name`)
      if (name && (name.length > 214 || !PACKAGE_NAME.test(name))) fail(`${path}.name`, 'must be a valid npm package name')
      if (names.has(name)) fail(`${path}.name`, `duplicates ${name}`)
      names.add(name)

      if (entry.title !== undefined) checkLocalized(entry.title, `${path}.title`)
      if (entry.description !== undefined) checkLocalized(entry.description, `${path}.description`)
      if (entry.author !== undefined) requireString(entry.author, `${path}.author`)
      if (entry.homepage !== undefined) checkUrl(entry.homepage, `${path}.homepage`, ['https:', 'http:'], { allowQuery: true })
      if (entry.icon !== undefined) {
        const icon = requireString(entry.icon, `${path}.icon`)
        if (icon.startsWith('data:')) {
          const payload = DATA_ICON.exec(icon)?.[1]
          if (!payload) fail(`${path}.icon`, 'must be a base64 SVG/PNG/JPEG/WebP data URL')
          else if ((payload.length / 4) * 3 > 32 * 1024) fail(`${path}.icon`, 'must not exceed 32 KiB decoded')
        } else {
          checkUrl(icon, `${path}.icon`, ['https:', 'http:'])
        }
      }
      if (entry.repository !== undefined) {
        const repository = requireObject(entry.repository, `${path}.repository`)
        checkUrl(repository.url, `${path}.repository.url`, ['https:', 'http:'])
        if (repository.directory !== undefined) {
          const text = requireString(repository.directory, `${path}.repository.directory`)
          if (text.split('/').some((segment) => segment === '.' || segment === '..' || !PATH_SEGMENT.test(segment))) {
            fail(`${path}.repository.directory`, 'must be a relative directory without . or ..')
          }
        }
      }

      const pluginMetadata = entry.metadata === undefined ? {} : requireObject(entry.metadata, `${path}.metadata`)
      if (pluginMetadata.category !== undefined && !categories.has(pluginMetadata.category)) {
        fail(`${path}.metadata.category`, `references undeclared category ${JSON.stringify(pluginMetadata.category)}`)
      }
      if (pluginMetadata.keywords !== undefined) {
        if (!Array.isArray(pluginMetadata.keywords)) fail(`${path}.metadata.keywords`, 'must be an array')
        else pluginMetadata.keywords.forEach((keyword, at) => {
          if (typeof keyword !== 'string') fail(`${path}.metadata.keywords[${at}]`, 'must be a string')
        })
      }
      if (pluginMetadata.labels !== undefined) {
        if (!Array.isArray(pluginMetadata.labels)) fail(`${path}.metadata.labels`, 'must be an array')
        else {
          const seen = new Set()
          pluginMetadata.labels.forEach((label, at) => {
            if (!labels.has(label)) fail(`${path}.metadata.labels[${at}]`, `references undeclared label ${JSON.stringify(label)}`)
            if (seen.has(label)) fail(`${path}.metadata.labels`, 'must not repeat a label')
            seen.add(label)
          })
        }
      }
      if (pluginMetadata.sortKeys !== undefined) {
        const values = requireObject(pluginMetadata.sortKeys, `${path}.metadata.sortKeys`)
        for (const [id, value] of Object.entries(values)) {
          if (!sortKeys.has(id)) fail(`${path}.metadata.sortKeys.${id}`, 'references undeclared sort key')
          if (typeof value !== 'number' || !Number.isFinite(value)) fail(`${path}.metadata.sortKeys.${id}`, 'must be a finite number')
        }
      }

      if (!Array.isArray(entry.versions) || entry.versions.length === 0) {
        fail(`${path}.versions`, 'must be a non-empty array')
        return
      }
      const versions = new Set()
      entry.versions.forEach((version, at) => {
        const atPath = `${path}.versions[${at}]`
        const item = requireObject(version, atPath)
        const value = requireString(item.version, `${atPath}.version`)
        if (value && !SEMVER.test(value)) fail(`${atPath}.version`, 'must be an exact SemVer version')
        if (versions.has(value)) fail(`${atPath}.version`, `duplicates ${value}`)
        versions.add(value)
        const stamp = item.publishTimestamp
        if (!Number.isInteger(stamp) || stamp < 0 || stamp >= MAX_PUBLISH_TIMESTAMP) {
          fail(`${atPath}.publishTimestamp`, 'must be an integer number of Unix seconds in [0, 10^11)')
        }
        const source = requireObject(item.source, `${atPath}.source`)
        if (source.type === 'npm') {
          if (source.registry !== undefined) checkUrl(source.registry, `${atPath}.source.registry`, ['https:', 'http:'])
        } else if (source.type === 'git') {
          checkUrl(source.url, `${atPath}.source.url`, ['https:'])
          requireString(source.commit, `${atPath}.source.commit`)
          if (!COMMIT.test(source.commit ?? '')) fail(`${atPath}.source.commit`, 'must be a lowercase 40-hex-digit commit SHA')
        } else {
          fail(`${atPath}.source.type`, 'must be "npm" or "git"')
        }
        if (item.engines !== undefined) {
          const engines = requireObject(item.engines, `${atPath}.engines`)
          if (engines.dsh !== undefined) {
            const range = requireString(engines.dsh, `${atPath}.engines.dsh`)
            if (range.startsWith('workspace:')) fail(`${atPath}.engines.dsh`, 'must not be a workspace: range')
          }
        }
      })
    })
  }

  if (problems.length > 0) {
    console.error('catalog/v1/plugins.json 不符合插件市场索引格式 1：')
    for (const problem of problems) console.error(`  - ${problem}`)
    process.exit(1)
  }
  console.log(`catalog/v1/plugins.json OK（${root.plugins.length} 个插件）`)
}

main()
