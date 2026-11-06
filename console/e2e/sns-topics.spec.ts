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

test.describe('SNS topics UI (#172)', () => {
  test('lists a seeded topic', async ({ page }) => {
    const ts = Date.now()
    const name = `e2e-sns-ui-${ts}`
    let arn = ''
    try {
      arn = aws([
        'sns',
        'create-topic',
        '--name',
        name,
        '--query',
        'TopicArn',
        '--output',
        'text',
      ]).trim()

      await page.goto('/sns')
      await expect(
        page.getByRole('heading', { level: 1, name: 'Topics' }),
      ).toBeVisible()
      await expect(page.getByTestId('sns-topics-table')).toBeVisible()
      await expect(
        page.getByRole('button', { name, exact: true }),
      ).toBeVisible({ timeout: 15000 })
      await expect(
        page.getByRole('button', { name: 'Create topic' }),
      ).toBeDisabled()
      await expect(
        page.getByRole('button', { name: 'Create topic' }),
      ).toHaveAttribute('title', 'To implement')
      await expect(page.getByRole('button', { name: 'Delete' })).toBeDisabled()
      await expect(page.getByRole('button', { name: 'Delete' })).toHaveAttribute(
        'title',
        'Select a row',
      )
    } finally {
      if (arn) {
        try {
          aws(['sns', 'delete-topic', '--topic-arn', arn])
        } catch {
          /* ignore */
        }
      }
    }
  })
})
