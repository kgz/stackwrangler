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

test.describe('Step Functions state machines UI (#175 / #610)', () => {
  test('lists a seeded state machine, opens detail, starts execution', async ({
    page,
  }) => {
    const ts = Date.now()
    const name = `e2e-sfn-ui-${ts}`
    const role = `e2e-sfn-role-${ts}`
    const execName = `run-${ts}`
    const trust =
      '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"states.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
    const def =
      '{"Comment":"e2e","StartAt":"Hi","States":{"Hi":{"Type":"Pass","Result":{"ok":true},"End":true}}}'

    let smArn = ''
    try {
      aws([
        'iam',
        'create-role',
        '--role-name',
        role,
        '--assume-role-policy-document',
        trust,
      ])
      const roleArn = aws([
        'iam',
        'get-role',
        '--role-name',
        role,
        '--query',
        'Role.Arn',
        '--output',
        'text',
      ]).trim()
      smArn = aws([
        'stepfunctions',
        'create-state-machine',
        '--name',
        name,
        '--definition',
        def,
        '--role-arn',
        roleArn,
        '--query',
        'stateMachineArn',
        '--output',
        'text',
      ]).trim()

      await page.goto('/stepfunctions')
      await expect(
        page.getByRole('heading', { level: 1, name: 'State machines' }),
      ).toBeVisible()
      await expect(
        page.getByTestId('sfn-state-machines-table'),
      ).toBeVisible()
      await expect(
        page.getByRole('link', { name, exact: true }),
      ).toBeVisible({ timeout: 15000 })
      await expect(
        page.getByRole('button', { name: 'Create state machine' }),
      ).toBeDisabled()

      await page.getByRole('link', { name, exact: true }).click()
      await expect(page).toHaveURL(
        new RegExp(`/stepfunctions/state-machines/${name}$`),
      )
      await expect(
        page.getByRole('heading', { level: 1, name }),
      ).toBeVisible()
      await expect(page.getByTestId('sfn-tab-details')).toBeVisible()
      await page.getByTestId('sfn-tab-definition').click()
      await expect(page.getByTestId('sfn-definition')).toContainText('Pass')

      await page.getByTestId('sfn-start-execution').click()
      await expect(page.getByTestId('sfn-start-modal')).toBeVisible()
      await page.getByTestId('sfn-exec-name').fill(execName)
      await page.getByTestId('sfn-exec-input').fill('{"ping":true}')
      await page.getByTestId('sfn-start-submit').click()

      await expect(page.getByTestId('sfn-executions-table')).toBeVisible({
        timeout: 15000,
      })
      await expect(
        page.getByTestId('sfn-executions-table').getByText(execName),
      ).toBeVisible({ timeout: 15000 })
    } finally {
      if (smArn) {
        try {
          aws([
            'stepfunctions',
            'delete-state-machine',
            '--state-machine-arn',
            smArn,
          ])
        } catch {
          /* ignore */
        }
      }
      try {
        aws(['iam', 'delete-role', '--role-name', role])
      } catch {
        /* ignore */
      }
    }
  })
})
