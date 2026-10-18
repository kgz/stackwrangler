import { execFileSync } from 'node:child_process'
import { writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, test } from '@playwright/test'

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
    const paths = [
      '/directory-buckets',
      '/table-buckets',
      '/vector-buckets',
    ]
    for (const path of paths) {
      await page.goto(path)
      await expect(page.getByText('Not available on local stack')).toBeVisible()
      await expect(
        page.getByRole('button', { name: /Create .+ bucket/ }),
      ).toBeDisabled()
      await expect(
        page.getByRole('link', { name: 'Go to General purpose buckets' }),
      ).toBeVisible()
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

  test('selects a row on the list and empties via toolbar', async ({ page }) => {
    const name = `e2e-sel-${Date.now()}`
    aws(['s3', 'mb', `s3://${name}`])
    putText(name, 'z.txt', 'z')

    await page.goto('/')
    await page.getByPlaceholder('Find buckets by name').fill(name)
    await page.getByRole('checkbox', { name: `Select ${name}` }).check()
    await expect(page.getByRole('button', { name: 'Empty' })).toBeEnabled()
    await page.getByRole('button', { name: 'Empty' }).click()
    await page.getByRole('button', { name: 'Empty', exact: true }).last().click()

    const listed = aws(['s3', 'ls', `s3://${name}/`])
    expect(listed).toBe('')

    aws(['s3', 'rb', `s3://${name}`, '--force'])
  })
})
