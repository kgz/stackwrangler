import { useCallback, useEffect, useState } from 'react'
import type { Api } from '@aws-sdk/client-apigatewayv2'
import type { FunctionConfiguration } from '@aws-sdk/client-lambda'
import {
  browserInvokeUrl,
  createHttpApiForLambda,
  listHttpApis,
  localInvokeUrl,
} from '../lib/apigw'
import { listFunctions } from '../lib/lambda'

export function ApiGatewayPage() {
  const [apis, setApis] = useState<Api[]>([])
  const [fns, setFns] = useState<FunctionConfiguration[]>([])
  const [fnName, setFnName] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [toast, setToast] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [lastUrl, setLastUrl] = useState<string | null>(null)
  const [probe, setProbe] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setError(null)
    try {
      const [a, f] = await Promise.all([listHttpApis(), listFunctions()])
      setApis(a)
      setFns(f)
      setFnName((prev) => prev || f[0]?.FunctionName || '')
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    }
  }, [])

  useEffect(() => {
    void refresh()
  }, [refresh])

  async function onCreate() {
    if (!fnName) return
    setBusy(true)
    setError(null)
    setToast(null)
    setProbe(null)
    const name = `awsbox-http-${Date.now()}`
    try {
      const wired = await createHttpApiForLambda(name, fnName)
      setLastUrl(browserInvokeUrl(wired.apiId))
      setToast(`Created API ${wired.apiId} → ${fnName}`)
      await refresh()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  async function onProbe() {
    if (!lastUrl) return
    setBusy(true)
    setProbe(null)
    setError(null)
    try {
      const res = await fetch(lastUrl, { method: 'GET' })
      const text = await res.text()
      setProbe(`HTTP ${res.status}\n${text}`)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div>
      <h1>HTTP APIs</h1>
      <p className="page-lead">
        API Gateway HTTP API in front of a local Lambda. Create wires GET / to
        the selected function (AWS_PROXY).
      </p>

      {error ? <div className="error-banner">{error}</div> : null}
      {toast ? (
        <div className="toast-banner" role="status">
          {toast}
        </div>
      ) : null}

      <div className="toolbar toolbar-stack">
        <h3>APIs ({apis.length})</h3>
        <div className="toolbar-actions">
          <label className="field-inline">
            Lambda
            <select
              value={fnName}
              onChange={(e) => setFnName(e.target.value)}
              disabled={fns.length === 0}
            >
              {fns.length === 0 ? (
                <option value="">No functions</option>
              ) : (
                fns.map((f) => (
                  <option key={f.FunctionArn} value={f.FunctionName ?? ''}>
                    {f.FunctionName}
                  </option>
                ))
              )}
            </select>
          </label>
          <button type="button" className="btn" onClick={() => void refresh()}>
            Refresh
          </button>
          <button
            type="button"
            className="btn btn-primary"
            disabled={busy || !fnName}
            onClick={() => void onCreate()}
          >
            {busy ? 'Working…' : 'Create HTTP API → Lambda'}
          </button>
        </div>
      </div>

      {apis.length === 0 ? (
        <p className="empty-state">No HTTP APIs</p>
      ) : (
        <table className="data-table">
          <thead>
            <tr>
              <th>Name</th>
              <th>API ID</th>
              <th>Invoke URL</th>
            </tr>
          </thead>
          <tbody>
            {apis.map((a) => {
              const id = a.ApiId ?? ''
              return (
                <tr key={id}>
                  <td>{a.Name}</td>
                  <td>
                    <code>{id}</code>
                  </td>
                  <td>
                    <code>{localInvokeUrl(id)}</code>
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      )}

      {lastUrl ? (
        <div className="invoke-panel">
          <h3>Last created invoke URL</h3>
          <p>
            <code>{lastUrl}</code>
          </p>
          <button
            type="button"
            className="btn"
            disabled={busy}
            onClick={() => void onProbe()}
          >
            GET invoke URL
          </button>
          {probe ? <pre className="lab-detail">{probe}</pre> : null}
        </div>
      ) : null}
    </div>
  )
}
