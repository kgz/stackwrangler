import { expect, test, type Page } from '@playwright/test'
import { execFileSync } from 'node:child_process'
import { randomBytes } from 'node:crypto'

const EP = process.env.AWSBOX_IAM_ENDPOINT || 'http://127.0.0.1:4566'
const KEY = process.env.AWSBOX_ACCESS_KEY || 'awsbox'
const SECRET = process.env.AWSBOX_SECRET_KEY || 'awsboxawsbox'
const REGION = 'us-east-1'

function aws(args: string[]): string {
  return execFileSync('aws', ['--endpoint-url', EP, '--region', REGION, ...args], {
    encoding: 'utf8',
    env: {
      ...process.env,
      AWS_ACCESS_KEY_ID: KEY,
      AWS_SECRET_ACCESS_KEY: SECRET,
      AWS_DEFAULT_REGION: REGION,
    },
  }).trim()
}

function tryAws(args: string[]): void {
  try {
    aws(args)
  } catch {
    // already gone
  }
}

async function expectDisabledControlsExplained(page: Page) {
  const titles = await page
    .locator('.aws-main button[disabled]:not(.aws-pager button)')
    .evaluateAll((els) => els.map((el) => el.getAttribute('title')))
  for (const t of titles) {
    expect(['To implement', 'Select a row']).toContain(t)
  }
}

const ts = Date.now()
const ids: {
  vpc?: string
  subnet?: string
  sg?: string
  nlbArn?: string
  server?: string
  cluster?: string
  service?: string
  db?: string
} = {}
const vpcName = `e2e-vpc-${ts}`
const subnetName = `e2e-subnet-${ts}`
const nlbName = `e2e-nlb-${ts}`
const clusterName = `e2e-ecs-${ts}`
const serviceName = `e2e-svc-${ts}`
const dbId = `e2e-db-${ts}`
const cidr = '10.231.0.0/16'
const subnetCidr = '10.231.1.0/24'

test.describe('Built service detail pages (#349)', () => {
  test.describe.configure({ mode: 'serial' })
  test.setTimeout(180_000)

  test.beforeAll(() => {
    ids.vpc = aws([
      'ec2',
      'create-vpc',
      '--cidr-block',
      cidr,
      '--tag-specifications',
      `ResourceType=vpc,Tags=[{Key=Name,Value=${vpcName}}]`,
      '--query',
      'Vpc.VpcId',
      '--output',
      'text',
    ])
    ids.subnet = aws([
      'ec2',
      'create-subnet',
      '--vpc-id',
      ids.vpc,
      '--cidr-block',
      subnetCidr,
      '--tag-specifications',
      `ResourceType=subnet,Tags=[{Key=Name,Value=${subnetName}}]`,
      '--query',
      'Subnet.SubnetId',
      '--output',
      'text',
    ])
    ids.sg = aws([
      'ec2',
      'create-security-group',
      '--group-name',
      `e2e-sg-${ts}`,
      '--description',
      'e2e detail pages',
      '--vpc-id',
      ids.vpc,
      '--query',
      'GroupId',
      '--output',
      'text',
    ])
    ids.nlbArn = aws([
      'elbv2',
      'create-load-balancer',
      '--name',
      nlbName,
      '--type',
      'network',
      '--scheme',
      'internal',
      '--subnets',
      ids.subnet,
      '--query',
      'LoadBalancers[0].LoadBalancerArn',
      '--output',
      'text',
    ])

    ids.server = aws([
      'transfer',
      'create-server',
      '--protocols',
      'SFTP',
      '--identity-provider-type',
      'SERVICE_MANAGED',
      '--query',
      'ServerId',
      '--output',
      'text',
    ])
    aws([
      'transfer',
      'create-user',
      '--server-id',
      ids.server,
      '--user-name',
      'e2e-sftp-user',
      '--role',
      'arn:aws:iam::000000000000:role/TransferAccess',
      '--home-directory',
      '/e2e-home',
    ])

    ids.cluster = clusterName
    aws(['ecs', 'create-cluster', '--cluster-name', clusterName])
    aws([
      'ecs',
      'register-task-definition',
      '--family',
      serviceName,
      '--requires-compatibilities',
      'FARGATE',
      '--network-mode',
      'awsvpc',
      '--cpu',
      '256',
      '--memory',
      '512',
      '--container-definitions',
      JSON.stringify([{ name: 'web', image: 'nginx:alpine', essential: true }]),
    ])
    aws([
      'ecs',
      'create-service',
      '--cluster',
      clusterName,
      '--service-name',
      serviceName,
      '--task-definition',
      serviceName,
      '--desired-count',
      '0',
      '--launch-type',
      'FARGATE',
      '--network-configuration',
      `awsvpcConfiguration={subnets=[${ids.subnet}],securityGroups=[${ids.sg}],assignPublicIp=DISABLED}`,
    ])
    ids.service = serviceName

    aws([
      'rds',
      'create-db-instance',
      '--db-instance-identifier',
      dbId,
      '--db-instance-class',
      'db.t3.micro',
      '--engine',
      'postgres',
      '--engine-version',
      '16.3',
      '--master-username',
      'stackwrangler',
      '--master-user-password',
      randomBytes(12).toString('hex'),
      '--allocated-storage',
      '20',
      '--db-name',
      'stackwrangler',
    ])
    ids.db = dbId
  })

  test.afterAll(() => {
    if (ids.db) {
      tryAws([
        'rds',
        'delete-db-instance',
        '--db-instance-identifier',
        ids.db,
        '--skip-final-snapshot',
      ])
    }
    if (ids.cluster && ids.service) {
      tryAws([
        'ecs',
        'delete-service',
        '--cluster',
        ids.cluster,
        '--service',
        ids.service,
        '--force',
      ])
    }
    if (ids.cluster) {
      for (let i = 0; i < 10; i++) {
        try {
          aws(['ecs', 'delete-cluster', '--cluster', ids.cluster])
          break
        } catch {
          execFileSync('sleep', ['1'])
        }
      }
    }
    if (ids.server) {
      tryAws(['transfer', 'delete-server', '--server-id', ids.server])
    }
    if (ids.nlbArn) {
      tryAws(['elbv2', 'delete-load-balancer', '--load-balancer-arn', ids.nlbArn])
    }
    if (ids.subnet) {
      for (let i = 0; i < 20; i++) {
        try {
          aws(['ec2', 'delete-subnet', '--subnet-id', ids.subnet])
          break
        } catch {
          execFileSync('sleep', ['1'])
        }
      }
    }
    if (ids.sg) {
      tryAws(['ec2', 'delete-security-group', '--group-id', ids.sg])
    }
    if (ids.vpc) {
      tryAws(['ec2', 'delete-vpc', '--vpc-id', ids.vpc])
    }
  })

  test('Transfer server detail: overview, users, data plane', async ({ page }) => {
    const id = ids.server ?? ''
    await page.goto(`/transfer/servers/${encodeURIComponent(id)}`)
    await expect(
      page.getByRole('heading', { level: 1, name: id }),
    ).toBeVisible()
    await expect(page.locator('.aws-subtitle-row')).toContainText('SFTP')
    for (const section of ['Overview', 'Users', 'Data plane']) {
      await expect(
        page.getByRole('heading', { level: 2, name: section }),
      ).toBeVisible()
    }
    const overview = page.locator('.aws-kv').first()
    await expect(overview).toContainText('Protocols')
    await expect(overview).toContainText('SFTP')
    await expect(overview).toContainText('Service managed')
    await expect(overview).toContainText('arn:aws:transfer:')
    const users = page.getByTestId('transfer-users-table')
    for (const col of ['User name', 'Home directory', 'Role']) {
      await expect(users.locator('th').filter({ hasText: col })).toBeVisible()
    }
    // LocalEmu list-users can be empty even when user-count is 1.
    await expect(users).toContainText(/e2e-sftp-user|No users/)
    const dataPlane = page.locator('.aws-kv').last()
    await expect(dataPlane).toContainText('Port')
    await expect(dataPlane).toContainText('sftp -P')
    await expectDisabledControlsExplained(page)
  })

  test('Transfer list: create in UI, open detail, delete', async ({ page }) => {
    await page.goto('/transfer')
    await page.getByRole('button', { name: 'Create server' }).click()
    const toast = page.getByRole('status').filter({ hasText: 'Created server' })
    await expect(toast).toBeVisible({ timeout: 30_000 })
    const created = (await toast.innerText()).replace('Created server ', '').trim()
    await page.getByRole('link', { name: created, exact: true }).click()
    await expect(page).toHaveURL(/\/transfer\/servers\//)
    await expect(
      page.getByRole('heading', { level: 1, name: created }),
    ).toBeVisible()
    await expect(
      page.getByRole('heading', { level: 2, name: 'Data plane' }),
    ).toBeVisible()
    await page.getByRole('link', { name: 'Back to servers' }).click()
    await page.getByLabel(`Select ${created}`).check()
    await page.getByRole('button', { name: 'Delete', exact: true }).click()
    await expect(page.getByRole('status').filter({ hasText: `Deleted ${created}` })).toBeVisible()
  })

  test('RDS instance detail: connectivity and configuration', async ({ page }) => {
    const id = ids.db ?? ''
    await page.goto(`/rds/databases/${encodeURIComponent(id)}`)
    await expect(
      page.getByRole('heading', { level: 1, name: id }),
    ).toBeVisible()
    for (const section of ['Connectivity & security', 'Configuration']) {
      await expect(
        page.getByRole('heading', { level: 2, name: section }),
      ).toBeVisible()
    }
    const connectivity = page.locator('.aws-kv').first()
    for (const label of [
      'Endpoint',
      'Port',
      'Master username',
      'DB name',
      'VPC',
      'Publicly accessible',
      'Connect',
    ]) {
      await expect(connectivity).toContainText(label)
    }
    await expect(connectivity).toContainText('stackwrangler')
    await expect(connectivity).toContainText('psql -h')
    const config = page.locator('.aws-kv').last()
    await expect(config).toContainText('DB instance class')
    await expect(config).toContainText('db.t3.micro')
    await expect(config).toContainText('20 GiB')
    const actions = page.getByRole('button', { name: 'Actions ▾' })
    await expect(actions).toBeDisabled()
    await expect(actions).toHaveAttribute('title', 'To implement')
    await expectDisabledControlsExplained(page)
  })

  test('RDS list links to the detail page', async ({ page }) => {
    const id = ids.db ?? ''
    await page.goto('/rds')
    await page.getByRole('link', { name: id, exact: true }).click()
    await expect(page).toHaveURL(new RegExp(`/rds/databases/${id}$`))
  })

  test('ECS cluster detail: overview, services, tasks', async ({ page }) => {
    await page.goto(`/ecs/clusters/${encodeURIComponent(clusterName)}`)
    await expect(
      page.getByRole('heading', { level: 1, name: clusterName }),
    ).toBeVisible()
    for (const section of ['Overview', 'Services', 'Tasks']) {
      await expect(
        page.getByRole('heading', { level: 2, name: section }),
      ).toBeVisible()
    }
    const overview = page.locator('.aws-kv').first()
    for (const label of ['Status', 'ARN', 'Active services', 'Running tasks']) {
      await expect(overview).toContainText(label)
    }
    await expect(overview).toContainText(`cluster/${clusterName}`)
    const services = page.getByTestId('ecs-services-table')
    for (const col of ['Service name', 'Desired tasks', 'Running tasks']) {
      await expect(services.locator('th').filter({ hasText: col })).toBeVisible()
    }
    await expect(services).toContainText(serviceName)
    const tasks = page.getByTestId('ecs-tasks-table')
    for (const col of ['Task', 'Last status', 'Desired status', 'Launch type']) {
      await expect(tasks.locator('th').filter({ hasText: col })).toBeVisible()
    }
    await expect(tasks).toContainText('No tasks')
    await expectDisabledControlsExplained(page)
  })

  test('ECS list links to the detail page', async ({ page }) => {
    await page.goto('/ecs')
    await page.getByRole('link', { name: clusterName, exact: true }).click()
    await expect(page).toHaveURL(
      new RegExp(`/ecs/clusters/${clusterName}$`),
    )
  })

  test('VPC detail: details, CIDR blocks, subnets, tags tabs', async ({ page }) => {
    const id = ids.vpc ?? ''
    const subnetId = ids.subnet ?? ''
    await page.goto(`/ec2/vpcs/${encodeURIComponent(id)}`)
    await expect(
      page.getByRole('heading', { level: 1, name: id, exact: true }),
    ).toBeVisible()
    await expect(page.locator('.aws-subtitle-row')).toContainText(vpcName)

    for (const tab of ['Details', 'CIDR blocks', 'Subnets', 'Tags']) {
      await expect(page.getByRole('button', { name: tab, exact: true })).toBeVisible()
    }

    const details = page.locator('.aws-kv').first()
    for (const label of [
      'VPC ID',
      'State',
      'IPv4 CIDR',
      'IPv6 CIDR',
      'DHCP option set',
      'Tenancy',
      'Default VPC',
      'Owner ID',
    ]) {
      await expect(details).toContainText(label)
    }
    await expect(details).toContainText(id)
    await expect(details).toContainText(cidr)

    await page.getByRole('button', { name: 'CIDR blocks', exact: true }).click()
    const cidrs = page.getByTestId('vpc-cidrs-table')
    await expect(cidrs).toContainText(cidr)
    await expect(cidrs.locator('th').filter({ hasText: 'Association ID' })).toBeVisible()

    await page.getByRole('button', { name: 'Subnets', exact: true }).click()
    const subnets = page.getByTestId('vpc-subnets-table')
    await expect(subnets).toContainText(subnetId)
    await expect(subnets).toContainText(subnetName)
    await expect(subnets).toContainText(subnetCidr)

    await page.getByRole('button', { name: 'Tags', exact: true }).click()
    await expect(page.locator('.aws-main table').last()).toContainText(vpcName)

    const actions = page.getByRole('button', { name: 'Actions ▾' })
    await expect(actions).toBeDisabled()
    await expect(actions).toHaveAttribute('title', 'To implement')
    await expectDisabledControlsExplained(page)
  })

  test('Load balancer detail: overview chrome', async ({ page }) => {
    const arn = ids.nlbArn ?? ''
    await page.goto(`/ec2/load-balancers?arn=${encodeURIComponent(arn)}`)
    await expect(
      page.getByRole('heading', { level: 1, name: nlbName }),
    ).toBeVisible()
    await expect(
      page.getByRole('heading', { level: 2, name: 'Overview' }),
    ).toBeVisible()
    const overview = page.locator('.aws-kv').first()
    for (const label of [
      'ARN',
      'DNS name',
      'State',
      'Type',
      'Scheme',
      'VPC ID',
      'Availability Zones',
    ]) {
      await expect(overview).toContainText(label)
    }
    await expect(overview).toContainText(arn)
    await expect(overview).toContainText(ids.vpc ?? '')
    const actions = page.getByRole('button', { name: 'Actions ▾' })
    await expect(actions).toBeDisabled()
    await expect(actions).toHaveAttribute('title', 'To implement')
    await expectDisabledControlsExplained(page)
  })

  test('Load balancer list links to the detail page', async ({ page }) => {
    await page.goto('/ec2/load-balancers')
    await page.getByRole('link', { name: nlbName, exact: true }).click()
    await expect(
      page.getByRole('heading', { level: 1, name: nlbName }),
    ).toBeVisible()
  })

  test('VPC list links to the detail page', async ({ page }) => {
    const id = ids.vpc ?? ''
    await page.goto('/ec2/vpcs')
    await page.getByRole('link', { name: id, exact: true }).click()
    await expect(page).toHaveURL(new RegExp(`/ec2/vpcs/${id}$`))
  })
})
