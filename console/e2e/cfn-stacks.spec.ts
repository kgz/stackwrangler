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

test.describe('CloudFormation stacks UI', () => {
  test('lists stacks and opens detail tabs', async ({ page }) => {
    const ts = Date.now()
    const stack = `e2e-cfn-ui-${ts}`
    const bucket = `e2e-cfn-ui-b-${ts}`

    const template = JSON.stringify({
      AWSTemplateFormatVersion: '2010-09-09',
      Description: 'e2e awsbox cfn ui',
      Resources: {
        DemoBucket: {
          Type: 'AWS::S3::Bucket',
          Properties: { BucketName: bucket },
        },
      },
      Outputs: {
        BucketName: { Value: { Ref: 'DemoBucket' } },
      },
    })

    aws([
      'cloudformation',
      'create-stack',
      '--stack-name',
      stack,
      '--template-body',
      template,
    ])

    for (let i = 0; i < 60; i++) {
      const st = aws([
        'cloudformation',
        'describe-stacks',
        '--stack-name',
        stack,
        '--query',
        'Stacks[0].StackStatus',
        '--output',
        'text',
      ]).trim()
      if (st === 'CREATE_COMPLETE' || st === 'CREATE_FAILED') break
      await new Promise((r) => setTimeout(r, 2000))
    }

    await page.goto('/cloudformation')
    await expect(
      page.getByRole('heading', { name: /^Stacks \(/ }),
    ).toBeVisible()
    await expect(page.getByRole('link', { name: stack })).toBeVisible({
      timeout: 15000,
    })
    await page.getByRole('link', { name: stack }).click()
    await expect(page.getByRole('heading', { name: stack })).toBeVisible()
    await page.getByRole('button', { name: 'Resources' }).click()
    await expect(page.getByText('DemoBucket')).toBeVisible()
    await page.getByRole('button', { name: 'Outputs' }).click()
    await expect(page.getByText(bucket)).toBeVisible()

    aws(['cloudformation', 'delete-stack', '--stack-name', stack])
  })
})
