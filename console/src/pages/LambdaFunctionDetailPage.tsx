import { useCallback, useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import type { FunctionConfiguration } from '@aws-sdk/client-lambda'
import { MonacoEditor } from '../components/MonacoEditor'
import { ResourceLabel } from '../components/ResourceLabel'
import { DeadButton, RefreshButton } from '../components/S3Ui'
import { Kv, Mono, Notices, StatusBadge } from '../components/ServiceUi'
import { formatServiceDate } from '../lib/format'
import { lambdaLogGroupName } from '../lib/logs'
import {
  getFunction,
  getFunctionSource,
  invokeFunction,
  updateFunctionSource,
  type InvokeResult,
} from '../lib/lambda'

type DetailTab = 'overview' | 'code'

export function LambdaFunctionDetailPage() {
  const { name: rawName } = useParams()
  const name = rawName ? decodeURIComponent(rawName) : ''
  const [tab, setTab] = useState<DetailTab>('overview')
  const [fn, setFn] = useState<FunctionConfiguration | null>(null)
  const [filename, setFilename] = useState('index.js')
  const [source, setSource] = useState('')
  const [language, setLanguage] = useState('javascript')
  const [sourceLoaded, setSourceLoaded] = useState(false)
  const [dirty, setDirty] = useState(false)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [toast, setToast] = useState<string | null>(null)
  const [invokeOut, setInvokeOut] = useState<InvokeResult | null>(null)

  const refreshMeta = useCallback(async () => {
    if (!name) return
    setLoading(true)
    setError(null)
    try {
      const cfg = await getFunction(name)
      setFn(cfg)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [name])

  const loadSource = useCallback(async () => {
    if (!name) return
    setBusy(true)
    setError(null)
    try {
      const src = await getFunctionSource(name)
      setFilename(src.filename)
      setSource(src.source)
      setLanguage(src.language)
      setDirty(false)
      setSourceLoaded(true)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }, [name])

  useEffect(() => {
    void refreshMeta()
  }, [refreshMeta])

  useEffect(() => {
    if (tab === 'code' && !sourceLoaded) {
      void loadSource()
    }
  }, [tab, sourceLoaded, loadSource])

  async function onDeploy() {
    if (!name) return
    setBusy(true)
    setError(null)
    setToast(null)
    try {
      const cfg = await updateFunctionSource(name, filename, source)
      setFn(cfg)
      setDirty(false)
      setToast(`Deployed ${filename} to ${name}`)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  async function onTest() {
    if (!name) return
    setBusy(true)
    setError(null)
    setInvokeOut(null)
    try {
      const result = await invokeFunction(name, { ping: true })
      setInvokeOut(result)
      if (result.statusCode >= 200 && result.statusCode < 300) {
        setToast(`Invoked ${name}`)
      } else {
        setError(`Invoke status ${result.statusCode}: ${result.payloadText}`)
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  if (!name) {
    return <p className="aws-desc">Missing function name.</p>
  }

  const arch = fn?.Architectures?.[0] ?? 'x86_64'
  const roleName = (fn?.Role ?? '').split('/').pop() || '—'

  return (
    <>
      <div className="aws-toolbar">
        <div style={{ flex: 1, minWidth: 0 }}>
          <h1 className="aws-h1" style={{ margin: 0 }}>
            <ResourceLabel ids={[name, fn?.FunctionArn]} detail>
              {name}
            </ResourceLabel>
          </h1>
          {fn ? (
            <div className="aws-subtitle-row">
              <StatusBadge status={fn.State ?? 'Active'} />
              <span>
                {fn.Runtime ?? '—'} · {fn.PackageType ?? 'Zip'} · {arch}
              </span>
              <span>Last modified {formatServiceDate(fn.LastModified)}</span>
            </div>
          ) : null}
        </div>
        <RefreshButton
          onClick={() => {
            setSourceLoaded(false)
            void refreshMeta()
          }}
        />
        <button
          type="button"
          className="btn btn-normal"
          disabled={busy}
          onClick={() => void onTest()}
        >
          Test
        </button>
        <DeadButton>Actions ▾</DeadButton>
      </div>

      <Notices error={error} toast={toast} />

      <section className="aws-card">
        <div className="aws-tabs" role="tablist">
          <button
            type="button"
            className={`aws-tab${tab === 'overview' ? ' active' : ''}`}
            aria-current={tab === 'overview' ? 'page' : undefined}
            onClick={() => setTab('overview')}
          >
            Overview
          </button>
          <button
            type="button"
            className={`aws-tab${tab === 'code' ? ' active' : ''}`}
            aria-current={tab === 'code' ? 'page' : undefined}
            onClick={() => setTab('code')}
            data-testid="lambda-tab-code"
          >
            Code
          </button>
          <button
            type="button"
            className="aws-tab"
            disabled
            aria-disabled="true"
            title="To implement"
          >
            Permissions
          </button>
          <button
            type="button"
            className="aws-tab"
            disabled
            aria-disabled="true"
            title="To implement"
          >
            Monitor
          </button>
        </div>
        <div className="aws-card-body">
          {loading && tab === 'overview' ? (
            <p className="aws-desc">Loading…</p>
          ) : null}

          {tab === 'overview' && fn ? (
            <>
              <h2 className="aws-section-title">Function overview</h2>
              <Kv
                rows={[
                  [
                    'Function ARN',
                    <Mono key="arn">{fn.FunctionArn ?? '—'}</Mono>,
                  ],
                  ['Runtime', fn.Runtime ?? '—'],
                  [
                    'Handler',
                    <Mono key="handler">{fn.Handler ?? '—'}</Mono>,
                  ],
                  ['Architecture', arch],
                  ['Package type', fn.PackageType ?? 'Zip'],
                  [
                    'Execution role',
                    <Mono key="role">{roleName}</Mono>,
                  ],
                  ['Memory', fn.MemorySize ? `${fn.MemorySize} MB` : '—'],
                  ['Timeout', fn.Timeout ? `${fn.Timeout} sec` : '—'],
                  ['Description', fn.Description || '—'],
                  [
                    'Log group',
                    <Link key="logs" to="/logs">
                      <Mono>{lambdaLogGroupName(name)}</Mono>
                    </Link>,
                  ],
                ]}
              />
            </>
          ) : null}

          {tab === 'code' ? (
            <>
              <div className="aws-code-toolbar">
                <span className="file-tab">{filename}</span>
                <div className="spacer" style={{ flex: 1 }} />
                <button
                  type="button"
                  className="btn btn-normal"
                  disabled={busy || !sourceLoaded || !dirty}
                  onClick={() => void onDeploy()}
                >
                  Save
                </button>
                <button
                  type="button"
                  className="btn btn-primary"
                  disabled={busy || !sourceLoaded}
                  onClick={() => void onDeploy()}
                  data-testid="lambda-deploy-code"
                >
                  {busy ? 'Working…' : 'Deploy'}
                </button>
                <button
                  type="button"
                  className="btn btn-normal"
                  disabled={busy}
                  onClick={() => void onTest()}
                >
                  Test
                </button>
              </div>
              {sourceLoaded ? (
                <MonacoEditor
                  path={filename}
                  language={language}
                  value={source}
                  onChange={(next) => {
                    setSource(next)
                    setDirty(true)
                  }}
                />
              ) : (
                <p className="aws-desc">
                  {busy ? 'Loading source…' : 'Open Code to load the package.'}
                </p>
              )}
              <p className="aws-hint" style={{ marginTop: 10 }}>
                Runtime settings · Handler{' '}
                <Mono>{fn?.Handler ?? 'index.handler'}</Mono>
                {dirty ? ' · Unsaved edits' : null}
              </p>
            </>
          ) : null}
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
