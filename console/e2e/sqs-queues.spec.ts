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

test.describe('SQS queues UI (#167)', () => {
  test('lists a seeded queue', async ({ page }) => {
    const ts = Date.now()
    const name = `e2e-sqs-ui-${ts}`
    let queueUrl = ''
    try {
      queueUrl = aws([
        'sqs',
        'create-queue',
        '--queue-name',
        name,
        '--query',
        'QueueUrl',
        '--output',
        'text',
      ]).trim()

      await page.goto('/sqs')
      await expect(
        page.getByRole('heading', { level: 1, name: 'Queues' }),
      ).toBeVisible()
      await expect(page.getByTestId('sqs-queues-table')).toBeVisible()
      await expect(
        page.getByRole('button', { name, exact: true }),
      ).toBeVisible({ timeout: 15000 })
      await expect(
        page.getByRole('button', { name: 'Create queue' }),
      ).toBeDisabled()
      await expect(
        page.getByRole('button', { name: 'Create queue' }),
      ).toHaveAttribute('title', 'To implement')
      await expect(page.getByRole('button', { name: 'Delete' })).toBeDisabled()
      await expect(page.getByRole('button', { name: 'Delete' })).toHaveAttribute(
        'title',
        'Select a row',
      )
    } finally {
      if (queueUrl) {
        try {
          aws(['sqs', 'delete-queue', '--queue-url', queueUrl])
        } catch {
          /* ignore */
        }
      }
    }
  })
})
