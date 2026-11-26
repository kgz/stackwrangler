import { expect, test } from '@playwright/test'
import { execFileSync } from 'node:child_process'
import { e2eCreds } from './helpers/env'

const EP = e2eCreds.iamEndpoint
const KEY = e2eCreds.accessKey
const SECRET = e2eCreds.secretKey
const REGION = e2eCreds.region

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

test.describe('ECS run task / create service / logs (#545)', () => {
  test.describe.configure({ mode: 'serial' })
  test.setTimeout(240_000)

  const ts = Date.now()
  const clusterName = `e2e-ecs545-${ts}`
  const family = `e2e-ecs545-td-${ts}`
  const serviceName = `e2e-ecs545-svc-${ts}`
  const logGroup = `/ecs/${family}`
  const cidr = '10.232.0.0/16'
  const subnetCidr = '10.232.1.0/24'
  const ids: {
    vpc?: string
    subnet?: string
    sg?: string
    taskArn?: string
  } = {}

  test.beforeAll(() => {
    ids.vpc = aws([
      'ec2',
      'create-vpc',
      '--cidr-block',
      cidr,
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
      '--query',
      'Subnet.SubnetId',
      '--output',
      'text',
    ])
    ids.sg = aws([
      'ec2',
      'create-security-group',
      '--group-name',
      `e2e-ecs545-sg-${ts}`,
      '--description',
      'e2e ecs 545',
      '--vpc-id',
      ids.vpc,
      '--query',
      'GroupId',
      '--output',
      'text',
    ])

    aws(['ecs', 'create-cluster', '--cluster-name', clusterName])
    tryAws(['logs', 'create-log-group', '--log-group-name', logGroup])

    aws([
      'ecs',
      'register-task-definition',
      '--family',
      family,
      '--requires-compatibilities',
      'FARGATE',
      '--network-mode',
      'awsvpc',
      '--cpu',
      '256',
      '--memory',
      '512',
      '--container-definitions',
      JSON.stringify([
        {
          name: 'web',
          image: 'nginx:alpine',
          essential: true,
          logConfiguration: {
            logDriver: 'awslogs',
            options: {
              'awslogs-group': logGroup,
              'awslogs-region': REGION,
              'awslogs-stream-prefix': 'ecs',
            },
          },
        },
      ]),
    ])
  })

  test.afterAll(() => {
    if (ids.taskArn) {
      tryAws([
        'ecs',
        'stop-task',
        '--cluster',
        clusterName,
        '--task',
        ids.taskArn,
      ])
    }
    tryAws([
      'ecs',
      'delete-service',
      '--cluster',
      clusterName,
      '--service',
      serviceName,
      '--force',
    ])
    for (let i = 0; i < 10; i++) {
      try {
        aws(['ecs', 'delete-cluster', '--cluster', clusterName])
        break
      } catch {
        execFileSync('sleep', ['1'])
      }
    }
    tryAws(['logs', 'delete-log-group', '--log-group-name', logGroup])
    if (ids.sg) tryAws(['ec2', 'delete-security-group', '--group-id', ids.sg])
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
    if (ids.vpc) {
      for (let i = 0; i < 20; i++) {
        try {
          aws(['ec2', 'delete-vpc', '--vpc-id', ids.vpc])
          break
        } catch {
          execFileSync('sleep', ['1'])
        }
      }
    }
  })

  test('create service thin form', async ({ page }) => {
    await page.goto(`/ecs/clusters/${encodeURIComponent(clusterName)}`)
    await expect(
      page.getByRole('heading', { level: 1, name: clusterName }),
    ).toBeVisible()
    await page.getByTestId('ecs-create-service-link').click()
    await expect(page).toHaveURL(/\/create-service$/)
    await expect(
      page.getByRole('heading', { level: 1, name: 'Create service' }),
    ).toBeVisible()

    await page.getByTestId('ecs-service-name').fill(serviceName)
    await page.getByTestId('ecs-service-task-definition').fill(family)
    await page.getByTestId('ecs-desired-count').fill('0')
    await page.getByTestId('ecs-subnets').fill(ids.subnet ?? '')
    await page.getByTestId('ecs-security-groups').fill(ids.sg ?? '')
    await page.getByTestId('ecs-create-service-submit').click()

    await expect(page).toHaveURL(
      new RegExp(`/ecs/clusters/${clusterName}$`),
    )
    await expect(page.getByTestId('ecs-services-table')).toContainText(
      serviceName,
      { timeout: 60_000 },
    )
  })

  test('run task, awslogs panel, stop', async ({ page }) => {
    await page.goto(`/ecs/clusters/${encodeURIComponent(clusterName)}`)
    await page.getByTestId('ecs-run-task-link').click()
    await expect(page).toHaveURL(/\/run-task$/)
    await expect(
      page.getByRole('heading', { level: 1, name: 'Run task' }),
    ).toBeVisible()

    await page.getByTestId('ecs-run-task-definition').fill(family)
    await page.getByTestId('ecs-subnets').fill(ids.subnet ?? '')
    await page.getByTestId('ecs-security-groups').fill(ids.sg ?? '')
    await page.getByTestId('ecs-run-submit').click()

    await expect(page).toHaveURL(/\/tasks\//, { timeout: 120_000 })
    await expect(page.getByTestId('ecs-containers-table')).toBeVisible({
      timeout: 60_000,
    })
    await expect(page.getByTestId('ecs-logs-awslogs')).toBeVisible()
    await expect(page.getByTestId('ecs-view-logs')).toBeVisible()
    await expect(page.getByTestId('ecs-view-logs')).toHaveAttribute(
      'href',
      new RegExp(`/logs/log-groups/${encodeURIComponent(logGroup)}`),
    )

    const taskShort = page.url().split('/tasks/').pop() ?? ''
    expect(taskShort.length).toBeGreaterThan(4)
    ids.taskArn = aws([
      'ecs',
      'list-tasks',
      '--cluster',
      clusterName,
      '--query',
      'taskArns[0]',
      '--output',
      'text',
    ])

    await page.getByTestId('ecs-stop-task').click()
    await expect(page.getByText('STOPPED').first()).toBeVisible({
      timeout: 120_000,
    })
  })
})
