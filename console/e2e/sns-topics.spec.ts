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

function deleteQuiet(arn: string) {
  try {
    aws(['sns', 'delete-topic', '--topic-arn', arn])
  } catch {
    /* ignore */
  }
}

function topicArnByName(name: string): string {
  return aws([
    'sns',
    'list-topics',
    '--query',
    `Topics[?ends_with(TopicArn, \`:${name}\`)].TopicArn | [0]`,
    '--output',
    'text',
  ]).trim()
}

test.describe('SNS topics UI (#172 / #546 / #622)', () => {
  test('lists a seeded topic and opens detail', async ({ page }) => {
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
        page.getByRole('link', { name, exact: true }),
      ).toBeVisible({ timeout: 15000 })
      await expect(
        page.getByRole('link', { name: 'Create topic' }),
      ).toBeVisible()
      await expect(page.getByTestId('sns-delete')).toBeDisabled()
      await expect(page.getByTestId('sns-delete')).toHaveAttribute(
        'title',
        'Select a row',
      )

      await page.getByRole('link', { name, exact: true }).click()
      await expect(page).toHaveURL(
        new RegExp(`/sns/topics/${name}$`),
      )
      await expect(
        page.getByRole('heading', { level: 1, name }),
      ).toBeVisible()
      await expect(page.getByTestId('sns-tab-details')).toBeVisible()
      await expect(page.getByText('Standard').first()).toBeVisible()
      await page.getByTestId('sns-tab-subscriptions').click()
      await expect(page.getByTestId('sns-subscriptions-table')).toBeVisible()
      await expect(page.getByTestId('sns-create-subscription')).toBeEnabled()
      await expect(page.getByTestId('sns-detail-delete')).toBeEnabled()
    } finally {
      if (arn) deleteQuiet(arn)
    }
  })

  test('creates a Standard topic from the console', async ({ page }) => {
    const ts = Date.now()
    const name = `e2e-sns-create-${ts}`
    let arn = ''
    try {
      await page.goto('/sns')
      await page.getByRole('link', { name: 'Create topic' }).click()
      await expect(page).toHaveURL(/\/sns\/create$/)
      await expect(
        page.getByRole('heading', { level: 1, name: 'Create topic' }),
      ).toBeVisible()
      await page.getByTestId('sns-create-name').fill(name)
      await page.getByTestId('sns-type-standard').check()
      await page.getByTestId('sns-create-submit').click()
      await expect(page).toHaveURL(
        new RegExp(`/sns/topics/${name}$`),
        { timeout: 20000 },
      )
      arn = topicArnByName(name)
      await expect(
        page.getByRole('heading', { level: 1, name }),
      ).toBeVisible()
      await expect(page.getByText('Standard').first()).toBeVisible({
        timeout: 15000,
      })

      await page.getByTestId('sns-tab-publish').click()
      await page.getByTestId('sns-publish-message').fill(`hello-${ts}`)
      await page.getByTestId('sns-publish-submit').click()
      await expect(page.getByTestId('sns-publish-result')).toBeVisible({
        timeout: 15000,
      })
    } finally {
      if (!arn) {
        try {
          arn = topicArnByName(name)
        } catch {
          arn = ''
        }
      }
      if (arn && arn !== 'None') deleteQuiet(arn)
    }
  })

  test('creates a FIFO topic from the console', async ({ page }) => {
    const ts = Date.now()
    const name = `e2e-sns-fifo-${ts}.fifo`
    let arn = ''
    try {
      await page.goto('/sns/create')
      await page.getByTestId('sns-create-name').fill(name)
      await page.getByTestId('sns-type-fifo').check()
      await page.getByTestId('sns-create-submit').click()
      await expect(page).toHaveURL(
        new RegExp(`/sns/topics/${name.replace('.', '\\.')}$`),
        { timeout: 20000 },
      )
      arn = topicArnByName(name)
      await expect(
        page.getByRole('heading', { level: 1, name }),
      ).toBeVisible()
      await expect(page.getByText('FIFO').first()).toBeVisible({
        timeout: 15000,
      })
    } finally {
      if (!arn) {
        try {
          arn = topicArnByName(name)
        } catch {
          arn = ''
        }
      }
      if (arn && arn !== 'None') deleteQuiet(arn)
    }
  })

  test('creates an SQS subscription and deletes the topic', async ({
    page,
  }) => {
    const ts = Date.now()
    const topicName = `e2e-sns-sub-${ts}`
    const queueName = `e2e-sns-sub-q-${ts}`
    let topicArn = ''
    let queueUrl = ''
    let queueArn = ''
    try {
      topicArn = aws([
        'sns',
        'create-topic',
        '--name',
        topicName,
        '--query',
        'TopicArn',
        '--output',
        'text',
      ]).trim()
      queueUrl = aws([
        'sqs',
        'create-queue',
        '--queue-name',
        queueName,
        '--query',
        'QueueUrl',
        '--output',
        'text',
      ]).trim()
      queueArn = aws([
        'sqs',
        'get-queue-attributes',
        '--queue-url',
        queueUrl,
        '--attribute-names',
        'QueueArn',
        '--query',
        'Attributes.QueueArn',
        '--output',
        'text',
      ]).trim()

      await page.goto(`/sns/topics/${topicName}`)
      await expect(
        page.getByRole('heading', { level: 1, name: topicName }),
      ).toBeVisible({ timeout: 15000 })

      await page.getByTestId('sns-create-subscription').click()
      await expect(page.getByTestId('sns-subscribe-modal')).toBeVisible()
      await page.getByTestId('sns-sub-protocol').selectOption('sqs')
      await page.getByTestId('sns-sub-endpoint').fill(queueArn)
      await page.getByTestId('sns-sub-submit').click()

      await expect(page.getByTestId('sns-subscriptions-table')).toBeVisible({
        timeout: 15000,
      })
      await expect(page.getByText(queueArn)).toBeVisible({ timeout: 15000 })
      await expect(page.getByText('sqs').first()).toBeVisible()

      await page.getByTestId('sns-detail-delete').click()
      await page.getByTestId('sns-confirm-delete').click()
      await expect(page).toHaveURL(/\/sns$/, { timeout: 20000 })
      await expect(
        page.getByRole('link', { name: topicName, exact: true }),
      ).toHaveCount(0, { timeout: 20000 })
      topicArn = ''
    } finally {
      if (topicArn && topicArn !== 'None') deleteQuiet(topicArn)
      if (queueUrl) {
        try {
          aws(['sqs', 'delete-queue', '--queue-url', queueUrl])
        } catch {
          /* ignore */
        }
      }
    }
  })

  test('deletes a selected topic from the list', async ({ page }) => {
    const ts = Date.now()
    const name = `e2e-sns-del-list-${ts}`
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
      const rowLink = page.getByRole('link', { name, exact: true })
      await expect(rowLink).toBeVisible({ timeout: 15000 })
      await rowLink
        .locator('xpath=ancestor::tr[1]')
        .getByRole('radio')
        .check()
      await page.getByTestId('sns-delete').click()
      await page.getByTestId('sns-confirm-delete').click()
      await expect(rowLink).toHaveCount(0, { timeout: 20000 })
      arn = ''
    } finally {
      if (arn && arn !== 'None') deleteQuiet(arn)
    }
  })
})
