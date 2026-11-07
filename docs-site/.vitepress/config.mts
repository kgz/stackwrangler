import { createRequire } from 'node:module'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vitepress'
import { withMermaid } from 'vitepress-plugin-mermaid'

// Hosted: https://kgz.github.io/stackwrangler/
// Local `pnpm dev` / `pnpm preview` without the env → base `/` so you open http://127.0.0.1:5173/
// CI / Pages builds always use `/stackwrangler/` (GITHUB_PAGES=1 or CI=true).
const pages = process.env.GITHUB_PAGES === '1' || process.env.CI === 'true'
const require = createRequire(import.meta.url)
const dayjsRoot = path.dirname(require.resolve('dayjs/package.json'))
const dayjsEsm = path.join(dayjsRoot, 'esm/index.js')
const vitepressDir = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(vitepressDir, '../..')


export default withMermaid(
  defineConfig({
    title: 'stackwrangler',
    description:
      'Local AWS-shaped account for real APIs, console, and IaC — then deploy to real AWS',
    base: pages ? '/stackwrangler/' : '/',
    appearance: 'dark',
    ignoreDeadLinks: true,
    lastUpdated: true,
    srcExclude: ['README.md'],
    head: [
      [
        'link',
        {
          rel: 'icon',
          type: 'image/svg+xml',
          href: pages ? '/stackwrangler/mark.svg' : '/mark.svg',
        },
      ],
    ],
    themeConfig: {
      siteTitle: 'stackwrangler',
      logo: { src: '/mark.svg', alt: 'stackwrangler' },
      nav: [
        { text: 'Why', link: '/guide/why' },
        { text: 'Guide', link: '/guide/getting-started' },
        { text: 'Changelog', link: '/guide/changelog' },
        { text: 'Completeness', link: '/guide/completeness' },
        { text: 'Interactions', link: '/guide/interactions/' },
        {
          text: 'GitHub',
          link: 'https://github.com/kgz/stackwrangler',
        },
      ],
      sidebar: {
        '/guide/': [
          {
            text: 'Start here',
            items: [
              { text: 'Why', link: '/guide/why' },
              { text: 'Getting Started', link: '/guide/getting-started' },
              { text: 'Vision', link: '/guide/vision' },
              { text: 'Changelog', link: '/guide/changelog' },
              { text: 'Completeness / status', link: '/guide/completeness' },
            ],
          },
          {
            text: 'Product',
            items: [
              { text: 'Console tour', link: '/guide/console-tour' },
              { text: 'Concepts', link: '/guide/concepts' },
              { text: 'Interactions', link: '/guide/interactions/' },
              { text: 'Changelog', link: '/guide/changelog' },
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
              {
                text: 'RDS Create → SQL',
                link: '/guide/interactions/rds-create-sql',
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
          'MIT · Not affiliated with Amazon Web Services · Independent OSS · <a href="https://kgz.github.io/stackwrangler/">Docs</a> · <a href="https://github.com/kgz/stackwrangler">GitHub</a>',
        copyright:
          'Copyright © stackwrangler contributors · Run docs locally: cd docs-site && pnpm install && pnpm dev',
      },
      search: { provider: 'local' },
      editLink: {
        pattern:
          'https://github.com/kgz/stackwrangler/edit/main/docs-site/:path',
        text: 'Edit this page on GitHub',
      },
      outline: { level: [2, 3] },
    },
    markdown: {
      theme: { light: 'github-light', dark: 'github-dark' },
      lineNumbers: true,
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
      // theme imports design/stackwrangler/tokens.css outside docs-site/
      server: {
        fs: { allow: [repoRoot] },
      },
    },

    mermaid: {
      theme: 'dark',
      themeVariables: {
        primaryColor: '#2a2428',
        primaryTextColor: '#ececec',
        primaryBorderColor: '#b48aa0',
        lineColor: '#8d8d8d',
        secondaryColor: '#242424',
        tertiaryColor: '#1c1c1c',
      },
    },
  }),
)
