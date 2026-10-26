import react from '@vitejs/plugin-react'
import { fileURLToPath } from 'node:url'
import { defineConfig, loadEnv } from 'vite'
import { labelsPlugin } from './labelsPlugin.ts'

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '')
  const iamTarget = env.VITE_IAM_PROXY_TARGET || 'http://127.0.0.1:4566'

  return {
    plugins: [react(), labelsPlugin()],
    server: {
      host: '127.0.0.1',
      port: 3000,
      fs: { allow: [fileURLToPath(new URL('..', import.meta.url))] },
      proxy: {
        // Browser → same-origin; LocalEmu CORS blocks :3000 even with DISABLE_CORS_CHECKS
        '/aws-iam': {
          target: iamTarget,
          changeOrigin: true,
          rewrite: (path) => path.replace(/^\/aws-iam/, ''),
        },
      },
    },
  }
})
