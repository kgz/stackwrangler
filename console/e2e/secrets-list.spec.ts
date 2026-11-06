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

test.describe('Secrets Manager secrets UI (#176)', () => {
  test('lists a seeded secret', async ({ page }) => {
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
      await expect(
        page.getByRole('button', { name, exact: true }),
      ).toBeVisible({ timeout: 15000 })
      await expect(
        page.getByRole('button', { name: 'Store a new secret' }),
      ).toBeDisabled()
      await expect(
        page.getByRole('button', { name: 'Store a new secret' }),
      ).toHaveAttribute('title', 'To implement')
      await expect(page.getByRole('button', { name: 'Delete' })).toBeDisabled()
      await expect(page.getByRole('button', { name: 'Rotate' })).toBeDisabled()
    } finally {
      if (arn) {
        try {
          aws([
            'secretsmanager',
            'delete-secret',
            '--secret-id',
            arn,
            '--force-delete-without-recovery',
          ])
        } catch {
          /* ignore */
        }
      }
    }
  })
})
