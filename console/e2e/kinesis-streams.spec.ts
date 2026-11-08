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

function deleteQuiet(name: string) {
  try {
    aws(['kinesis', 'delete-stream', '--stream-name', name])
  } catch {
    /* ignore */
  }
}

test.describe('Kinesis data streams UI (#178 / #539)', () => {
  test('lists a seeded data stream and opens detail', async ({ page }) => {
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
        page.getByRole('link', { name, exact: true }),
      ).toBeVisible({ timeout: 15000 })
      await expect(
        page.getByRole('link', { name: 'Create data stream' }),
      ).toBeVisible()
      await expect(page.getByTestId('kinesis-delete')).toBeDisabled()
      await expect(page.getByTestId('kinesis-delete')).toHaveAttribute(
        'title',
        'Select a row',
      )

      await page.getByRole('link', { name, exact: true }).click()
      await expect(page).toHaveURL(
        new RegExp(`/kinesis/streams/${name}$`),
      )
      await expect(
        page.getByRole('heading', { level: 1, name }),
      ).toBeVisible()
      await expect(page.getByTestId('kinesis-tab-details')).toBeVisible()
      await expect(page.getByText('Provisioned').first()).toBeVisible()
      await page.getByTestId('kinesis-tab-shards').click()
      await expect(page.getByTestId('kinesis-shards-table')).toBeVisible()
      await expect(page.getByText('shardId-').first()).toBeVisible()
    } finally {
      deleteQuiet(name)
    }
  })

  test('creates a provisioned stream and deletes it from the list', async ({
    page,
  }) => {
    const ts = Date.now()
    const name = `e2e-kinesis-create-${ts}`
    let created = false

    try {
      await page.goto('/kinesis')
      await page.getByRole('link', { name: 'Create data stream' }).click()
      await expect(page).toHaveURL(/\/kinesis\/create$/)
      await expect(
        page.getByRole('heading', { level: 1, name: 'Create data stream' }),
      ).toBeVisible()
      await page.getByTestId('kinesis-create-name').fill(name)
      await page.getByTestId('kinesis-mode-provisioned').check()
      await page.getByTestId('kinesis-create-shard-count').fill('1')
      await page.getByTestId('kinesis-create-submit').click()
      await expect(page).toHaveURL(
        new RegExp(`/kinesis/streams/${name}$`),
        { timeout: 20000 },
      )
      created = true
      await expect(
        page.getByRole('heading', { level: 1, name }),
      ).toBeVisible()
      await expect(page.getByText('Provisioned').first()).toBeVisible({
        timeout: 15000,
      })

      await page.getByRole('link', { name: '← Data streams' }).click()
      await expect(page).toHaveURL(/\/kinesis$/)
      const rowLink = page.getByRole('link', { name, exact: true })
      await expect(rowLink).toBeVisible({ timeout: 15000 })
      await rowLink
        .locator('xpath=ancestor::tr[1]')
        .getByRole('radio')
        .check()
      await page.getByTestId('kinesis-delete').click()
      await page.getByTestId('kinesis-confirm-delete').click()
      await expect(rowLink).toHaveCount(0, { timeout: 20000 })
      created = false
    } finally {
      if (created) deleteQuiet(name)
    }
  })

  test('creates an on-demand stream from the console', async ({ page }) => {
    const ts = Date.now()
    const name = `e2e-kinesis-od-${ts}`
    let created = false

    try {
      await page.goto('/kinesis/create')
      await page.getByTestId('kinesis-create-name').fill(name)
      await page.getByTestId('kinesis-mode-on-demand').check()
      await page.getByTestId('kinesis-create-submit').click()
      await expect(page).toHaveURL(
        new RegExp(`/kinesis/streams/${name}$`),
        { timeout: 20000 },
      )
      created = true
      await expect(page.getByText('On-demand').first()).toBeVisible({
        timeout: 15000,
      })
      await page.getByTestId('kinesis-detail-delete').click()
      await page.getByTestId('kinesis-confirm-delete').click()
      await expect(page).toHaveURL(/\/kinesis$/, { timeout: 20000 })
      created = false
    } finally {
      if (created) deleteQuiet(name)
    }
  })
})
