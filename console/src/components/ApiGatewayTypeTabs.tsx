import { Link } from 'react-router-dom'

export function ApiGatewayTypeTabs({ active }: { active: 'http' | 'rest' }) {
  return (
    <div className="aws-tabs" role="tablist">
      <Link
        className={`aws-tab${active === 'http' ? ' active' : ''}`}
        to="/apigateway"
        aria-current={active === 'http' ? 'page' : undefined}
      >
        HTTP APIs
      </Link>
      <Link
        className={`aws-tab${active === 'rest' ? ' active' : ''}`}
        to="/apigateway/rest-apis"
        aria-current={active === 'rest' ? 'page' : undefined}
      >
        REST APIs
      </Link>
    </div>
  )
}
