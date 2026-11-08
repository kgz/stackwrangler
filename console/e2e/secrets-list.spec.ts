import { expect, test } from '@playwright/test'
import { execFileSync } from 'node:child_process'
import { e2eCreds } from './helpers/env'

const EP = e2eCreds.iamEndpoint
const KEY = e2eCreds.accessKey
const SECRET = e2eCreds.secretKey
const REGION = e2eCreds.region

function aws(args: string[]): string {
  return execFileSync(
    'aws',
    ['--endpoint-url', EP, '--region', REGION, ...args],
    {
      encoding: 'utf8',
      env: {
        ...process.env,
        AWS_ACCESS_KEY_ID: KEY,
        AWS_SECRET_ACCESS_KEY: SECRET,
        AWS_DEFAULT_REGION: REGION,
      },
    },
  )
}

function deleteSecret(secretId: string) {
  try {
    aws([
      'secretsmanager',
      'delete-secret',
      '--secret-id',
      secretId,
      '--force-delete-without-recovery',
    ])
  } catch {
    /* ignore */
  }
}

test.describe('Secrets Manager console (#535)', () => {
  test('lists a seeded secret and opens detail', async ({ page }) => {
    const ts = Date.now()
    const name = `e2e/secrets-ui-${ts}`
    let arn = ''
    try {
      arn = aws([
        'secretsmanager',
        'create-secret',
        '--name',
        name,
        '--description',
        'e2e secrets console',
        '--secret-string',
        `e2e-${ts}`,
        '--query',
        'ARN',
        '--output',
        'text',
      ]).trim()

      await page.goto('/secretsmanager')
      await expect(
        page.getByRole('heading', { level: 1, name: 'Secrets' }),
      ).toBeVisible()
      await expect(page.getByTestId('secrets-table')).toBeVisible()
      const nameLink = page.getByRole('link', { name, exact: true })
      await expect(nameLink).toBeVisible({ timeout: 15000 })
      await expect(
        page.getByRole('link', { name: 'Store a new secret' }),
      ).toBeVisible()
      await expect(page.getByRole('button', { name: 'Delete' })).toBeDisabled()
      await expect(page.getByRole('button', { name: 'Rotate' })).toBeDisabled()

      await nameLink.click()
      await expect(
        page.getByRole('heading', { level: 1, name }),
      ).toBeVisible({ timeout: 15000 })
      await expect(page.getByTestId('secret-value-hidden')).toBeVisible()
      await page.getByTestId('retrieve-secret-value').click()
      await expect(page.getByTestId('secret-value-text')).toHaveText(
        `e2e-${ts}`,
        { timeout: 15000 },
      )
      await page.getByTestId('secrets-tab-versions').click()
      await expect(page.getByTestId('secret-versions-table')).toBeVisible({
        timeout: 15000,
      })
    } finally {
      if (arn) deleteSecret(arn)
    }
  })

  test('stores a new secret and opens detail', async ({ page }) => {
    const ts = Date.now()
    const name = `e2e/secrets-store-${ts}`
    const value = `store-${ts}`
    try {
      await page.goto('/secretsmanager')
      await page.getByRole('link', { name: 'Store a new secret' }).click()
      await expect(
        page.getByRole('heading', { level: 1, name: 'Store a new secret' }),
      ).toBeVisible()
      await page.getByTestId('secret-name').fill(name)
      await page.getByTestId('secret-description').fill('e2e store flow')
      await page.getByTestId('secret-string').fill(value)
      await page.getByTestId('store-secret').click()
      await expect(
        page.getByRole('heading', { level: 1, name }),
      ).toBeVisible({ timeout: 20000 })
      await expect(page.getByTestId('secret-value-hidden')).toBeVisible()
      await page.getByTestId('retrieve-secret-value').click()
      await expect(page.getByTestId('secret-value-text')).toHaveText(value, {
        timeout: 15000,
      })
    } finally {
      deleteSecret(name)
    }
  })
})
