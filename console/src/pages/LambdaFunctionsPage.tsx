import { useCallback, useEffect, useState } from 'react'
import type { FunctionConfiguration } from '@aws-sdk/client-lambda'
import {
  createHelloFunction,
  invokeFunction,
  listFunctions,
  type InvokeResult,
} from '../lib/lambda'

export function LambdaFunctionsPage() {
  const [fns, setFns] = useState<FunctionConfiguration[]>([])
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [selected, setSelected] = useState<string | null>(null)
  const [invokeOut, setInvokeOut] = useState<InvokeResult | null>(null)
  const [toast, setToast] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const list = await listFunctions()
      setFns(list)
      setSelected((prev) => prev ?? list[0]?.FunctionName ?? null)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    void refresh()
  }, [refresh])

  async function onCreateHello() {
    setBusy(true)
    setError(null)
    setToast(null)
    const name = `awsbox-hello-${Date.now()}`
    try {
      await createHelloFunction(name)
      setSelected(name)
      setToast(`Created function ${name}`)
      await refresh()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  async function onInvoke() {
    if (!selected) return
    setBusy(true)
    setError(null)
    setInvokeOut(null)
    try {
      const result = await invokeFunction(selected, { ping: true })
      setInvokeOut(result)
      if (result.statusCode >= 200 && result.statusCode < 300) {
        setToast(`Invoked ${selected}`)
      } else {
        setError(`Invoke status ${result.statusCode}: ${result.payloadText}`)
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div>
      <h1>Functions</h1>
      <p className="page-lead">
        Lambda on the local emulator (Docker runtimes). Create a hello Node
        function, then invoke it.
      </p>

      {error ? <div className="error-banner">{error}</div> : null}
      {toast ? (
        <div className="toast-banner" role="status">
          {toast}
        </div>
      ) : null}

      <div className="toolbar toolbar-stack">
        <h3>Functions ({fns.length})</h3>
        <div className="toolbar-actions">
          <button type="button" className="btn" onClick={() => void refresh()}>
            Refresh
          </button>
          <button
            type="button"
            className="btn"
            disabled={busy || !selected}
            onClick={() => void onInvoke()}
          >
            Invoke
          </button>
          <button
            type="button"
            className="btn btn-primary"
            disabled={busy}
            onClick={() => void onCreateHello()}
          >
            {busy ? 'Working…' : 'Create hello function'}
          </button>
        </div>
      </div>

      {loading ? (
        <p>Loading…</p>
      ) : fns.length === 0 ? (
        <p className="empty-state">No functions</p>
      ) : (
        <table className="data-table">
          <thead>
            <tr>
              <th />
              <th>Function name</th>
              <th>Runtime</th>
              <th>Handler</th>
            </tr>
          </thead>
          <tbody>
            {fns.map((fn) => {
              const name = fn.FunctionName ?? ''
              return (
                <tr
                  key={fn.FunctionArn ?? name}
                  className={selected === name ? 'row-selected' : undefined}
                >
                  <td>
                    <input
                      type="radio"
                      name="fn"
                      checked={selected === name}
                      aria-label={`Select ${name}`}
                      onChange={() => setSelected(name)}
                    />
                  </td>
                  <td>{name}</td>
                  <td>{fn.Runtime ?? '—'}</td>
                  <td>{fn.Handler ?? '—'}</td>
                </tr>
              )
            })}
          </tbody>
        </table>
      )}

      {invokeOut ? (
        <div className="invoke-panel">
          <h3>Invoke result</h3>
          <p>
            StatusCode: <code>{invokeOut.statusCode}</code>
          </p>
          <pre className="lab-detail">{invokeOut.payloadText}</pre>
        </div>
      ) : null}
    </div>
  )
}
