import { createRequire } from 'node:module'
import path from 'node:path'
import { defineConfig } from 'vitepress'
import { withMermaid } from 'vitepress-plugin-mermaid'

// Production: https://stackwrangler.dev (GitHub Pages custom domain; base `/`).
// Local `pnpm dev` / `pnpm preview` → same base `/` at http://127.0.0.1:5173/
const require = createRequire(import.meta.url)
const dayjsRoot = path.dirname(require.resolve('dayjs/package.json'))
const dayjsEsm = path.join(dayjsRoot, 'esm/index.js')

/** Production origin for canonical / OG / sitemap. */
const siteHostname = 'https://stackwrangler.dev'
const siteBasePath = '/'
const siteUrl = `${siteHostname}/`
const siteDescription =
  'Local AWS-shaped account for real APIs, console, and IaC — then deploy to real AWS'

function pagePathFromRelative(relativePath: string): string {
  if (relativePath === 'index.md') return siteBasePath
  const bare = relativePath.replace(/\.md$/, '').replace(/\/index$/, '/')
  const withSlash = bare.endsWith('/') ? bare : `${bare}`
  return `${siteBasePath}${withSlash}`.replace(/\/{2,}/g, '/')
}

export default withMermaid(
  defineConfig({
    title: 'stackwrangler',
    description: siteDescription,
    lang: 'en-US',
    base: '/',
    ignoreDeadLinks: true,
    lastUpdated: true,
    cleanUrls: true,
    // Drop maintainer README from the public map; locs are already on siteHostname.
    sitemap: {
      hostname: siteHostname,
      transformItems(items) {
        const mapped = items
          .filter((item) => !/README(?:\.html)?\/?$/i.test(item.url))
          .map((item) => {
            const path = item.url.replace(siteHostname, '')
            return {
              ...item,
              url: `${siteHostname}${path.startsWith('/') ? path : `/${path}`}`.replace(
                /([^:]\/)\/+/g,
                '$1',
              ),
            }
          })
        const llms = `${siteHostname}/llms.txt`
        if (!mapped.some((item) => item.url === llms)) {
          mapped.push({ url: llms })
        }
        return mapped
      },
    },
    head: [
      [
        'meta',
        {
          name: 'google-site-verification',
          content: '97g4GEkc7U6apxN5WY3aj2s4u8_7Ji9KrxFscrKxnaQ',
        },
      ],
      ['meta', { name: 'robots', content: 'index, follow, max-image-preview:large' }],
      ['meta', { name: 'googlebot', content: 'index, follow' }],
      ['meta', { name: 'author', content: 'stackwrangler contributors' }],
      [
        'meta',
        {
          name: 'keywords',
          content:
            'stackwrangler, local AWS, LocalEmu, AWS emulator, AWS Emulator, IAM enforcement, OpenTofu, Terraform local, serverless, IaC, localstack alternative, Floci alternative',
        },
      ],
      ['meta', { property: 'og:type', content: 'website' }],
      ['meta', { property: 'og:site_name', content: 'stackwrangler' }],
      ['meta', { property: 'og:locale', content: 'en_US' }],
      ['meta', { property: 'og:title', content: 'stackwrangler' }],
      ['meta', { property: 'og:description', content: siteDescription }],
      ['meta', { name: 'twitter:card', content: 'summary' }],
      ['meta', { name: 'twitter:title', content: 'stackwrangler' }],
      ['meta', { name: 'twitter:description', content: siteDescription }],
      // per-page canonical / og:url / titles via transformHead
      [
        'script',
        { type: 'application/ld+json' },
        JSON.stringify({
          '@context': 'https://schema.org',
          '@type': 'WebSite',
          name: 'stackwrangler',
          url: siteUrl,
          description: siteDescription,
          publisher: {
            '@type': 'Organization',
            name: 'stackwrangler',
            url: 'https://github.com/kgz/stackwrangler',
          },
        }),
      ],
      [
        'script',
        { type: 'application/ld+json' },
        JSON.stringify({
          '@context': 'https://schema.org',
          '@type': 'SoftwareApplication',
          name: 'stackwrangler',
          applicationCategory: 'DeveloperApplication',
          operatingSystem: 'Linux',
          license: 'https://opensource.org/licenses/MIT',
          url: siteUrl,
          codeRepository: 'https://github.com/kgz/stackwrangler',
          description: siteDescription,
        }),
      ],
    ],
    transformHead({ pageData }) {
      const path = pagePathFromRelative(pageData.relativePath)
      const url = `${siteHostname}${path}`
      const title = pageData.title
        ? `${pageData.title} | stackwrangler`
        : 'stackwrangler'
      const description =
        pageData.description && pageData.description.length > 0
          ? pageData.description
          : siteDescription
      return [
        ['link', { rel: 'canonical', href: url }],
        ['meta', { property: 'og:url', content: url }],
        ['meta', { property: 'og:title', content: title }],
        ['meta', { property: 'og:description', content: description }],
        ['meta', { name: 'twitter:title', content: title }],
        ['meta', { name: 'twitter:description', content: description }],
      ]
    },
    themeConfig: {
      siteTitle: 'stackwrangler',
      nav: [
        { text: 'Home', link: '/' },
        { text: 'Why', link: '/guide/why' },
        { text: 'Getting Started', link: '/guide/getting-started' },
        { text: 'Vision', link: '/guide/vision' },
        { text: 'Completeness', link: '/guide/completeness' },
        { text: 'Console tour', link: '/guide/console-tour' },
        { text: 'Concepts', link: '/guide/concepts' },
        { text: 'Interactions', link: '/guide/interactions/' },
        { text: 'Changelog', link: '/guide/changelog' },
        {
          text: 'GitHub',
          link: 'https://github.com/kgz/stackwrangler',
        },
      ],
      sidebar: {
        '/guide/': [
          {
            text: 'Guide',
            items: [
              { text: 'Why', link: '/guide/why' },
              { text: 'Getting Started', link: '/guide/getting-started' },
              { text: 'Vision', link: '/guide/vision' },
              { text: 'Completeness / status', link: '/guide/completeness' },
              { text: 'Console tour', link: '/guide/console-tour' },
              { text: 'Concepts', link: '/guide/concepts' },
              { text: 'Interactions', link: '/guide/interactions/' },
              { text: 'Use cases', link: '/guide/use-cases/' },
              { text: 'Changelog', link: '/guide/changelog' },
            ],
          },
          {
            text: 'Compare',
            items: [
              { text: 'Index', link: '/guide/compare/' },
              { text: 'vs AWS Emulator', link: '/guide/compare/vs-aws-emulator' },
              { text: 'vs LocalEmu', link: '/guide/compare/vs-localemu' },
              { text: 'vs LocalStack', link: '/guide/compare/vs-localstack' },
              { text: 'vs Moto', link: '/guide/compare/vs-moto' },
              { text: 'vs real AWS', link: '/guide/compare/vs-real-aws' },
              {
                text: 'vs other free emulators',
                link: '/guide/compare/vs-other-emulators',
              },
            ],
          },
          {
            text: 'Use cases',
            items: [
              { text: 'Index', link: '/guide/use-cases/' },
              {
                text: 'OpenTofu → Expo + IAM',
                link: '/guide/use-cases/opentofu-expo-iam',
              },
              {
                text: 'Prowler / Steampipe',
                link: '/guide/use-cases/scanners-diagrammers',
              },
              {
                text: 'Org path (Transfer → RDS)',
                link: '/guide/use-cases/org-path',
              },
            ],
          },
          {
            text: 'Interactions',
            items: [
              { text: 'Catalog', link: '/guide/interactions/' },
              { text: 'SNS → SQS', link: '/guide/interactions/sns-to-sqs' },
              {
                text: 'EventBridge → Lambda',
                link: '/guide/interactions/events-to-lambda',
              },
              {
                text: 'API GW → NLB → ECS',
                link: '/guide/interactions/apigw-nlb-ecs',
              },
              {
                text: 'Lambda → Secrets → HTTP',
                link: '/guide/interactions/lambda-secrets-http',
              },
              {
                text: 'Transfer SFTP → S3',
                link: '/guide/interactions/transfer-sftp-s3',
              },
              { text: 'Dual S3', link: '/guide/interactions/dual-s3' },
              { text: 'IAM deny', link: '/guide/interactions/iam-deny' },
              {
                text: 'Lambda VPC → host',
                link: '/guide/interactions/lambda-vpc-host',
              },
              {
                text: 'SQS → Lambda',
                link: '/guide/interactions/sqs-to-lambda',
              },
              {
                text: 'ECS → ECR pull',
                link: '/guide/interactions/ecs-ecr-pull',
              },
              {
                text: 'SNS large topic',
                link: '/guide/interactions/sns-large-topic',
              },
              {
                text: 'Transfer connector',
                link: '/guide/interactions/transfer-connector',
              },
            ],
          },
        ],
      },
      socialLinks: [
        { icon: 'github', link: 'https://github.com/kgz/stackwrangler' },
      ],
      footer: {
        message:
          'Not affiliated with Amazon Web Services. Independent MIT-licensed OSS. · <a href="/llms.txt">llms.txt</a>',
        copyright: 'Copyright © stackwrangler contributors',
      },
      search: { provider: 'local' },
      editLink: {
        pattern:
          'https://github.com/kgz/stackwrangler/edit/main/docs-site/:path',
        text: 'Edit this page on GitHub',
      },
    },
    markdown: {
      theme: { light: 'github-light', dark: 'github-dark' },
      // Off: line gutters confuse copy-paste / crawler text extraction of bash fences.
      lineNumbers: false,
    },
    // mermaid@11 does `import dayjs from "dayjs"` against CJS dayjs.min.js — no default export for Vite.
    // Exact alias only (string find is a prefix and breaks dayjs/plugin/*).
    vite: {
      resolve: {
        alias: [{ find: /^dayjs$/, replacement: dayjsEsm }],
      },
      optimizeDeps: {
        include: ['dayjs', 'mermaid'],
      },
    },
    mermaid: {
      theme: 'neutral',
    },
  }),
)
