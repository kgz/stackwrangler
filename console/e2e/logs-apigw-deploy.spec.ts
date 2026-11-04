import { execFileSync } from 'node:child_process'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { expect, test } from '@playwright/test'

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..')


function zipHello(path: string): void {
  execFileSync(
    'python3',
    [
      '-c',
      `import zipfile; z=zipfile.ZipFile(${JSON.stringify(path)},'w'); z.writestr('index.js', 'exports.handler=async(e)=>({uiDeploy:true,echo:e});\\n'); z.close()`,
    ],
    { encoding: 'utf8' },
  )
}

test.describe('Logs + API GW + zip deploy', () => {
  test('logs page lists groups after lambda smoke', async ({ page }) => {
    test.setTimeout(180_000)
    execFileSync(join(root, 'smokes', 'lambda', 'lambda-smoke.sh'), {
      encoding: 'utf8',
      timeout: 120_000,
    })
    await page.goto('/logs')
    await expect(
      page.getByRole('heading', { name: 'Log groups', exact: true }),
    ).toBeVisible()
    await page.getByRole('button', { name: 'Refresh', exact: true }).click()
    await expect(
      page.getByRole('cell').filter({ hasText: '/aws/lambda/' }).first(),
    ).toBeVisible({ timeout: 60_000 })
  })


  test('deploy zip from Lambda page', async ({ page }) => {
    test.setTimeout(180_000)
    const zipPath = join(tmpdir(), `awsbox-ui-deploy-${Date.now()}.zip`)
    zipHello(zipPath)
    const name = `awsbox-ui-zip-${Date.now()}`

    await page.goto('/lambda')
    await page.getByPlaceholder('stackwrangler-deploy-…').fill(name)
    await page.getByLabel('Lambda zip file').setInputFiles(zipPath)
    await expect(
      page.getByRole('status').filter({ hasText: `Deployed zip to ${name}` }),
    ).toBeVisible({ timeout: 120_000 })
    await expect(page.getByRole('cell', { name, exact: true })).toBeVisible()
  })

  test('API Gateway create + probe', async ({ page }) => {
    test.setTimeout(180_000)
    execFileSync(join(root, 'smokes', 'lambda', 'lambda-smoke.sh'), ['awsbox-hello'], {
      encoding: 'utf8',
      timeout: 120_000,
    })
    await page.goto('/apigateway')
    await expect(
      page.getByRole('heading', { name: 'APIs', exact: true }),
    ).toBeVisible()
    await page.getByRole('button', { name: 'Create HTTP API → Lambda' }).click()
    await expect(
      page.getByRole('status').filter({ hasText: 'Created API' }),
    ).toBeVisible({ timeout: 60_000 })
    await page.getByRole('button', { name: 'GET invoke URL' }).click()
    await expect(page.getByText(/HTTP 2/)).toBeVisible({ timeout: 90_000 })
  })
})
