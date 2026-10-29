import { defineConfig } from 'vitepress'
import { withMermaid } from 'vitepress-plugin-mermaid'

// GitHub Pages: https://kgz.github.io/stackwrangler/
export default withMermaid(
  defineConfig({
    title: 'stackwrangler',
    description:
      'Local AWS-shaped account for real APIs, console, and IaC — then deploy to real AWS',
    base: '/stackwrangler/',
    ignoreDeadLinks: true,
    lastUpdated: true,
    themeConfig: {
      siteTitle: 'stackwrangler',
      nav: [
        { text: 'Home', link: '/' },
        { text: 'Getting Started', link: '/guide/getting-started' },
        { text: 'Vision', link: '/guide/vision' },
        { text: 'Completeness', link: '/guide/completeness' },
        { text: 'Console tour', link: '/guide/console-tour' },
        { text: 'Concepts', link: '/guide/concepts' },
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
              { text: 'Getting Started', link: '/guide/getting-started' },
              { text: 'Vision', link: '/guide/vision' },
              { text: 'Completeness / status', link: '/guide/completeness' },
              { text: 'Console tour', link: '/guide/console-tour' },
              { text: 'Concepts', link: '/guide/concepts' },
              { text: 'Publishing (GitHub Pages)', link: '/guide/github-pages' },
            ],
          },
        ],
      },
      socialLinks: [
        { icon: 'github', link: 'https://github.com/kgz/stackwrangler' },
      ],
      footer: {
        message:
          'Not affiliated with Amazon Web Services. Independent MIT-licensed OSS.',
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
      lineNumbers: true,
    },
    mermaid: {
      theme: 'neutral',
    },
  }),
)
