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

test.describe('EventBridge rules UI (#173)', () => {
  test('lists a seeded rule', async ({ page }) => {
    const ts = Date.now()
    const name = `e2e-events-ui-${ts}`
    try {
      aws([
        'events',
        'put-rule',
        '--name',
        name,
        '--event-pattern',
        '{"source":["awsbox.e2e"]}',
        '--state',
        'ENABLED',
      ])

      await page.goto('/events')
      await expect(
        page.getByRole('heading', { level: 1, name: 'Rules' }),
      ).toBeVisible()
      await expect(page.getByTestId('eventbridge-rules-table')).toBeVisible()
      await expect(
        page.getByRole('button', { name, exact: true }),
      ).toBeVisible({ timeout: 15000 })
      await expect(
        page.getByRole('button', { name: 'Create rule' }),
      ).toBeDisabled()
      await expect(
        page.getByRole('button', { name: 'Create rule' }),
      ).toHaveAttribute('title', 'To implement')
      await expect(page.getByRole('button', { name: 'Delete' })).toBeDisabled()
      await expect(page.getByRole('button', { name: 'Delete' })).toHaveAttribute(
        'title',
        'Select a row',
      )
    } finally {
      try {
        aws(['events', 'delete-rule', '--name', name])
      } catch {
        /* ignore */
      }
    }
  })
})

test.describe('EventBridge event buses UI (#173)', () => {
  test('lists default bus and a seeded custom bus', async ({ page }) => {
    const ts = Date.now()
    const name = `e2e-bus-ui-${ts}`
    try {
      aws(['events', 'create-event-bus', '--name', name])

      await page.goto('/events/buses')
      await expect(
        page.getByRole('heading', { level: 1, name: 'Event buses' }),
      ).toBeVisible()
      await expect(page.getByTestId('eventbridge-buses-table')).toBeVisible()
      await expect(
        page.getByRole('button', { name: 'default', exact: true }),
      ).toBeVisible({ timeout: 15000 })
      await expect(
        page.getByRole('button', { name, exact: true }),
      ).toBeVisible({ timeout: 15000 })
      await expect(
        page.getByRole('button', { name: 'Create event bus' }),
      ).toBeDisabled()
      await expect(
        page.getByRole('button', { name: 'Create event bus' }),
      ).toHaveAttribute('title', 'To implement')
    } finally {
      try {
        aws(['events', 'delete-event-bus', '--name', name])
      } catch {
        /* ignore */
      }
    }
  })
})
