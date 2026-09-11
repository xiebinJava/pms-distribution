// Regenerates docs/screenshots/*.png from a running install.
// Requires a sibling pms-front checkout (for @playwright/test), local Chrome,
// and ENV_FILE with bootstrap admin credentials. Do not commit that env file.
import { createRequire } from 'node:module'
import { mkdirSync, readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const frontRoot = process.env.PMS_FRONT_ROOT || resolve(root, '../pms-front')
const { chromium } = createRequire(resolve(frontRoot, 'package.json'))('@playwright/test')
const outDir = resolve(root, 'docs/screenshots')
mkdirSync(outDir, { recursive: true })

const envFile = process.env.ENV_FILE || resolve(root, '.env.smoke')
const env = Object.fromEntries(
  readFileSync(envFile, 'utf8')
    .split('\n')
    .filter((line) => line && !line.startsWith('#') && line.includes('='))
    .map((line) => {
      const i = line.indexOf('=')
      return [line.slice(0, i), line.slice(i + 1)]
    }),
)

const port = env.PMS_PORT || '5173'
const base = process.env.PMS_BASE_URL || `http://localhost:${port}`
const email = env.PMS_BOOTSTRAP_ADMIN_EMAIL
const password = env.PMS_BOOTSTRAP_ADMIN_PASSWORD
if (!email || !password) {
  throw new Error('bootstrap admin email/password missing from ENV_FILE')
}

const systemFonts = `
  *:not(svg):not(svg *) {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Helvetica Neue", Arial, sans-serif !important;
  }
`

const browser = await chromium.launch({
  headless: true,
  channel: process.env.PMS_BROWSER_CHANNEL || 'chrome',
})
const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, locale: 'en-US' })
page.on('pageerror', (error) => console.error('pageerror', error.message))
page.on('response', (response) => {
  if (response.url().includes('/api/') && response.status() >= 400) {
    console.error('http', response.status(), response.url())
  }
})
await page.addInitScript(() => localStorage.setItem('pms.locale', 'en-US'))

async function shot(name) {
  await page.addStyleTag({ content: systemFonts })
  await page.evaluate(() => document.fonts.ready)
  await page.waitForTimeout(400)
  await page.screenshot({ path: resolve(outDir, name), fullPage: false })
  console.log(`wrote ${name}`)
}

await page.goto(`${base}/login`, { waitUntil: 'networkidle' })
await page.getByRole('button', { name: /sign in/i }).waitFor({ timeout: 15000 })
await shot('login.png')

await page.locator('input[placeholder^="Email"]').fill(email)
await page.locator('input[placeholder="Password"]').fill(password)
const loginResponse = page.waitForResponse((response) => response.url().includes('/api/auth/login'), { timeout: 20000 })
await page.locator('.pms-login-submit').click()
const login = await loginResponse
if (!login.ok()) {
  throw new Error(`login HTTP ${login.status()}`)
}
await page.waitForURL((url) => !url.pathname.includes('/login'), { timeout: 20000 })
await page.waitForTimeout(1200)
await shot('workbench.png')

await page.locator('.pms-nav-group--projects .pms-nav-link').click()
await page.waitForTimeout(1000)
await shot('projects.png')

await page.goto(`${base}/projects/1`, { waitUntil: 'networkidle' })
await page.waitForTimeout(1000)
await shot('project-detail.png')

await page.locator('.pms-nav-group--configuration .pms-nav-link').filter({ hasText: /organization/i }).click()
await page.waitForTimeout(1000)
await shot('organization.png')

await browser.close()
