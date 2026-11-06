import { expect, test, type Page } from '@playwright/test'

const lists: Array<{
  path: string
  heading: string | RegExp
  columns: string[]
  disabled: string[]
}> = [
  {
    path: '/iam',
    heading: 'Users',
    columns: ['User name', 'Groups', 'Last activity', 'MFA'],
    disabled: ['Delete', 'Create user'],
  },
  {
    path: '/lambda',
    heading: 'Functions',
    columns: ['Function name', 'Package type', 'Runtime', 'Last modified'],
    disabled: ['Actions ▾', 'Create function'],
  },
  {
    path: '/logs',
    heading: 'Log groups',
    columns: ['Log group', 'Retention', 'Stored bytes', 'Metric filters'],
    disabled: ['Actions ▾', 'Create log group'],
  },
  {
    path: '/stepfunctions',
    heading: 'State machines',
    columns: ['Name', 'Type', 'Creation date'],
    disabled: ['Actions ▾', 'Create state machine'],
  },
  {
    path: '/secretsmanager',
    heading: 'Secrets',
    columns: ['Name', 'Description', 'Last retrieved', 'Created on'],
    disabled: ['Delete', 'Rotate', 'Store a new secret'],
  },
  {
    path: '/apigateway',
    heading: 'APIs',
    columns: ['Name', 'API ID', 'Created date', 'Endpoint'],
    disabled: ['Delete', 'Create'],
  },
  {
    path: '/cloudformation',
    heading: /^Stacks/,
    columns: ['Stack name', 'Status', 'Created time', 'Description'],
    disabled: ['Update ▾', 'Stack actions ▾', 'Create stack ▾'],
  },
  {
    path: '/transfer',
    heading: 'Servers',
    columns: ['Server ID', 'Protocol', 'Endpoint type', 'State', 'Users'],
    disabled: [],
  },
  {
    path: '/rds',
    heading: 'Databases',
    columns: ['DB identifier', 'Role', 'Engine', 'Region & AZ', 'Size', 'VPC'],
    disabled: ['Actions ▾', 'Create database'],
  },
  {
    path: '/ecs',
    heading: 'Clusters',
    columns: ['Cluster name', 'Registered container instances', 'Tasks running'],
    disabled: ['Delete Cluster', 'Create Cluster'],
  },
  {
    path: '/ec2',
    heading: 'Instances',
    columns: ['Name', 'Instance ID', 'Instance state', 'Private IPv4'],
    disabled: ['Instance state ▾', 'Actions ▾', 'Launch instance'],
  },
  {
    path: '/ec2/vpcs',
    heading: 'Your VPCs',
    columns: ['VPC ID', 'IPv4 CIDR', 'DHCP option set', 'Owner ID'],
    disabled: ['Actions ▾', 'Create VPC'],
  },
  {
    path: '/ec2/load-balancers',
    heading: 'Load balancers',
    columns: ['Name', 'DNS name', 'Availability Zones', 'Date created'],
    disabled: ['Actions ▾', 'Create load balancer'],
  },
]

async function expectDisabledControlsExplained(page: Page) {
  const titles = await page
    .locator('.aws-main button[disabled]:not(.aws-pager button)')
    .evaluateAll((els) => els.map((el) => el.getAttribute('title')))
  for (const t of titles) {
    expect([
      'To implement',
      'Select a row',
      'Create a Lambda function first',
    ]).toContain(t)
  }
}

test.describe('Built service list chrome (#349)', () => {
  for (const spec of lists) {
    test(`${spec.path} matches mock chrome`, async ({ page }) => {
      await page.goto(spec.path)
      await expect(
        page.getByRole('heading', { level: 1, name: spec.heading }),
      ).toBeVisible()
      await expect(page.locator('.aws-card .aws-table').first()).toBeVisible()
      for (const col of spec.columns) {
        await expect(
          page.locator('.aws-table th').filter({ hasText: col }).first(),
        ).toBeVisible()
      }
      for (const label of spec.disabled) {
        const btn = page
          .locator('.aws-main button.btn')
          .filter({ hasText: new RegExp(`^${label}$`) })
          .first()
        await expect(btn).toBeDisabled()
        await expect(btn).toHaveAttribute('title', 'To implement')
      }
      await expectDisabledControlsExplained(page)
    })
  }

  test('sidebar highlights the active service page', async ({ page }) => {
    await page.goto('/ec2/vpcs')
    await expect(
      page.locator('.aws-sidebar a[aria-current="page"]'),
    ).toContainText('VPCs')
  })
})
