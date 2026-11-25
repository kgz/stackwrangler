import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { ResourceLabel } from '../components/ResourceLabel'
import { DeadButton, RefreshButton } from '../components/S3Ui'
import {
  EmptyRow,
  FilterHeader,
  ListCard,
  Mono,
  Notices,
  SelectCell,
  SelectHeader,
  SortHeader,
} from '../components/ServiceUi'
import { formatServiceDate } from '../lib/format'
import { listRepositories, type EcrRepositoryRow } from '../lib/ecr'

export function EcrRepositoriesPage() {
  const [repos, setRepos] = useState<EcrRepositoryRow[]>([])
  const [filter, setFilter] = useState('')
  const [selected, setSelected] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const list = await listRepositories()
      setRepos(list)
      setSelected((prev) =>
        prev && list.some((r) => r.name === prev) ? prev : null,
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
    if (!q) return repos
    return repos.filter(
      (r) =>
        r.name.toLowerCase().includes(q) ||
        r.uri.toLowerCase().includes(q) ||
        r.imageTagMutability.toLowerCase().includes(q) ||
        r.scanOnPush.toLowerCase().includes(q),
    )
  }, [repos, filter])

  function toggle(id: string) {
    setSelected((cur) => (cur === id ? null : id))
  }

  const selectionTitle = selected ? 'To implement' : 'Select a row'

  return (
    <ListCard
      title="Private repositories"
      desc="Amazon Elastic Container Registry (ECR) stores, manages, and deploys container images. A repository holds the images for a single application or service."
      notices={<Notices error={error} />}
      toolbar={
        <>
          <RefreshButton onClick={() => void refresh()} />
          <button
            type="button"
            className="btn btn-normal"
            disabled
            aria-disabled="true"
            title={selectionTitle}
            data-testid="ecr-delete"
          >
            Delete
          </button>
          <div className="spacer" />
          <DeadButton variant="primary">Create repository</DeadButton>
        </>
      }
      placeholder="Filter repositories by name or URI"
      filter={filter}
      onFilter={setFilter}
    >
      <table className="aws-table" data-testid="ecr-repositories-table">
        <thead>
          <tr>
            <SelectHeader />
            <SortHeader>Repository name</SortHeader>
            <SortHeader>URI</SortHeader>
            <FilterHeader>Image tag mutability</FilterHeader>
            <FilterHeader>Scan on push</FilterHeader>
            <SortHeader>Created at</SortHeader>
          </tr>
        </thead>
        <tbody>
          {filtered.length === 0 ? (
            <EmptyRow
              colSpan={6}
              loading={loading}
              loadingText="Loading repositories…"
              title="No private repositories"
              text="You do not have any private repositories in this region."
            />
          ) : (
            filtered.map((r) => {
              const isSelected = selected === r.name
              return (
                <tr
                  key={r.name}
                  className={`selectable${isSelected ? ' selected' : ''}`}
                  onClick={() => toggle(r.name)}
                >
                  <SelectCell
                    name="selected-ecr-repository"
                    id={r.name}
                    selected={isSelected}
                    onToggle={toggle}
                  />
                  <td>
                    <ResourceLabel ids={[r.name, r.uri]} detail={isSelected}>
                      <Link
                        to={`/ecr/repositories/${encodeURIComponent(r.name)}`}
                        onClick={(e) => e.stopPropagation()}
                      >
                        {r.name}
                      </Link>
                    </ResourceLabel>
                  </td>
                  <td>
                    <Mono>{r.uri}</Mono>
                  </td>
                  <td>{r.imageTagMutability}</td>
                  <td>{r.scanOnPush}</td>
                  <td>{formatServiceDate(r.createdAt)}</td>
                </tr>
              )
            })
          )}
        </tbody>
      </table>
    </ListCard>
  )
}
