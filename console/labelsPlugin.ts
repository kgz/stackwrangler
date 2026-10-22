import type { IncomingMessage, ServerResponse } from 'node:http'
import type { Plugin } from 'vite'
import { loadLabelEntries } from './labelsFile.ts'

function sendJson(res: ServerResponse, status: number, body: unknown): void {
  res.statusCode = status
  res.setHeader('content-type', 'application/json; charset=utf-8')
  res.setHeader('cache-control', 'no-store')
  res.end(JSON.stringify(body))
}

function labelsMiddleware(
  req: IncomingMessage,
  res: ServerResponse,
  next: (err?: unknown) => void,
): void {
  const pathOnly = (req.url ?? '').split('?')[0]
  if (pathOnly !== '/_awsl/labels') {
    next()
    return
  }
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.statusCode = 405
    res.setHeader('allow', 'GET, HEAD')
    res.end()
    return
  }
  try {
    const entries = loadLabelEntries()
    if (req.method === 'HEAD') {
      res.statusCode = 200
      res.setHeader('content-type', 'application/json; charset=utf-8')
      res.setHeader('cache-control', 'no-store')
      res.end()
      return
    }
    sendJson(res, 200, { entries })
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    sendJson(res, 400, { error: message })
  }
}

export function labelsPlugin(): Plugin {
  return {
    name: 'awsbox-labels',
    configureServer(server) {
      server.middlewares.use(labelsMiddleware)
    },
    configurePreviewServer(server) {
      server.middlewares.use(labelsMiddleware)
    },
  }
}
