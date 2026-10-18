import { useCallback, useEffect, useRef, useState } from 'react'
import type { FunctionConfiguration } from '@aws-sdk/client-lambda'
import {
  createHelloFunction,
  deployZip,
  invokeFunction,
  listFunctions,
  readFileAsBytes,
  type InvokeResult,
} from '../lib/lambda'
import { lambdaLogGroupName } from '../lib/logs'
import { Link } from 'react-router-dom'

export function LambdaFunctionsPage() {
  const [fns, setFns] = useState<FunctionConfiguration[]>([])
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [selected, setSelected] = useState<string | null>(null)
  const [invokeOut, setInvokeOut] = useState<InvokeResult | null>(null)
  const [toast, setToast] = useState<string | null>(null)
  const [deployName, setDeployName] = useState('')
  const fileRef = useRef<HTMLInputElement>(null)

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

  async function onDeployZip(file: File) {
    const name = deployName.trim() || selected || `awsbox-deploy-${Date.now()}`
    setBusy(true)
    setError(null)
    setToast(null)
    try {
      const bytes = await readFileAsBytes(file)
      await deployZip(name, bytes)
      setSelected(name)
      setDeployName(name)
      setToast(`Deployed zip to ${name}`)
      await refresh()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
      if (fileRef.current) {
        fileRef.current.value = ''
      }
    }
  }

  return (
    <div>
      <h1>Functions</h1>
      <p className="page-lead">
        Lambda on the local emulator. Create hello, deploy a zip (
        <code>index.handler</code>), or invoke. Logs:{' '}
        <Link to="/logs">CloudWatch Logs</Link>.
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

      <div className="deploy-panel">
        <h3>Deploy from zip</h3>
        <p className="page-lead">
          Node zip with <code>index.js</code> exporting <code>handler</code>.
          Uses selected name, or the name field, or creates a new one.
        </p>
        <div className="toolbar-actions">
          <label className="field-inline">
            Function name
            <input
              type="text"
              value={deployName}
              placeholder={selected ?? 'awsbox-deploy-…'}
              onChange={(e) => setDeployName(e.target.value)}
            />
          </label>
          <input
            ref={fileRef}
            type="file"
            accept=".zip,application/zip"
            aria-label="Lambda zip file"
            disabled={busy}
            onChange={(e) => {
              const file = e.target.files?.[0]
              if (file) void onDeployZip(file)
            }}
          />
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
              <th>Logs</th>
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
                  <td>
                    <Link to="/logs">{lambdaLogGroupName(name)}</Link>
                  </td>
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
