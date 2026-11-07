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

test.describe('KMS customer managed keys UI (#177)', () => {
  test('lists a seeded customer managed key', async ({ page }) => {
    const ts = Date.now()
    const alias = `alias/e2e-kms-ui-${ts}`
    let keyId = ''
    try {
      keyId = aws([
        'kms',
        'create-key',
        '--description',
        `e2e kms console ${ts}`,
        '--query',
        'KeyMetadata.KeyId',
        '--output',
        'text',
      ]).trim()
      aws(['kms', 'create-alias', '--alias-name', alias, '--target-key-id', keyId])

      await page.goto('/kms')
      await expect(
        page.getByRole('heading', {
          level: 1,
          name: 'Customer managed keys',
        }),
      ).toBeVisible()
      await expect(page.getByTestId('kms-keys-table')).toBeVisible()
      await expect(
        page.getByRole('button', { name: alias, exact: true }),
      ).toBeVisible({ timeout: 15000 })
      await expect(page.getByText(keyId, { exact: true })).toBeVisible()
      await expect(
        page.getByRole('button', { name: 'Create key' }),
      ).toBeDisabled()
      await expect(
        page.getByRole('button', { name: 'Create key' }),
      ).toHaveAttribute('title', 'To implement')
      await expect(page.getByRole('button', { name: 'Delete' })).toBeDisabled()
      await expect(
        page.getByRole('button', { name: 'Schedule key deletion' }),
      ).toBeDisabled()
      await expect(page.getByRole('button', { name: 'Refresh' })).toBeDisabled()
      await expect(page.getByRole('button', { name: 'Refresh' })).toHaveAttribute(
        'title',
        'To implement',
      )
    } finally {
      if (alias) {
        try {
          aws(['kms', 'delete-alias', '--alias-name', alias])
        } catch {
          /* ignore */
        }
      }
      if (keyId) {
        try {
          aws([
            'kms',
            'schedule-key-deletion',
            '--key-id',
            keyId,
            '--pending-window-in-days',
            '7',
          ])
        } catch {
          /* ignore */
        }
      }
    }
  })
})
