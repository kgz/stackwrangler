import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import type { RestApi } from '@aws-sdk/client-api-gateway'
import { ResourceLabel } from '../components/ResourceLabel'
import { RefreshButton, TableTools } from '../components/S3Ui'
import {
  EmptyRow,
  FilterHeader,
  Mono,
  Notices,
  SelectCell,
  SelectHeader,
  SortHeader,
} from '../components/ServiceUi'
import { formatServiceDate } from '../lib/format'
import {
  deleteRestApi,
  listRestApis,
  restListEndpoint,
} from '../lib/apigwRest'
import { ApiGatewayTypeTabs } from '../components/ApiGatewayTypeTabs'

export function ApiGatewayRestApisPage() {
  const [apis, setApis] = useState<RestApi[]>([])
  const [filter, setFilter] = useState('')
  const [selected, setSelected] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [confirmDelete, setConfirmDelete] = useState(false)
  const [busy, setBusy] = useState(false)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const list = await listRestApis()
      setApis(list)
      setSelected((prev) =>
        prev && list.some((a) => a.id === prev) ? prev : null,
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
    if (!q) return apis
    return apis.filter(
      (a) =>
        (a.name ?? '').toLowerCase().includes(q) ||
        (a.id ?? '').toLowerCase().includes(q) ||
        (a.description ?? '').toLowerCase().includes(q),
    )
  }, [apis, filter])

  function toggle(id: string) {
    setSelected((cur) => (cur === id ? null : id))
  }

  async function onDelete() {
    if (!selected) return
    setBusy(true)
    setError(null)
    try {
      await deleteRestApi(selected)
      setConfirmDelete(false)
      setSelected(null)
      await refresh()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
      setConfirmDelete(false)
    } finally {
      setBusy(false)
    }
  }

  const selectedName =
    apis.find((a) => a.id === selected)?.name ?? selected ?? ''

  return (
    <>
      <h1 className="aws-h1">APIs</h1>
      <Notices error={error} />
      <section className="aws-card">
        <ApiGatewayTypeTabs active="rest" />
        <div className="aws-card-body">
          <p className="aws-desc">
            REST APIs offer more features than HTTP APIs, including API keys,
            request validation, AWS WAF integration, and private integrations.
          </p>
          <div className="aws-toolbar">
            <RefreshButton onClick={() => void refresh()} disabled={loading} />
            <button
              type="button"
              className="btn btn-normal"
              disabled={!selected || busy}
              title={selected ? undefined : 'Select a row'}
              onClick={() => setConfirmDelete(true)}
            >
              Delete
            </button>
            <div className="spacer" />
            <Link className="btn btn-primary" to="/apigateway/rest-apis/create">
              Create
            </Link>
          </div>
          <TableTools
            placeholder="Search APIs"
            value={filter}
            onChange={setFilter}
          />
          <div className="aws-table-wrap">
            <table className="aws-table" data-testid="rest-apis-table">
              <thead>
                <tr>
                  <SelectHeader />
                  <SortHeader>Name</SortHeader>
                  <FilterHeader>API ID</FilterHeader>
                  <FilterHeader>Description</FilterHeader>
                  <SortHeader>Created date</SortHeader>
                  <FilterHeader>Protocol</FilterHeader>
                  <FilterHeader>Endpoint</FilterHeader>
                </tr>
              </thead>
              <tbody>
                {filtered.length === 0 ? (
                  <EmptyRow
                    colSpan={7}
                    loading={loading}
                    loadingText="Loading REST APIs…"
                    title="No REST APIs"
                    text="You do not have any REST APIs in this region."
                  />
                ) : (
                  filtered.map((a) => {
                    const id = a.id ?? ''
                    const name = a.name ?? id
                    const isSelected = selected === id
                    return (
                      <tr
                        key={id}
                        className={`selectable${isSelected ? ' selected' : ''}`}
                        onClick={() => toggle(id)}
                      >
                        <SelectCell
                          name="selected-rest-api"
                          id={id}
                          selected={isSelected}
                          onToggle={toggle}
                        />
                        <td>
                          <ResourceLabel ids={[name, id]} detail={isSelected}>
                            <Link
                              to={`/apigateway/rest-apis/${encodeURIComponent(id)}`}
                              onClick={(e) => e.stopPropagation()}
                            >
                              {name}
                            </Link>
                          </ResourceLabel>
                        </td>
                        <td>
                          <Mono>{id}</Mono>
                        </td>
                        <td>{a.description?.trim() ? a.description : '—'}</td>
                        <td>{formatServiceDate(a.createdDate)}</td>
                        <td>REST</td>
                        <td>
                          <Mono>{restListEndpoint(id)}</Mono>
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

      {confirmDelete && selected ? (
        <div className="modal-backdrop">
          <div className="modal" data-testid="rest-api-delete-modal">
            <h3>Delete API?</h3>
            <p style={{ color: 'var(--awsbox-quiet)', marginTop: 0 }}>
              Permanently delete <strong>{selectedName}</strong> ({selected}) and
              its resources, methods, and stages.
            </p>
            <div className="modal-actions">
              <button
                type="button"
                className="btn btn-normal"
                disabled={busy}
                onClick={() => setConfirmDelete(false)}
              >
                Cancel
              </button>
              <button
                type="button"
                className="btn btn-primary"
                disabled={busy}
                onClick={() => void onDelete()}
                data-testid="rest-api-delete-confirm"
              >
                {busy ? 'Deleting…' : 'Delete'}
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </>
  )
}
