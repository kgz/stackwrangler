import { expect, test } from '@playwright/test'

function env(name: string): string {
  return process.env[name] ?? ''
}

test('shows VPC and NLB labels on list and detail', async ({ page }) => {
  const vpcId = env('AWSBOX_SMOKE_VPC_ID')
  const nlbName = env('AWSBOX_SMOKE_NLB_NAME')
  const nlbArn = env('AWSBOX_SMOKE_NLB_ARN')
  const vpcLabel = env('AWSBOX_SMOKE_VPC_LABEL')
  const nlbLabel = env('AWSBOX_SMOKE_NLB_LABEL')
  const vpcNote = env('AWSBOX_SMOKE_VPC_NOTE')
  const nlbNote = env('AWSBOX_SMOKE_NLB_NOTE')
  const vpcLink = env('AWSBOX_SMOKE_VPC_LINK')
  const nlbLink = env('AWSBOX_SMOKE_NLB_LINK')
  test.skip(
    vpcId === '' || nlbName === '' || nlbArn === '',
    'run via ./smokes/account/labels-smoke.sh',
  )
  test.setTimeout(120_000)

  await page.goto('/ec2/vpcs')
  await expect(page.getByRole('link', { name: vpcLabel, exact: true })).toBeVisible()
  await page.getByRole('link', { name: vpcId, exact: true }).click()
  await expect(page.getByRole('heading', { name: vpcId, exact: true })).toBeVisible()
  await expect(page.getByText(vpcNote)).toBeVisible()
  await expect(page.getByRole('link', { name: vpcLabel, exact: true })).toHaveAttribute(
    'href',
    vpcLink,
  )

  await page.goto('/ec2/load-balancers')
  await expect(page.getByRole('link', { name: nlbLabel, exact: true })).toBeVisible()
  await page.getByRole('link', { name: nlbName, exact: true }).click()
  await expect(page.getByRole('heading', { name: nlbName, exact: true })).toBeVisible()
  await expect(page.getByText(nlbArn)).toBeVisible()
  await expect(page.getByText(nlbNote)).toBeVisible()
  await expect(page.getByRole('link', { name: nlbLabel, exact: true })).toHaveAttribute(
    'href',
    nlbLink,
  )
})

test('omits labels when the labels file is gone', async ({ page }) => {
  const vpcId = env('AWSBOX_SMOKE_VPC_ID')
  const vpcLabel = env('AWSBOX_SMOKE_VPC_LABEL')
  const nlbLabel = env('AWSBOX_SMOKE_NLB_LABEL')
  test.skip(
    env('AWSBOX_SMOKE_LABELS_ABSENT') !== '1' || vpcId === '' || vpcLabel === '',
    'run via ./smokes/account/labels-smoke.sh',
  )
  test.setTimeout(120_000)

  await page.goto('/ec2/vpcs')
  await expect(page.getByRole('link', { name: vpcId, exact: true })).toBeVisible()
  await expect(page.getByText(vpcLabel)).toHaveCount(0)
  await page.goto('/ec2/load-balancers')
  await expect(page.getByText(nlbLabel)).toHaveCount(0)
})
