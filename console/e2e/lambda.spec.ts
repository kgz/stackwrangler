import { expect, test } from '@playwright/test'

test.describe('Lambda console', () => {
  test('create hello function and invoke', async ({ page }) => {
    test.setTimeout(120_000)
    await page.goto('/lambda')
    await expect(
      page.getByRole('heading', { name: 'Functions', exact: true }),
    ).toBeVisible()

    await page.getByRole('button', { name: 'Create hello function' }).click()
    await expect(page.getByRole('status').filter({ hasText: 'Created function' })).toBeVisible({
      timeout: 60_000,
    })

    await page.getByRole('button', { name: 'Invoke' }).click()
    await expect(page.getByRole('heading', { name: 'Invoke result' })).toBeVisible({
      timeout: 90_000,
    })
    await expect(page.getByText(/"ok"\s*:\s*true/)).toBeVisible()
  })
})
