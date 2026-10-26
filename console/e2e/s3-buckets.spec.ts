import { execFileSync } from 'node:child_process'
import { writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, test, type Page } from '@playwright/test'

const profile = process.env.AWSBOX_PROFILE || 'local'

function aws(args: string[]): string {
  return execFileSync('aws', ['--profile', profile, ...args], {
    encoding: 'utf8',
  }).trim()
}

function putText(bucket: string, key: string, body: string): void {
  const path = join(tmpdir(), `awsbox-${Date.now()}-${key}`)
  writeFileSync(path, body)
  aws(['s3', 'cp', path, `s3://${bucket}/${key}`])
}

test.describe('S3 general purpose buckets (UI + CLI)', () => {
  const bucket = `e2e-ui-${Date.now()}`

  test.afterAll(() => {
    try {
      aws(['s3', 'rb', `s3://${bucket}`, '--force'])
    } catch {
      try {
        aws(['s3api', 'delete-bucket', '--bucket', bucket])
      } catch {
        // gone already
      }
    }
  })

  test('lists buckets from the live S3 API', async ({ page }) => {
    aws(['s3', 'mb', `s3://${bucket}`])

    await page.goto('/')
    await expect(
      page.getByRole('heading', { name: 'Buckets', exact: true }),
    ).toBeVisible()
    await page.getByPlaceholder('Find buckets by name').fill(bucket)
    await expect(page.getByRole('link', { name: bucket })).toBeVisible()
  })

  test('creates a bucket in the UI and CLI can see it', async ({ page }) => {
    const name = `e2e-create-${Date.now()}`

    await page.goto('/')
    await page.getByRole('button', { name: 'Create bucket' }).first().click()
    await page.getByLabel('Bucket name').fill(name)
    await page.getByRole('button', { name: 'Create bucket' }).last().click()

    await page.getByPlaceholder('Find buckets by name').fill(name)
    await expect(page.getByRole('link', { name })).toBeVisible()

    const listed = aws(['s3', 'ls'])
    expect(listed).toContain(name)

    aws(['s3', 'rb', `s3://${name}`, '--force'])
  })

  test('uploads an object in the UI; CLI can download it', async ({ page }) => {
    const name = `e2e-obj-${Date.now()}`
    aws(['s3', 'mb', `s3://${name}`])

    await page.goto(`/buckets/${encodeURIComponent(name)}`)
    await expect(page.getByRole('heading', { name })).toBeVisible()

    const fileChooserPromise = page.waitForEvent('filechooser')
    await page.getByRole('button', { name: 'Upload' }).click()
    const chooser = await fileChooserPromise
    await chooser.setFiles({
      name: 'e2e-hello.txt',
      mimeType: 'text/plain',
      buffer: Buffer.from('hello from playwright'),
    })

    await expect(page.getByText('Uploaded 1 object(s).')).toBeVisible()
    await expect(page.getByText('e2e-hello.txt')).toBeVisible()

    const body = aws([
      's3',
      'cp',
      `s3://${name}/e2e-hello.txt`,
      '-',
    ])
    expect(body).toContain('hello from playwright')

    aws(['s3', 'rb', `s3://${name}`, '--force'])
  })

  test('opens text object preview inline', async ({ page }) => {
    const name = `e2e-preview-${Date.now()}`
    aws(['s3', 'mb', `s3://${name}`])
    putText(name, 'note.txt', 'preview me please')

    await page.goto(`/buckets/${encodeURIComponent(name)}`)
    await page.getByRole('button', { name: 'note.txt' }).click()
    await expect(page.getByRole('dialog')).toBeVisible()
    await expect(page.getByTestId('object-preview-text')).toContainText(
      'preview me please',
    )
    await page.getByRole('button', { name: 'Close' }).click()
    await expect(page.getByRole('dialog')).toHaveCount(0)

    aws(['s3', 'rb', `s3://${name}`, '--force'])
  })

  test('specialty bucket pages show empty local-stack states', async ({
    page,
  }) => {
    const cases = [
      { path: '/directory-buckets', empty: 'No buckets', create: 'Create bucket' },
      { path: '/table-buckets', empty: 'No table buckets', create: 'Create table bucket' },
      { path: '/vector-buckets', empty: 'No vector buckets', create: 'Create vector bucket' },
    ]
    for (const c of cases) {
      await page.goto(c.path)
      await expect(page.getByText(c.empty, { exact: true })).toBeVisible()
      const create = page.getByRole('button', { name: c.create })
      await expect(create).toBeDisabled()
      await expect(create).toHaveAttribute('title', 'To implement')
    }
  })

  test('access management pages show empty local-stack states', async ({
    page,
  }) => {
    const cases = [
      { path: '/access-points', empty: 'No access points', create: 'Create access point' },
      { path: '/access-points-fsx', empty: 'No Access Points for FSx', create: 'Create access point' },
      { path: '/access-grants', empty: 'No Access Grants', create: 'Create grant' },
    ]
    for (const c of cases) {
      await page.goto(c.path)
      await expect(page.getByText(c.empty, { exact: true })).toBeVisible()
      await expect(page.getByRole('button', { name: c.create })).toBeDisabled()
    }
  })

  test('storage insights pages show empty local-stack states', async ({
    page,
  }) => {
    const cases = [
      { path: '/storage-lens', empty: 'No Storage Lens dashboards', create: 'Create dashboard' },
      { path: '/batch-operations', empty: 'No Batch Operations jobs', create: 'Create job' },
    ]
    for (const c of cases) {
      await page.goto(c.path)
      await expect(page.getByText(c.empty, { exact: true })).toBeVisible()
      await expect(page.getByRole('button', { name: c.create })).toBeDisabled()
    }
  })

  test('other S3 panels render mock layouts with disabled actions', async ({
    page,
  }) => {
    await page.goto('/file-systems')
    await expect(page.getByText('No file systems')).toBeVisible()
    await expect(
      page.getByRole('button', { name: 'Create file system' }),
    ).toBeDisabled()

    await page.goto('/access-analyzer')
    await expect(page.getByText('No findings to display')).toBeVisible()
    await expect(
      page.getByRole('button', { name: 'Download report' }),
    ).toBeDisabled()

    await page.goto('/account-settings')
    await expect(
      page.getByText('Block Public Access settings for this account'),
    ).toBeVisible()
    await expect(page.getByRole('button', { name: 'Edit', exact: true })).toBeDisabled()

    await page.goto('/marketplace')
    await expect(
      page.getByRole('heading', {
        name: 'Search all AWS Marketplace products for S3',
      }),
    ).toBeVisible()
  })

  test('shared chrome: services, search, region, account', async ({ page }) => {
    await page.goto('/')

    await page.getByRole('button', { name: 'Services' }).click()
    await expect(
      page.getByRole('navigation', { name: 'Services' }),
    ).toBeVisible()
    await page
      .getByRole('navigation', { name: 'Services' })
      .getByRole('link', { name: /IAM/ })
      .click()
    await expect(page).toHaveURL(/\/iam$/)

    await page.getByLabel('Search', { exact: true }).fill('storage lens')
    await page.getByRole('option', { name: /Storage Lens/ }).first().click()
    await expect(page).toHaveURL(/\/storage-lens$/)

    await page.getByRole('button', { name: /^US East|^Asia Pacific|^Europe/ }).first().click()
    await expect(page.getByText('Regions', { exact: true })).toBeVisible()

    await page.getByRole('button', { name: /Account ID:/ }).click()
    await expect(page.getByText('Account name')).toBeVisible()
    await expect(page.getByRole('button', { name: 'Sign out' })).toBeDisabled()
  })

  test('no enabled control carries the To implement marker', async ({ page }) => {
    const paths = [
      '/',
      '/directory-buckets',
      '/table-buckets',
      '/vector-buckets',
      '/file-systems',
      '/access-points',
      '/access-analyzer',
      '/storage-lens',
      '/account-settings',
      '/marketplace',
    ]
    for (const path of paths) {
      await page.goto(path)
      await expect(page.locator('main')).toBeVisible()
      await expect(
        page.locator('button[title="To implement"]:not([disabled])'),
      ).toHaveCount(0)
    }
  })

  test('empties a bucket from Properties; CLI sees no objects', async ({
    page,
  }) => {
    const name = `e2e-empty-${Date.now()}`
    aws(['s3', 'mb', `s3://${name}`])
    putText(name, 'a.txt', 'a')
    putText(name, 'b.txt', 'b')

    await page.goto(`/buckets/${encodeURIComponent(name)}`)
    await page.getByRole('button', { name: 'Properties' }).click()
    await page.getByRole('button', { name: 'Empty bucket' }).click()
    await page.getByRole('button', { name: 'Empty', exact: true }).click()
    await page.getByRole('button', { name: 'Objects' }).click()
    await expect(page.getByText('No objects')).toBeVisible()

    const listed = aws(['s3', 'ls', `s3://${name}/`])
    expect(listed).toBe('')

    aws(['s3', 'rb', `s3://${name}`, '--force'])
  })

  test('deletes objects with confirmation + toast', async ({ page }) => {
    const name = `e2e-objdel-${Date.now()}`
    aws(['s3', 'mb', `s3://${name}`])
    putText(name, 'kill-me.txt', 'bye')

    await page.goto(`/buckets/${encodeURIComponent(name)}`)
    await page.getByRole('checkbox', { name: 'Select kill-me.txt' }).check()
    await page.getByRole('button', { name: 'Delete', exact: true }).click()
    await expect(
      page.getByRole('heading', { name: 'Delete objects (1)?' }),
    ).toBeVisible()
    await page.getByRole('button', { name: 'Delete objects' }).click()
    await expect(page.getByText(/Successfully deleted object/)).toBeVisible()
    await expect(page.getByText('No objects')).toBeVisible()

    aws(['s3', 'rb', `s3://${name}`, '--force'])
  })

  test('deletes a bucket from Properties; CLI no longer lists it', async ({
    page,
  }) => {
    const name = `e2e-del-${Date.now()}`
    aws(['s3', 'mb', `s3://${name}`])
    putText(name, 'x.txt', 'x')

    await page.goto(`/buckets/${encodeURIComponent(name)}`)
    await page.getByRole('button', { name: 'Properties' }).click()
    await page.getByRole('button', { name: 'Delete bucket' }).click()
    await page.getByRole('button', { name: 'Delete bucket' }).last().click()
    await expect(
      page.getByRole('heading', { name: 'Buckets', exact: true }),
    ).toBeVisible()

    const listed = aws(['s3', 'ls'])
    expect(listed).not.toContain(name)
  })

  test.describe('clipboard actions', () => {
    test.use({ permissions: ['clipboard-read', 'clipboard-write'] })

    async function clipboard(page: Page) {
      return page.evaluate(() => navigator.clipboard.readText())
    }

    test('Copy ARN on the bucket list copies the bucket ARN', async ({ page }) => {
      const name = `e2e-arn-${Date.now()}`
      aws(['s3', 'mb', `s3://${name}`])

      await page.goto('/')
      await page.getByPlaceholder('Find buckets by name').fill(name)
      const copy = page.getByRole('button', { name: 'Copy ARN' })
      await expect(copy).toBeDisabled()
      await page.getByRole('radio', { name: `Select ${name}` }).check()
      await copy.click()
      await expect.poll(() => clipboard(page)).toBe(`arn:aws:s3:::${name}`)

      aws(['s3', 'rb', `s3://${name}`, '--force'])
    })

    test('Copy S3 URI on the objects page copies the object URI', async ({ page }) => {
      const name = `e2e-uri-${Date.now()}`
      aws(['s3', 'mb', `s3://${name}`])
      putText(name, 'uri.txt', 'u')

      await page.goto(`/buckets/${encodeURIComponent(name)}`)
      const copy = page.getByRole('button', { name: 'Copy S3 URI' })
      await expect(copy).toBeDisabled()
      await page.getByRole('checkbox', { name: 'Select uri.txt' }).check()
      await copy.click()
      await expect.poll(() => clipboard(page)).toBe(`s3://${name}/uri.txt`)

      aws(['s3', 'rb', `s3://${name}`, '--force'])
    })

    test('Copy account ID in the account menu copies the raw account ID', async ({
      page,
    }) => {
      await page.goto('/')
      await page.getByRole('button', { name: /Account ID:/ }).click()
      await page.getByRole('button', { name: 'Copy account ID' }).click()
      await expect.poll(() => clipboard(page)).toMatch(/^\d{12}$/)
    })
  })

  test('selects a row on the list and empties via toolbar', async ({ page }) => {
    const name = `e2e-sel-${Date.now()}`
    aws(['s3', 'mb', `s3://${name}`])
    putText(name, 'z.txt', 'z')

    await page.goto('/')
    await page.getByPlaceholder('Find buckets by name').fill(name)
    await page.getByRole('radio', { name: `Select ${name}` }).check()
    await expect(page.getByRole('button', { name: 'Empty' })).toBeEnabled()
    await page.getByRole('button', { name: 'Empty' }).click()
    await page.getByRole('button', { name: 'Empty', exact: true }).last().click()

    const listed = aws(['s3', 'ls', `s3://${name}/`])
    expect(listed).toBe('')

    aws(['s3', 'rb', `s3://${name}`, '--force'])
  })
})
