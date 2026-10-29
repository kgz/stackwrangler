import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Api } from '@aws-sdk/client-apigatewayv2'
import type { FunctionConfiguration } from '@aws-sdk/client-lambda'
import {
  browserInvokeUrl,
  createHttpApiForLambda,
  listHttpApis,
  localInvokeUrl,
} from '../lib/apigw'
import { listFunctions } from '../lib/lambda'
import { ResourceLabel } from '../components/ResourceLabel'
import { DeadButton, RefreshButton, TableTools } from '../components/S3Ui'
import {
  DeadLink,
  EmptyRow,
  FilterHeader,
  Mono,
  Notices,
  SelectCell,
  SelectHeader,
  SortHeader,
} from '../components/ServiceUi'
import { formatServiceDate } from '../lib/format'

export function ApiGatewayPage() {
  const [apis, setApis] = useState<Api[]>([])
  const [fns, setFns] = useState<FunctionConfiguration[]>([])
  const [fnName, setFnName] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [toast, setToast] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [lastUrl, setLastUrl] = useState<string | null>(null)
  const [probe, setProbe] = useState<string | null>(null)
  const [filter, setFilter] = useState('')
  const [selected, setSelected] = useState<string | null>(null)

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

  const filtered = useMemo(() => {
    const q = filter.trim().toLowerCase()
    if (!q) return apis
    return apis.filter(
      (a) =>
        (a.Name ?? '').toLowerCase().includes(q) ||
        (a.ApiId ?? '').toLowerCase().includes(q),
    )
  }, [apis, filter])

  function toggle(id: string) {
    setSelected((cur) => (cur === id ? null : id))
  }

  async function onCreate() {
    if (!fnName) return
    setBusy(true)
    setError(null)
    setToast(null)
    setProbe(null)
    const name = `stackwrangler-http-${Date.now()}`
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
    <>
      <h1 className="aws-h1">APIs</h1>
      <Notices error={error} toast={toast} />
      <section className="aws-card">
        <div className="aws-tabs" role="tablist">
          <span className="aws-tab active" aria-current="page">
            HTTP APIs
          </span>
        </div>
        <div className="aws-card-body">
          <p className="aws-desc">
            HTTP APIs enable you to create RESTful APIs with lower latency and
            cost.
          </p>
          <div className="aws-toolbar">
            <RefreshButton onClick={() => void refresh()} />
            <DeadButton>Delete</DeadButton>
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
            <button
              type="button"
              className="btn btn-normal"
              disabled={busy || !fnName}
              title={fnName ? undefined : 'Create a Lambda function first'}
              onClick={() => void onCreate()}
            >
              {busy ? 'Working…' : 'Create HTTP API → Lambda'}
            </button>
            <div className="spacer" />
            <DeadButton variant="primary">Create</DeadButton>
          </div>
          <TableTools
            placeholder="Search APIs"
            value={filter}
            onChange={setFilter}
          />
          <div className="aws-table-wrap">
            <table className="aws-table" data-testid="http-apis-table">
              <thead>
                <tr>
                  <SelectHeader />
                  <SortHeader>Name</SortHeader>
                  <FilterHeader>API ID</FilterHeader>
                  <FilterHeader>Description</FilterHeader>
                  <SortHeader>Created date</SortHeader>
                  <FilterHeader>Endpoint</FilterHeader>
                </tr>
              </thead>
              <tbody>
                {filtered.length === 0 ? (
                  <EmptyRow
                    colSpan={6}
                    loading={false}
                    loadingText=""
                    title="No HTTP APIs"
                    text="You do not have any HTTP APIs in this region."
                  />
                ) : (
                  filtered.map((a) => {
                    const id = a.ApiId ?? ''
                    const isSelected = selected === id
                    return (
                      <tr
                        key={id}
                        className={`selectable${isSelected ? ' selected' : ''}`}
                        onClick={() => toggle(id)}
                      >
                        <SelectCell
                          name="selected-api"
                          id={id}
                          selected={isSelected}
                          onToggle={toggle}
                        />
                        <td>
                          <DeadLink>{a.Name ?? '—'}</DeadLink>
                        </td>
                        <td>
                          <ResourceLabel ids={[id, a.ApiEndpoint]}>
                            <Mono>{id}</Mono>
                          </ResourceLabel>
                        </td>
                        <td>{a.Description || '—'}</td>
                        <td>{formatServiceDate(a.CreatedDate)}</td>
                        <td>
                          <Mono>{localInvokeUrl(id)}</Mono>
                        </td>
                      </tr>
                    )
                  })
                )}
              </tbody>
            </table>
          </div>
        </div>
      </section>

      {lastUrl ? (
        <section className="aws-card" style={{ marginTop: 16 }}>
          <div className="aws-card-body">
            <h2 className="aws-section-title">Last created invoke URL</h2>
            <p>
              <code>{lastUrl}</code>
            </p>
            <button
              type="button"
              className="btn btn-normal"
              disabled={busy}
              onClick={() => void onProbe()}
            >
              GET invoke URL
            </button>
            {probe ? <pre className="lab-detail">{probe}</pre> : null}
          </div>
        </section>
      ) : null}
    </>
  )
}
