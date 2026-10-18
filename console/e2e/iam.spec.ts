import { expect, test } from '@playwright/test'

test.describe('IAM console + AccessDenied lab', () => {
  test('lists users and AccessDenied lab shows denial', async ({ page }) => {
    await page.goto('/iam')
    await expect(page.getByRole('heading', { name: 'Users', exact: true })).toBeVisible()
    await expect(page.getByRole('link', { name: 'IAM' })).toBeVisible()

    await page.getByRole('button', { name: 'Run AccessDenied lab' }).click()
    await expect(page.getByText(/AccessDenied/)).toBeVisible({ timeout: 45_000 })
  })
})
