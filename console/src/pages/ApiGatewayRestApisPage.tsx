import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import type { RestApi } from '@aws-sdk/client-api-gateway'
import { ResourceLabel } from '../components/ResourceLabel'
import { DeadButton, RefreshButton, TableTools } from '../components/S3Ui'
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
import { listRestApis, restListEndpoint } from '../lib/apigwRest'
import { ApiGatewayTypeTabs } from '../components/ApiGatewayTypeTabs'

export function ApiGatewayRestApisPage() {
  const [apis, setApis] = useState<RestApi[]>([])
  const [filter, setFilter] = useState('')
  const [selected, setSelected] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

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
            <RefreshButton />
            <DeadButton title={selected ? 'To implement' : 'Select a row'}>
              Delete
            </DeadButton>
            <div className="spacer" />
            <DeadButton variant="primary">Create</DeadButton>
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
    </>
  )
}
