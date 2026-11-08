import { expect, test } from '@playwright/test'

test.describe('CloudWatch Logs create + detail', () => {
  test('create log group then open streams/events', async ({ page }) => {
    test.setTimeout(180_000)
    const name = `/stackwrangler/ui-logs-${Date.now()}`

    await page.goto('/logs')
    await expect(
      page.getByRole('heading', { name: 'Log groups', exact: true }),
    ).toBeVisible()
    await page.getByRole('link', { name: 'Create log group' }).click()
    await expect(
      page.getByRole('heading', { name: 'Create log group', exact: true }),
    ).toBeVisible()

    await page.getByTestId('logs-create-name').fill(name)
    await page.getByTestId('logs-create-retention').selectOption('14')
    await page.getByTestId('logs-create-submit').click()

    await expect(page).toHaveURL(/\/logs\/log-groups\//)
    await expect(page.getByText(name).first()).toBeVisible({ timeout: 60_000 })
    await expect(
      page.getByRole('button', { name: 'Log streams', exact: true }),
    ).toBeVisible()
    await expect(
      page.getByRole('heading', { name: 'Log streams', exact: true }),
    ).toBeVisible()

    await page.getByRole('button', { name: 'Search log group', exact: true }).click()
    await expect(
      page.getByRole('heading', { name: 'Search log group', exact: true }),
    ).toBeVisible()
    await page.getByTestId('logs-filter-pattern').fill('REPORT')
    await page.getByTestId('logs-search-events').click()
    await expect(page.getByTestId('log-events-table')).toBeVisible()
  })
})
