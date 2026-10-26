import { expect, test } from '@playwright/test'

test.describe('Lambda create + code editor', () => {
  test('create function, edit code, deploy', async ({ page }) => {
    test.setTimeout(180_000)
    const name = `awsbox-ui-create-${Date.now()}`

    await page.goto('/lambda')
    await expect(
      page.getByRole('heading', { name: 'Functions', exact: true }),
    ).toBeVisible()

    await page.getByRole('link', { name: 'Create function' }).click()
    await expect(
      page.getByRole('heading', { name: 'Create function', exact: true }),
    ).toBeVisible()

    await page.getByTestId('lambda-create-name').fill(name)
    await page.getByTestId('lambda-create-submit').click()

    await expect(
      page.getByRole('heading', { name, exact: true }),
    ).toBeVisible({ timeout: 90_000 })

    await page.getByTestId('lambda-tab-code').click()
    const editor = page.locator('.monaco-editor').first()
    await expect(editor).toBeVisible({ timeout: 60_000 })

    await page.getByTestId('lambda-deploy-code').click()
    await expect(
      page.getByRole('status').filter({ hasText: `Deployed` }),
    ).toBeVisible({ timeout: 90_000 })
  })
})
