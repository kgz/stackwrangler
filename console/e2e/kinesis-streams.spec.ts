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

function waitActive(name: string) {
  for (let i = 0; i < 60; i++) {
    try {
      const st = aws([
        'kinesis',
        'describe-stream-summary',
        '--stream-name',
        name,
        '--query',
        'StreamDescriptionSummary.StreamStatus',
        '--output',
        'text',
      ]).trim()
      if (st === 'ACTIVE') return
    } catch {
      /* creating */
    }
    execFileSync('sleep', ['1'])
  }
  throw new Error(`stream not ACTIVE: ${name}`)
}

test.describe('Kinesis data streams UI (#178)', () => {
  test('lists a seeded data stream', async ({ page }) => {
    const ts = Date.now()
    const name = `e2e-kinesis-ui-${ts}`
    try {
      aws([
        'kinesis',
        'create-stream',
        '--stream-name',
        name,
        '--shard-count',
        '1',
      ])
      waitActive(name)

      await page.goto('/kinesis')
      await expect(
        page.getByRole('heading', { level: 1, name: 'Data streams' }),
      ).toBeVisible()
      await expect(page.getByTestId('kinesis-streams-table')).toBeVisible()
      await expect(
        page.getByRole('button', { name, exact: true }),
      ).toBeVisible({ timeout: 15000 })
      await expect(
        page.getByRole('button', { name: 'Create data stream' }),
      ).toBeDisabled()
      await expect(
        page.getByRole('button', { name: 'Create data stream' }),
      ).toHaveAttribute('title', 'To implement')
      await expect(page.getByRole('button', { name: 'Delete' })).toBeDisabled()
      await expect(page.getByRole('button', { name: 'Delete' })).toHaveAttribute(
        'title',
        'Select a row',
      )
    } finally {
      try {
        aws(['kinesis', 'delete-stream', '--stream-name', name])
      } catch {
        /* ignore */
      }
    }
  })
})
