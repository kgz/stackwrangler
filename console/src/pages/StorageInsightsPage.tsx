import { useLocation } from 'react-router-dom'
import { UnavailableListPage } from '../components/S3Ui'

type Kind = 'storage-lens' | 'batch-operations'

const META: Record<
  Kind,
  {
    title: string
    heading: string
    emptyTitle: string
    empty: string
    createLabel: string
  }
> = {
  'storage-lens': {
    title: 'Storage Lens',
    heading: 'Storage Lens (0)',
    emptyTitle: 'No Storage Lens dashboards',
    empty:
      'S3 Storage Lens is not available on this local stack. Use CLI and console object listings for local data.',
    createLabel: 'Create dashboard',
  },
  'batch-operations': {
    title: 'Batch Operations',
    heading: 'Batch Operations (0)',
    emptyTitle: 'No Batch Operations jobs',
    empty: 'S3 Batch Operations are not available on this local stack.',
    createLabel: 'Create job',
  },
}

function kindFromPath(pathname: string): Kind {
  if (pathname.includes('batch')) return 'batch-operations'
  return 'storage-lens'
}

export function StorageInsightsPage() {
  const { pathname } = useLocation()
  const kind = kindFromPath(pathname)
  const meta = META[kind]

  return (
    <UnavailableListPage
      title={meta.title}
      heading={meta.heading}
      createLabel={meta.createLabel}
      emptyTitle={meta.emptyTitle}
      emptyText={meta.empty}
      testId={`${kind}-empty`}
    />
  )
}
