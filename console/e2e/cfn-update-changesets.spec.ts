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

async function waitStack(
  stack: string,
  want: string[],
  max = 60,
): Promise<string> {
  let st = ''
  for (let i = 0; i < max; i++) {
    st = aws([
      'cloudformation',
      'describe-stacks',
      '--stack-name',
      stack,
      '--query',
      'Stacks[0].StackStatus',
      '--output',
      'text',
    ]).trim()
    if (want.includes(st)) return st
    await new Promise((r) => setTimeout(r, 2000))
  }
  return st
}

test.describe('CloudFormation update + change sets UI', () => {
  test('update stack with template replace and change set execute/delete', async ({
    page,
  }) => {
    test.setTimeout(300_000)
    const ts = Date.now()
    const stack = `e2e-cfn-upd-${ts}`
    const queue = `e2e-cfn-upd-q-${ts}`
    const queue2 = `e2e-cfn-upd-q2-${ts}`
    const csName = `e2e-cs-${ts}`

    const tpl1 = JSON.stringify({
      AWSTemplateFormatVersion: '2010-09-09',
      Description: 'e2e cfn update v1',
      Resources: {
        DemoQueue: {
          Type: 'AWS::SQS::Queue',
          Properties: { QueueName: queue },
        },
      },
    })
    const tpl2 = JSON.stringify({
      AWSTemplateFormatVersion: '2010-09-09',
      Description: 'e2e cfn update v2',
      Resources: {
        DemoQueue: {
          Type: 'AWS::SQS::Queue',
          Properties: { QueueName: queue },
        },
        DemoQueueTwo: {
          Type: 'AWS::SQS::Queue',
          Properties: { QueueName: queue2 },
        },
      },
    })

    aws([
      'cloudformation',
      'create-stack',
      '--stack-name',
      stack,
      '--template-body',
      tpl1,
    ])
    expect(await waitStack(stack, ['CREATE_COMPLETE', 'CREATE_FAILED'])).toBe(
      'CREATE_COMPLETE',
    )

    await page.goto(`/cloudformation/stacks/${encodeURIComponent(stack)}`)
    await expect(page.getByRole('heading', { name: stack })).toBeVisible()

    await page.getByRole('button', { name: 'Update ▾' }).click()
    await page.getByRole('menuitem', { name: 'Update stack' }).click()
    await expect(page.getByRole('heading', { name: 'Update stack' })).toBeVisible()
    await page.locator('#template-body').fill(tpl2)
    await page.getByRole('button', { name: 'Update stack' }).click()
    await expect(page.getByRole('heading', { name: stack })).toBeVisible({
      timeout: 15000,
    })
    expect(
      await waitStack(stack, [
        'UPDATE_COMPLETE',
        'UPDATE_ROLLBACK_COMPLETE',
        'UPDATE_FAILED',
      ]),
    ).toBe('UPDATE_COMPLETE')

    await page.getByRole('button', { name: 'Change sets' }).click()
    await page.getByRole('link', { name: 'Create change set' }).click()
    await expect(
      page.getByRole('heading', { name: 'Create change set' }),
    ).toBeVisible()
    await page.locator('#changeset-name').fill(csName)
    await page.locator('#changeset-desc').fill('e2e change set')
    const tpl3 = JSON.stringify({
      AWSTemplateFormatVersion: '2010-09-09',
      Description: 'e2e cfn changeset',
      Resources: {
        DemoQueue: {
          Type: 'AWS::SQS::Queue',
          Properties: { QueueName: queue },
        },
      },
    })
    await page.locator('#template-body').fill(tpl3)
    await page.getByRole('button', { name: 'Create change set' }).click()
    await expect(page.getByRole('heading', { name: csName })).toBeVisible({
      timeout: 30000,
    })

    for (let i = 0; i < 30; i++) {
      const ready = page.getByText('AVAILABLE').first()
      if (await ready.isVisible().catch(() => false)) break
      await page.reload()
      await expect(page.getByRole('heading', { name: csName })).toBeVisible()
      await page.waitForTimeout(2000)
    }

    await page.getByRole('button', { name: 'Execute change set' }).click()
    await expect(page.getByRole('heading', { name: stack })).toBeVisible({
      timeout: 15000,
    })
    expect(
      await waitStack(stack, [
        'UPDATE_COMPLETE',
        'UPDATE_ROLLBACK_COMPLETE',
        'UPDATE_FAILED',
      ]),
    ).toBe('UPDATE_COMPLETE')

    aws([
      'cloudformation',
      'create-change-set',
      '--stack-name',
      stack,
      '--change-set-name',
      `${csName}-del`,
      '--change-set-type',
      'UPDATE',
      '--template-body',
      tpl2,
    ])
    for (let i = 0; i < 30; i++) {
      const st = aws([
        'cloudformation',
        'describe-change-set',
        '--stack-name',
        stack,
        '--change-set-name',
        `${csName}-del`,
        '--query',
        'Status',
        '--output',
        'text',
      ]).trim()
      if (st === 'CREATE_COMPLETE' || st === 'FAILED') break
      await new Promise((r) => setTimeout(r, 2000))
    }

    await page.goto(`/cloudformation/stacks/${encodeURIComponent(stack)}`)
    await page.getByRole('button', { name: 'Change sets' }).click()
    await expect(page.getByRole('link', { name: `${csName}-del` })).toBeVisible({
      timeout: 15000,
    })
    await page
      .getByRole('row', { name: new RegExp(`${csName}-del`) })
      .locator('input[type="radio"]')
      .click()
    await page.getByTestId('btn-delete-changeset').click()
    await expect(
      page.getByRole('link', { name: `${csName}-del` }),
    ).toHaveCount(0, { timeout: 15000 })

    aws(['cloudformation', 'delete-stack', '--stack-name', stack])
  })
})
