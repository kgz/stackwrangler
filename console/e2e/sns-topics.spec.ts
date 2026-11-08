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

test.describe('SNS topics UI (#172 / #546)', () => {
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
      await expect(page.getByRole('button', { name: 'Delete' })).toBeDisabled()
      await expect(page.getByRole('button', { name: 'Delete' })).toHaveAttribute(
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
})
