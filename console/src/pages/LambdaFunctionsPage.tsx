import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { FunctionConfiguration } from '@aws-sdk/client-lambda'
import {
  createHelloFunction,
  deployZip,
  invokeFunction,
  listFunctions,
  readFileAsBytes,
  type InvokeResult,
} from '../lib/lambda'
import { Link } from 'react-router-dom'
import { ResourceLabel } from '../components/ResourceLabel'
import { DeadButton, RefreshButton } from '../components/S3Ui'
import {
  EmptyRow,
  FilterHeader,
  ListCard,
  Notices,
  SelectCell,
  SelectHeader,
  SortHeader,
} from '../components/ServiceUi'
import { formatServiceDate } from '../lib/format'

export function LambdaFunctionsPage() {
  const [fns, setFns] = useState<FunctionConfiguration[]>([])
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [selected, setSelected] = useState<string | null>(null)
  const [invokeOut, setInvokeOut] = useState<InvokeResult | null>(null)
  const [toast, setToast] = useState<string | null>(null)
  const [deployName, setDeployName] = useState('')
  const [filter, setFilter] = useState('')
  const fileRef = useRef<HTMLInputElement>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const list = await listFunctions()
      setFns(list)
      setSelected((prev) =>
        prev && list.some((f) => f.FunctionName === prev) ? prev : null,
      )
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    void refresh()
  }, [refresh])

  const filtered = useMemo(() => {
    const q = filter.trim().toLowerCase()
    if (!q) return fns
    return fns.filter(
      (f) =>
        (f.FunctionName ?? '').toLowerCase().includes(q) ||
        (f.FunctionArn ?? '').toLowerCase().includes(q),
    )
  }, [fns, filter])

  function toggle(id: string) {
    setSelected((cur) => (cur === id ? null : id))
  }

  async function onCreateHello() {
    setBusy(true)
    setError(null)
    setToast(null)
    const name = `stackwrangler-hello-${Date.now()}`
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
    const name = deployName.trim() || selected || `stackwrangler-deploy-${Date.now()}`
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
    <>
      <ListCard
        title="Functions"
        desc={
          <>
            Lambda lets you run code without provisioning or managing servers.
            Logs: <Link to="/logs">CloudWatch Logs</Link>.
          </>
        }
        notices={<Notices error={error} toast={toast} />}
        toolbar={
          <>
            <RefreshButton onClick={() => void refresh()} />
            <button
              type="button"
              className="btn btn-normal"
              disabled={busy || !selected}
              title={selected ? undefined : 'Select a row'}
              onClick={() => void onInvoke()}
            >
              Invoke
            </button>
            <DeadButton>Actions ▾</DeadButton>
            <button
              type="button"
              className="btn btn-normal"
              disabled={busy}
              onClick={() => void onCreateHello()}
            >
              {busy ? 'Working…' : 'Create hello function'}
            </button>
            <div className="spacer" />
            <Link className="btn btn-primary" to="/lambda/create">
              Create function
            </Link>
          </>
        }
        placeholder="Filter by function name or ARN"
        filter={filter}
        onFilter={setFilter}
      >
        <table className="aws-table" data-testid="lambda-functions-table">
          <thead>
            <tr>
              <SelectHeader />
              <SortHeader>Function name</SortHeader>
              <FilterHeader>Description</FilterHeader>
              <FilterHeader>Package type</FilterHeader>
              <FilterHeader>Runtime</FilterHeader>
              <SortHeader>Last modified</SortHeader>
            </tr>
          </thead>
          <tbody>
            {filtered.length === 0 ? (
              <EmptyRow
                colSpan={6}
                loading={loading}
                loadingText="Loading functions…"
                title="No functions"
                text="You do not have any Lambda functions in this region."
              />
            ) : (
              filtered.map((fn) => {
                const name = fn.FunctionName ?? ''
                const isSelected = selected === name
                return (
                  <tr
                    key={fn.FunctionArn ?? name}
                    className={`selectable${isSelected ? ' selected' : ''}`}
                    onClick={() => toggle(name)}
                  >
                    <SelectCell
                      name="selected-fn"
                      id={name}
                      selected={isSelected}
                      onToggle={toggle}
                    />
                    <td>
                      <ResourceLabel ids={[name, fn.FunctionArn]}>
                        <Link
                          to={`/lambda/functions/${encodeURIComponent(name)}`}
                          onClick={(e) => e.stopPropagation()}
                        >
                          {name}
                        </Link>
                      </ResourceLabel>
                    </td>
                    <td>{fn.Description || '—'}</td>
                    <td>{fn.PackageType ?? '—'}</td>
                    <td>{fn.Runtime ?? '—'}</td>
                    <td>{formatServiceDate(fn.LastModified)}</td>
                  </tr>
                )
              })
            )}
          </tbody>
        </table>
      </ListCard>

      <section className="aws-card" style={{ marginTop: 16 }}>
        <div className="aws-card-body">
          <h2 className="aws-section-title">Deploy from zip</h2>
          <p className="aws-desc">
            Node zip with <code>index.js</code> exporting <code>handler</code>.
            Uses selected name, or the name field, or creates a new one.
          </p>
          <div className="aws-toolbar">
            <label className="field-inline">
              Function name
              <input
                type="text"
                value={deployName}
                placeholder={selected ?? 'stackwrangler-deploy-…'}
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
      </section>

      {invokeOut ? (
        <section className="aws-card" style={{ marginTop: 16 }}>
          <div className="aws-card-body">
            <h2 className="aws-section-title">Invoke result</h2>
            <p>
              StatusCode: <code>{invokeOut.statusCode}</code>
            </p>
            <pre className="lab-detail">{invokeOut.payloadText}</pre>
          </div>
        </section>
      ) : null}
    </>
  )
}
