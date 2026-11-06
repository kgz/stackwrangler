import { expect, test } from '@playwright/test'

test.describe('RDS create database', () => {
  test('create postgres instance from console form', async ({ page }) => {
    const id = `awsbox-ui-rds-${Date.now()}`
    await page.goto('/rds')
    await page.getByRole('link', { name: 'Create database' }).click()
    await expect(
      page.getByRole('heading', { name: 'Create database', exact: true }),
    ).toBeVisible()

    await page.getByTestId('rds-create-id').fill(id)
    await page.getByTestId('rds-create-password').fill('Stackwrangler1!')
    await page.getByTestId('rds-create-password-confirm').fill('Stackwrangler1!')
    await page.getByTestId('rds-create-submit').click()

    await expect(page).toHaveURL(new RegExp(`/rds/databases/${id}$`))
    await expect(page.getByRole('heading', { name: id })).toBeVisible({
      timeout: 120_000,
    })
  })
})
