import { mkdirSync } from 'node:fs'
import path from 'node:path'
import { expect, test } from '@playwright/test'

const outDir =
  process.env.DOCS_CAPTURE_OUT ||
  path.resolve(__dirname, '../../../docs/assets/console')

mkdirSync(outDir, { recursive: true })

async function shot(
  page: import('@playwright/test').Page,
  name: string,
  url: string,
  ready: () => Promise<void>,
): Promise<void> {
  await page.goto(url)
  await ready()
  await page.screenshot({
    path: path.join(outDir, name),
    fullPage: false,
  })
}

test.describe('docs-capture', () => {
  test('home S3 buckets', async ({ page }) => {
    await shot(page, 'home-s3-buckets.png', '/', async () => {
      await expect(
        page.getByRole('heading', { name: 'Buckets', exact: true }),
      ).toBeVisible({ timeout: 30_000 })
    })
  })

  test('lambda functions list', async ({ page }) => {
    await shot(page, 'lambda-functions.png', '/lambda', async () => {
      await expect(
        page.getByRole('heading', { name: /function/i }).first(),
      ).toBeVisible({ timeout: 30_000 })
    })
  })

  test('cloudformation stacks', async ({ page }) => {
    await shot(page, 'cloudformation-stacks.png', '/cloudformation', async () => {
      await expect(
        page.getByRole('heading', { name: /stack/i }).first(),
      ).toBeVisible({ timeout: 30_000 })
    })
  })

  test('cloudformation stacksets', async ({ page }) => {
    await shot(
      page,
      'cloudformation-stacksets.png',
      '/cloudformation/stacksets',
      async () => {
        await expect(
          page.getByRole('heading', { name: 'StackSets' }),
        ).toBeVisible({ timeout: 30_000 })
      },
    )
  })

  test('ecs clusters', async ({ page }) => {
    await shot(page, 'ecs-clusters.png', '/ecs', async () => {
      await expect(
        page.getByRole('heading', { name: /cluster/i }).first(),
      ).toBeVisible({ timeout: 30_000 })
    })
  })

  test('ec2 instances', async ({ page }) => {
    await shot(page, 'ec2-instances.png', '/ec2', async () => {
      await expect(
        page.getByRole('heading', { name: /instance/i }).first(),
      ).toBeVisible({ timeout: 30_000 })
    })
  })

  test('step functions state machines', async ({ page }) => {
    await shot(page, 'sfn-state-machines.png', '/stepfunctions', async () => {
      await expect(
        page.getByRole('heading', { level: 1, name: 'State machines' }),
      ).toBeVisible({ timeout: 30_000 })
    })
  })

  test('secrets manager secrets list', async ({ page }) => {
    await shot(page, 'secrets-list.png', '/secretsmanager', async () => {
      await expect(
        page.getByRole('heading', { level: 1, name: 'Secrets' }),
      ).toBeVisible({ timeout: 30_000 })
    })
  })

  test('kms customer managed keys', async ({ page }) => {
    await shot(page, 'kms-keys.png', '/kms', async () => {
      await expect(
        page.getByRole('heading', { level: 1, name: 'Customer managed keys' }),
      ).toBeVisible({ timeout: 30_000 })
      await expect(
        page.getByText('Loading customer managed keys…'),
      ).toHaveCount(0, { timeout: 30_000 })
    })
  })

  test('eventbridge rules list', async ({ page }) => {
    await shot(page, 'eventbridge-rules.png', '/events', async () => {
      await expect(
        page.getByRole('heading', { level: 1, name: 'Rules' }),
      ).toBeVisible({ timeout: 30_000 })
      await expect(page.getByText('Loading rules…')).toHaveCount(0, {
        timeout: 30_000,
      })
    })
  })

  test('specialty buckets empty chrome', async ({ page }) => {
    await shot(
      page,
      'empty-specialty-buckets.png',
      '/directory-buckets',
      async () => {
        await expect(page.locator('main').first()).toBeVisible({
          timeout: 30_000,
        })
      },
    )
  })

  test('rds databases list', async ({ page }) => {
    await shot(page, 'rds-databases.png', '/rds', async () => {
      await expect(
        page.getByRole('heading', { level: 1, name: 'Databases' }),
      ).toBeVisible({ timeout: 30_000 })
    })
  })

  test('apigateway rest apis list', async ({ page }) => {
    await shot(
      page,
      'apigateway-rest-apis.png',
      '/apigateway/rest-apis',
      async () => {
        await expect(
          page.getByRole('heading', { level: 1, name: 'APIs' }),
        ).toBeVisible({ timeout: 30_000 })
        await expect(page.getByText('Loading REST APIs…')).toHaveCount(0, {
          timeout: 30_000,
        })
      },
    )
  })

  test('sns topics list', async ({ page }) => {
    await shot(page, 'sns-topics.png', '/sns', async () => {
      await expect(
        page.getByRole('heading', { level: 1, name: 'Topics' }),
      ).toBeVisible({ timeout: 30_000 })
    })
  })

  test('sqs queues list', async ({ page }) => {
    await shot(page, 'sqs-queues.png', '/sqs', async () => {
      await expect(
        page.getByRole('heading', { level: 1, name: 'Queues' }),
      ).toBeVisible({ timeout: 30_000 })
    })
  })
})

