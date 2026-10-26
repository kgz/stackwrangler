import { useLocation } from 'react-router-dom'
import { UnavailableListPage } from '../components/S3Ui'

type Kind = 'access-points' | 'access-points-fsx' | 'access-grants'

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
  'access-points': {
    title: 'Access Points',
    heading: 'Access Points (0)',
    emptyTitle: 'No access points',
    empty:
      'S3 Access Points are not available on this local stack. General purpose buckets work without them.',
    createLabel: 'Create access point',
  },
  'access-points-fsx': {
    title: 'Access Points for FSx',
    heading: 'Access Points for FSx (0)',
    emptyTitle: 'No Access Points for FSx',
    empty: 'Access Points for FSx are not available on this local stack.',
    createLabel: 'Create access point',
  },
  'access-grants': {
    title: 'Access Grants',
    heading: 'Access Grants (0)',
    emptyTitle: 'No Access Grants',
    empty: 'S3 Access Grants are not available on this local stack.',
    createLabel: 'Create grant',
  },
}

function kindFromPath(pathname: string): Kind {
  if (pathname.includes('fsx')) return 'access-points-fsx'
  if (pathname.includes('grants')) return 'access-grants'
  return 'access-points'
}

export function AccessManagementPage() {
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
