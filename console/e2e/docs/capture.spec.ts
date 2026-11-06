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
})

