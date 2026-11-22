import { expect, test, type Page } from '@playwright/test'
import { execFileSync } from 'node:child_process'
import { randomBytes } from 'node:crypto'
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
  ).trim()
}

function tryAws(args: string[]) {
  try {
    aws(args)
  } catch {
    /* ignore */
  }
}

function fakePubKey(comment: string): string {
  return `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI${randomBytes(16).toString('base64url').slice(0, 32)} ${comment}`
}

async function expectDecodedPath(page: Page, path: string) {
  await expect
    .poll(() => {
      const url = new URL(page.url())
      return decodeURIComponent(url.pathname)
    })
    .toBe(path)
}

test.describe('Transfer create user + import SSH key (#321)', () => {
  const ts = Date.now()
  const roleName = `e2e-xfer-role-${ts}`
  const createUserName = `e2e-xfer-create-${ts}`
  const importUserName = `e2e-xfer-import-${ts}`
  let serverId = ''
  let roleArn = ''
  const pubKey = fakePubKey('e2e@stackwrangler')

  test.beforeAll(() => {
    aws([
      'iam',
      'create-role',
      '--role-name',
      roleName,
      '--assume-role-policy-document',
      JSON.stringify({
        Version: '2012-10-17',
        Statement: [
          {
            Effect: 'Allow',
            Principal: { Service: 'transfer.amazonaws.com' },
            Action: 'sts:AssumeRole',
          },
        ],
      }),
    ])
    roleArn = aws([
      'iam',
      'get-role',
      '--role-name',
      roleName,
      '--query',
      'Role.Arn',
      '--output',
      'text',
    ])
    serverId = aws([
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
      serverId,
      '--user-name',
      importUserName,
      '--role',
      roleArn,
      '--home-directory',
      '/e2e-import-home',
      '--home-directory-type',
      'PATH',
    ])
  })

  test.afterAll(() => {
    for (const name of [createUserName, importUserName]) {
      if (serverId) {
        tryAws([
          'transfer',
          'delete-user',
          '--server-id',
          serverId,
          '--user-name',
          name,
        ])
      }
    }
    if (serverId) {
      tryAws(['transfer', 'delete-server', '--server-id', serverId])
    }
    tryAws(['iam', 'delete-role', '--role-name', roleName])
  })

  test('create user with SSH key from server detail', async ({ page }) => {
    await page.goto(`/transfer/servers/${encodeURIComponent(serverId)}`)
    await expect(
      page.getByRole('heading', { level: 1, name: serverId }),
    ).toBeVisible()
    await expect(page.getByTestId('transfer-add-user')).toBeVisible()
    await expect(page.getByTestId('transfer-add-ssh-key')).toBeVisible()
    await expect(page.getByTestId('transfer-delete-user')).toBeDisabled()
    await expect(page.getByTestId('transfer-delete-user')).toHaveAttribute(
      'title',
      'To implement',
    )

    await page.getByTestId('transfer-add-user').click()
    await expectDecodedPath(
      page,
      `/transfer/servers/${serverId}/users/create`,
    )
    await page.getByTestId('transfer-create-user-name').fill(createUserName)
    await page.getByTestId('transfer-create-role').fill(roleArn)
    await page.getByTestId('transfer-create-home').fill('/e2e-home')
    await page.getByTestId('transfer-create-ssh-key').fill(pubKey)
    await page.getByTestId('transfer-create-user-submit').click()
    await expectDecodedPath(
      page,
      `/transfer/servers/${serverId}/users/${createUserName}`,
    )
    await expect(
      page.getByRole('heading', { level: 1, name: createUserName }),
    ).toBeVisible()
    const keys = page.getByTestId('transfer-ssh-keys-table')
    await expect(keys).toContainText(pubKey.slice(0, 24), { timeout: 15000 })

    const described = aws([
      'transfer',
      'describe-user',
      '--server-id',
      serverId,
      '--user-name',
      createUserName,
      '--output',
      'json',
    ])
    expect(described).toContain('SshPublicKey')
    expect(described).toContain(pubKey.split(' ')[0] ?? 'ssh-ed25519')
  })

  test('import SSH key from UI for existing user', async ({ page }) => {
    const secondKey = fakePubKey('e2e-import@stackwrangler')
    await page.goto(
      `/transfer/servers/${encodeURIComponent(serverId)}/users/import-ssh-key?user=${encodeURIComponent(importUserName)}`,
    )
    await expect(
      page.getByRole('heading', { level: 1, name: 'Import SSH public key' }),
    ).toBeVisible()
    await expect(page.getByTestId('transfer-import-user')).toHaveValue(
      importUserName,
      { timeout: 15000 },
    )
    await page.getByTestId('transfer-import-ssh-key').fill(secondKey)
    await page.getByTestId('transfer-import-submit').click()
    await expectDecodedPath(
      page,
      `/transfer/servers/${serverId}/users/${importUserName}`,
    )
    const keys = page.getByTestId('transfer-ssh-keys-table')
    await expect(keys).toContainText(secondKey.slice(0, 24), { timeout: 15000 })

    const described = aws([
      'transfer',
      'describe-user',
      '--server-id',
      serverId,
      '--user-name',
      importUserName,
      '--output',
      'json',
    ])
    expect(described).toContain('SshPublicKey')
  })
})
