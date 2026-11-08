import { useCallback, useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { DeadButton, RefreshButton } from '../components/S3Ui'
import {
  DetailHeader,
  EmptyRow,
  Kv,
  Mono,
  Notices,
  PlainHeader,
} from '../components/ServiceUi'
import {
  describeTopic,
  findTopicArnByName,
  listTopicSubscriptions,
  publishToTopic,
  type SnsSubscriptionRow,
  type SnsTopicDetail,
} from '../lib/sns'

type DetailTab = 'details' | 'subscriptions' | 'publish'

const TABS: ReadonlyArray<readonly [DetailTab, string]> = [
  ['details', 'Details'],
  ['subscriptions', 'Subscriptions'],
  ['publish', 'Publish'],
]

export function SnsTopicDetailPage() {
  const { name: rawName } = useParams()
  const name = rawName ? decodeURIComponent(rawName) : ''
  const [detail, setDetail] = useState<SnsTopicDetail | null>(null)
  const [subs, setSubs] = useState<SnsSubscriptionRow[]>([])
  const [tab, setTab] = useState<DetailTab>('details')
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')
  const [subject, setSubject] = useState('')
  const [messageGroupId, setMessageGroupId] = useState('')
  const [messageDedupId, setMessageDedupId] = useState('')
  const [lastMessageId, setLastMessageId] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    if (!name) return
    setLoading(true)
    setError(null)
    try {
      const arn = await findTopicArnByName(name)
      if (!arn) {
        setDetail(null)
        setSubs([])
        setError(`Topic not found: ${name}`)
        return
      }
      const topic = await describeTopic(arn)
      setDetail(topic)
      try {
        setSubs(await listTopicSubscriptions(arn))
      } catch {
        setSubs([])
      }
    } catch (err) {
      setDetail(null)
      setSubs([])
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [name])

  useEffect(() => {
    void refresh()
  }, [refresh])

  async function onPublish() {
    if (!detail) return
    setBusy(true)
    setError(null)
    setLastMessageId(null)
    try {
      const id = await publishToTopic({
        topicArn: detail.arn,
        message,
        subject,
        messageGroupId:
          detail.type === 'FIFO' ? messageGroupId : undefined,
        messageDeduplicationId:
          detail.type === 'FIFO' ? messageDedupId : undefined,
      })
      setLastMessageId(id || 'ok')
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  const title = detail?.name ?? name

  return (
    <>
      <DetailHeader
        title={title}
        subtitle={
          <>
            <span>{detail?.type ?? '—'}</span>
            <span>
              {detail?.arn ? <Mono>{detail.arn}</Mono> : '—'}
            </span>
          </>
        }
        actions={
          <>
            <RefreshButton onClick={() => void refresh()} />
            <DeadButton>Delete</DeadButton>
            <DeadButton>Create subscription</DeadButton>
            <button
              type="button"
              className="btn btn-primary"
              disabled={!detail}
              onClick={() => setTab('publish')}
              data-testid="sns-detail-publish"
            >
              Publish message
            </button>
          </>
        }
      />
      <p className="aws-desc">
        <Link to="/sns">← Topics</Link>
      </p>
      <Notices error={error} />

      <section className="aws-card">
        <div className="aws-tabs" role="tablist">
          {TABS.map(([id, label]) => (
            <button
              key={id}
              type="button"
              className={`aws-tab${tab === id ? ' active' : ''}`}
              aria-current={tab === id ? 'page' : undefined}
              onClick={() => setTab(id)}
              data-testid={`sns-tab-${id}`}
            >
              {label}
            </button>
          ))}
          <button
            type="button"
            className="aws-tab"
            disabled
            aria-disabled="true"
            title="To implement"
          >
            Encryption
          </button>
          <button
            type="button"
            className="aws-tab"
            disabled
            aria-disabled="true"
            title="To implement"
          >
            Access policy
          </button>
          <button
            type="button"
            className="aws-tab"
            disabled
            aria-disabled="true"
            title="To implement"
          >
            Delivery status
          </button>
        </div>
        <div className="aws-card-body">
          {loading && !detail ? <p className="aws-desc">Loading…</p> : null}

          {tab === 'details' && detail ? (
            <>
              <h2 className="aws-section-title">Topic details</h2>
              <Kv
                rows={[
                  ['Name', detail.name],
                  ['ARN', <Mono key="arn">{detail.arn}</Mono>],
                  ['Type', detail.type],
                  ['Display name', detail.displayName],
                  ['Owner', detail.owner],
                ]}
              />
            </>
          ) : null}

          {tab === 'subscriptions' ? (
            <>
              <h2 className="aws-section-title">Subscriptions</h2>
              <p className="aws-desc">
                From LocalEmu <code>ListSubscriptionsByTopic</code>.
              </p>
              <div className="aws-table-wrap">
                <table
                  className="aws-table"
                  data-testid="sns-subscriptions-table"
                >
                  <thead>
                    <tr>
                      <PlainHeader>Protocol</PlainHeader>
                      <PlainHeader>Endpoint</PlainHeader>
                      <PlainHeader>Status</PlainHeader>
                      <PlainHeader>Subscription ARN</PlainHeader>
                    </tr>
                  </thead>
                  <tbody>
                    {subs.length === 0 ? (
                      <EmptyRow
                        colSpan={4}
                        loading={loading}
                        loadingText="Loading subscriptions…"
                        title="No subscriptions"
                        text="This topic has no subscriptions in this region."
                      />
                    ) : (
                      subs.map((s) => (
                        <tr key={`${s.protocol}:${s.endpoint}:${s.subscriptionArn}`}>
                          <td>{s.protocol}</td>
                          <td>
                            <Mono>{s.endpoint}</Mono>
                          </td>
                          <td>{s.status}</td>
                          <td>
                            <Mono>{s.subscriptionArn}</Mono>
                          </td>
                        </tr>
                      ))
                    )}
                  </tbody>
                </table>
              </div>
            </>
          ) : null}

          {tab === 'publish' && detail ? (
            <>
              <h2 className="aws-section-title">Publish message</h2>
              <p className="aws-desc">
                Calls LocalEmu <code>Publish</code> against this topic ARN.
              </p>
              <div className="aws-field">
                <label className="aws-label" htmlFor="message-body">
                  Message <span className="req">*</span>
                </label>
                <textarea
                  className="aws-input"
                  id="message-body"
                  name="message"
                  rows={6}
                  placeholder="Message body"
                  value={message}
                  onChange={(e) => setMessage(e.target.value)}
                  data-testid="sns-publish-message"
                />
              </div>
              <div className="aws-field">
                <label className="aws-label" htmlFor="subject">
                  Subject
                </label>
                <input
                  className="aws-input"
                  id="subject"
                  name="subject"
                  type="text"
                  placeholder="Optional subject"
                  value={subject}
                  onChange={(e) => setSubject(e.target.value)}
                  data-testid="sns-publish-subject"
                />
              </div>
              {detail.type === 'FIFO' ? (
                <>
                  <div className="aws-field">
                    <label className="aws-label" htmlFor="message-group-id">
                      Message group ID <span className="req">*</span>
                    </label>
                    <input
                      className="aws-input"
                      id="message-group-id"
                      name="messageGroupId"
                      type="text"
                      value={messageGroupId}
                      onChange={(e) => setMessageGroupId(e.target.value)}
                      data-testid="sns-publish-group-id"
                    />
                  </div>
                  <div className="aws-field">
                    <label className="aws-label" htmlFor="message-dedup-id">
                      Message deduplication ID
                    </label>
                    <input
                      className="aws-input"
                      id="message-dedup-id"
                      name="messageDeduplicationId"
                      type="text"
                      value={messageDedupId}
                      onChange={(e) => setMessageDedupId(e.target.value)}
                      data-testid="sns-publish-dedup-id"
                    />
                    <p className="aws-hint">
                      Optional when content-based deduplication is enabled on
                      the topic.
                    </p>
                  </div>
                </>
              ) : null}
              <div className="aws-toolbar" style={{ marginTop: 12 }}>
                <button
                  type="button"
                  className="btn btn-primary"
                  disabled={busy}
                  onClick={() => void onPublish()}
                  data-testid="sns-publish-submit"
                >
                  {busy ? 'Publishing…' : 'Publish message'}
                </button>
              </div>
              {lastMessageId ? (
                <p className="aws-desc" data-testid="sns-publish-result">
                  Published. Message ID: <Mono>{lastMessageId}</Mono>
                </p>
              ) : null}
            </>
          ) : null}
        </div>
      </section>
    </>
  )
}
