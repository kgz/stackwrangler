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

function deleteQuiet(queueUrl: string) {
  try {
    aws(['sqs', 'delete-queue', '--queue-url', queueUrl])
  } catch {
    /* ignore */
  }
}

function queueUrlForName(name: string): string {
  return aws([
    'sqs',
    'get-queue-url',
    '--queue-name',
    name,
    '--query',
    'QueueUrl',
    '--output',
    'text',
  ]).trim()
}

test.describe('SQS queues UI (#167 / #548 / #627)', () => {
  test('lists a seeded queue and opens detail', async ({ page }) => {
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
        page.getByRole('link', { name, exact: true }),
      ).toBeVisible({ timeout: 15000 })
      await expect(
        page.getByRole('link', { name: 'Create queue' }),
      ).toBeVisible()
      await expect(page.getByTestId('sqs-delete')).toBeDisabled()
      await expect(page.getByTestId('sqs-delete')).toHaveAttribute(
        'title',
        'Select a row',
      )
      await expect(page.getByTestId('sqs-purge')).toBeDisabled()
      await expect(page.getByTestId('sqs-purge')).toHaveAttribute(
        'title',
        'Select a row',
      )

      await page.getByRole('link', { name, exact: true }).click()
      await expect(page).toHaveURL(new RegExp(`/sqs/queues/${name}$`))
      await expect(
        page.getByRole('heading', { level: 1, name }),
      ).toBeVisible()
      await expect(page.getByTestId('sqs-tab-details')).toBeVisible()
      await expect(page.getByText('Standard').first()).toBeVisible()
      await expect(page.getByText('Messages available')).toBeVisible()
    } finally {
      if (queueUrl) deleteQuiet(queueUrl)
    }
  })

  test('creates a standard queue, sends a message, and deletes it', async ({
    page,
  }) => {
    const ts = Date.now()
    const name = `e2e-sqs-create-${ts}`
    let created = false

    try {
      await page.goto('/sqs')
      await page.getByRole('link', { name: 'Create queue' }).click()
      await expect(page).toHaveURL(/\/sqs\/create$/)
      await expect(
        page.getByRole('heading', { level: 1, name: 'Create queue' }),
      ).toBeVisible()
      await page.getByTestId('sqs-create-name').fill(name)
      await page.getByTestId('sqs-type-standard').check()
      await page.getByTestId('sqs-create-submit').click()
      await expect(page).toHaveURL(new RegExp(`/sqs/queues/${name}$`), {
        timeout: 20000,
      })
      created = true
      await expect(
        page.getByRole('heading', { level: 1, name }),
      ).toBeVisible()
      await expect(page.getByText('Standard').first()).toBeVisible({
        timeout: 15000,
      })

      await page.getByTestId('sqs-send-open').click()
      await expect(page).toHaveURL(new RegExp(`/sqs/queues/${name}/send-receive$`))
      await page.getByTestId('sqs-send-body').fill('{"hello":"sqs"}')
      await page.getByTestId('sqs-send-submit').click()
      await expect(page.getByRole('status')).toContainText('Message sent', {
        timeout: 15000,
      })

      await page.getByRole('link', { name: `← ${name}` }).click()
      await expect(page).toHaveURL(new RegExp(`/sqs/queues/${name}$`))
      await expect(page.getByText('Messages available')).toBeVisible()

      await page.getByRole('link', { name: '← Queues' }).click()
      await expect(page).toHaveURL(/\/sqs$/)
      const rowLink = page.getByRole('link', { name, exact: true })
      await expect(rowLink).toBeVisible({ timeout: 15000 })
      await rowLink
        .locator('xpath=ancestor::tr[1]')
        .getByRole('radio')
        .check()
      await page.getByTestId('sqs-delete').click()
      await page.getByTestId('sqs-confirm-delete').click()
      await expect(rowLink).toHaveCount(0, { timeout: 20000 })
      created = false
    } finally {
      if (created) {
        try {
          deleteQuiet(queueUrlForName(name))
        } catch {
          /* ignore */
        }
      }
    }
  })

  test('creates a FIFO queue with content-based dedup and sends', async ({
    page,
  }) => {
    const ts = Date.now()
    const name = `e2e-sqs-fifo-cbd-${ts}.fifo`
    let created = false

    try {
      await page.goto('/sqs/create')
      await page.getByTestId('sqs-type-fifo').check()
      await page.getByTestId('sqs-create-name').fill(name)
      await page.getByTestId('sqs-content-based').check()
      await page.getByTestId('sqs-create-submit').click()
      await expect(page).toHaveURL(
        new RegExp(`/sqs/queues/${name.replace('.', '\\.')}$`),
        { timeout: 20000 },
      )
      created = true
      await expect(page.getByText('FIFO').first()).toBeVisible({
        timeout: 15000,
      })
      await expect(
        page.getByText('Content-based deduplication'),
      ).toBeVisible()

      await page.getByTestId('sqs-send-open').click()
      await expect(page).toHaveURL(
        new RegExp(`/sqs/queues/${name.replace('.', '\\.')}/send-receive$`),
      )
      await page.getByTestId('sqs-send-body').fill('fifo-body')
      await page.getByTestId('sqs-send-group-id').fill('g1')
      await page.getByTestId('sqs-send-submit').click()
      await expect(page.getByRole('status')).toContainText('Message sent', {
        timeout: 15000,
      })

      await page.getByRole('link', { name: new RegExp(`← ${name}`) }).click()
      await expect(page).toHaveURL(
        new RegExp(`/sqs/queues/${name.replace('.', '\\.')}$`),
      )
      await page.getByTestId('sqs-detail-delete').click()
      await page.getByTestId('sqs-confirm-delete').click()
      await expect(page).toHaveURL(/\/sqs$/, { timeout: 20000 })
      created = false
    } finally {
      if (created) {
        try {
          deleteQuiet(queueUrlForName(name))
        } catch {
          /* ignore */
        }
      }
    }
  })

  test('FIFO without content-based dedup requires MessageDeduplicationId', async ({
    page,
  }) => {
    const ts = Date.now()
    const name = `e2e-sqs-fifo-nodup-${ts}.fifo`
    let created = false

    try {
      await page.goto('/sqs/create')
      await page.getByTestId('sqs-type-fifo').check()
      await page.getByTestId('sqs-create-name').fill(name)
      await expect(page.getByTestId('sqs-content-based')).not.toBeChecked()
      await page.getByTestId('sqs-create-submit').click()
      await expect(page).toHaveURL(
        new RegExp(`/sqs/queues/${name.replace('.', '\\.')}$`),
        { timeout: 20000 },
      )
      created = true
      await expect(page.getByText('FIFO').first()).toBeVisible({
        timeout: 15000,
      })

      await page.getByTestId('sqs-send-open').click()
      await expect(page).toHaveURL(
        new RegExp(`/sqs/queues/${name.replace('.', '\\.')}/send-receive$`),
      )
      await page.getByTestId('sqs-send-submit').click()
      await expect(
        page.getByTestId('sqs-send-card').getByText('Message body is required'),
      ).toBeVisible()

      await page.getByTestId('sqs-send-body').fill('fifo-no-cbd')
      await page.getByTestId('sqs-send-group-id').fill('g1')
      await page.getByTestId('sqs-send-submit').click()
      await expect(
        page
          .getByTestId('sqs-send-card')
          .getByText(
            'Message deduplication ID is required when content-based deduplication is off',
          ),
      ).toBeVisible()

      await page.getByTestId('sqs-send-dedup-id').fill(`dedup-${ts}`)
      await page.getByTestId('sqs-send-submit').click()
      await expect(page.getByRole('status')).toContainText('Message sent', {
        timeout: 15000,
      })

      await page.getByRole('link', { name: new RegExp(`← ${name}`) }).click()
      await expect(page).toHaveURL(
        new RegExp(`/sqs/queues/${name.replace('.', '\\.')}$`),
      )
      await page.getByTestId('sqs-detail-delete').click()
      await page.getByTestId('sqs-confirm-delete').click()
      await expect(page).toHaveURL(/\/sqs$/, { timeout: 20000 })
      created = false
    } finally {
      if (created) {
        try {
          deleteQuiet(queueUrlForName(name))
        } catch {
          /* ignore */
        }
      }
    }
  })

  test('sends, polls, deletes a message, and purges the queue', async ({
    page,
  }) => {
    const ts = Date.now()
    const name = `e2e-sqs-recv-${ts}`
    let created = false

    try {
      await page.goto('/sqs/create')
      await page.getByTestId('sqs-create-name').fill(name)
      await page.getByTestId('sqs-type-standard').check()
      await page.getByTestId('sqs-create-submit').click()
      await expect(page).toHaveURL(new RegExp(`/sqs/queues/${name}$`), {
        timeout: 20000,
      })
      created = true

      await page.getByTestId('sqs-send-open').click()
      await expect(page).toHaveURL(
        new RegExp(`/sqs/queues/${name}/send-receive$`),
      )
      await page.getByTestId('sqs-send-body').fill('{"poll":"me"}')
      await page.getByTestId('sqs-send-submit').click()
      await expect(page.getByRole('status')).toContainText('Message sent', {
        timeout: 15000,
      })

      await page.getByTestId('sqs-poll').click()
      await expect(page.getByTestId('sqs-messages-table')).toContainText(
        'poll',
        { timeout: 15000 },
      )
      const row = page.getByTestId('sqs-messages-table').locator('tbody tr').first()
      await row.getByRole('radio').check()
      await page.getByTestId('sqs-delete-message').click()
      await page.getByTestId('sqs-confirm-delete-message').click()
      await expect(page.getByRole('status')).toContainText('Deleted message', {
        timeout: 15000,
      })

      await page.getByTestId('sqs-send-body').fill('{"purge":"me"}')
      await page.getByTestId('sqs-send-submit').click()
      await expect(page.getByRole('status')).toContainText('Message sent', {
        timeout: 15000,
      })

      await page.getByRole('link', { name: `← ${name}` }).click()
      await expect(page).toHaveURL(new RegExp(`/sqs/queues/${name}$`))
      await page.getByTestId('sqs-detail-purge').click()
      await expect(page.getByTestId('sqs-confirm-purge')).toBeDisabled()
      await page.getByTestId('sqs-purge-confirm-input').fill('purge')
      await page.getByTestId('sqs-confirm-purge').click()
      await expect(page.getByRole('status')).toContainText('Purged queue', {
        timeout: 15000,
      })

      await page.getByTestId('sqs-detail-delete').click()
      await page.getByTestId('sqs-confirm-delete').click()
      await expect(page).toHaveURL(/\/sqs$/, { timeout: 20000 })
      created = false
    } finally {
      if (created) {
        try {
          deleteQuiet(queueUrlForName(name))
        } catch {
          /* ignore */
        }
      }
    }
  })
})
