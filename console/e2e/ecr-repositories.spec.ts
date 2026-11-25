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

function deleteQuiet(name: string) {
  try {
    aws(['ecr', 'delete-repository', '--repository-name', name, '--force'])
  } catch {
    /* ignore */
  }
}

test.describe('ECR private repositories UI (#217)', () => {
  test('lists a seeded repository and opens detail', async ({ page }) => {
    const ts = Date.now()
    const name = `e2e-ecr-ui-${ts}`
    try {
      aws(['ecr', 'create-repository', '--repository-name', name])

      await page.goto('/ecr')
      await expect(
        page.getByRole('heading', { level: 1, name: 'Private repositories' }),
      ).toBeVisible()
      await expect(page.getByTestId('ecr-repositories-table')).toBeVisible()
      await expect(
        page.getByRole('link', { name, exact: true }),
      ).toBeVisible({ timeout: 15000 })
      await expect(
        page.getByRole('button', { name: 'Create repository' }),
      ).toBeDisabled()
      await expect(
        page.getByRole('button', { name: 'Create repository' }),
      ).toHaveAttribute('title', 'To implement')
      await expect(page.getByTestId('ecr-delete')).toBeDisabled()
      await expect(page.getByTestId('ecr-delete')).toHaveAttribute(
        'title',
        'Select a row',
      )

      await page.getByRole('link', { name, exact: true }).click()
      await expect(page).toHaveURL(
        new RegExp(`/ecr/repositories/${name}$`),
      )
      await expect(
        page.getByRole('heading', { level: 1, name }),
      ).toBeVisible()
      await expect(page.getByTestId('ecr-tab-details')).toBeVisible()
      await expect(page.getByText('Repository URI').first()).toBeVisible()
      await expect(page.getByTestId('ecr-back-list')).toBeVisible()
      await expect(page.getByTestId('ecr-detail-delete')).toBeDisabled()
      await expect(page.getByTestId('ecr-detail-delete')).toHaveAttribute(
        'title',
        'To implement',
      )
    } finally {
      deleteQuiet(name)
    }
  })

  test('empty state when no repositories match', async ({ page }) => {
    const missing = `e2e-ecr-empty-${Date.now()}-missing`
    await page.goto('/ecr')
    await expect(
      page.getByRole('heading', { level: 1, name: 'Private repositories' }),
    ).toBeVisible()
    await page
      .getByPlaceholder('Filter repositories by name or URI')
      .fill(missing)
    await expect(page.getByText('No private repositories')).toBeVisible({
      timeout: 15000,
    })
    await expect(
      page.getByText(
        'You do not have any private repositories in this region.',
      ),
    ).toBeVisible()
    await expect(
      page.getByRole('button', { name: 'Create repository' }),
    ).toBeDisabled()
  })
})
