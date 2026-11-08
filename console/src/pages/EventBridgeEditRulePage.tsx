import { useEffect, useState } from 'react'
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom'
import { Notices } from '../components/ServiceUi'
import {
  describeRule,
  isDefaultEventBus,
  updateRule,
  type RuleType,
} from '../lib/events'

export function EventBridgeEditRulePage() {
  const navigate = useNavigate()
  const { name: rawName } = useParams()
  const [search] = useSearchParams()
  const name = rawName ? decodeURIComponent(rawName) : ''
  const eventBusName = search.get('bus')?.trim() || 'default'

  const [description, setDescription] = useState('')
  const [state, setState] = useState<'ENABLED' | 'DISABLED'>('ENABLED')
  const [ruleType, setRuleType] = useState<RuleType>('pattern')
  const [eventPattern, setEventPattern] = useState('{\n  "source": ["awsbox.demo"]\n}')
  const [scheduleExpression, setScheduleExpression] =
    useState('rate(5 minutes)')
  const [busy, setBusy] = useState(false)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!name) return
    setLoading(true)
    setError(null)
    void describeRule(name, eventBusName)
      .then((rule) => {
        setDescription(rule.description === '—' ? '' : rule.description)
        setState(rule.status === 'DISABLED' ? 'DISABLED' : 'ENABLED')
        if (rule.scheduleExpression) {
          setRuleType('schedule')
          setScheduleExpression(rule.scheduleExpression)
        } else {
          setRuleType('pattern')
          setEventPattern(
            rule.eventPattern || '{\n  "source": ["awsbox.demo"]\n}',
          )
        }
      })
      .catch((err: unknown) => {
        setError(err instanceof Error ? err.message : String(err))
      })
      .finally(() => setLoading(false))
  }, [name, eventBusName])

  async function onSave() {
    if (!name.trim()) {
      setError('Rule name is required')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await updateRule({
        name,
        description,
        eventBusName,
        state,
        ruleType,
        eventPattern,
        scheduleExpression,
      })
      navigate(
        `/events/rules/${encodeURIComponent(name)}?bus=${encodeURIComponent(eventBusName)}`,
      )
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  const backTo = `/events/rules/${encodeURIComponent(name)}?bus=${encodeURIComponent(eventBusName)}`
  const scheduleAllowed = isDefaultEventBus(eventBusName)

  return (
    <>
      <h1 className="aws-h1">Edit rule</h1>
      <p className="aws-desc">
        Update description, state, and pattern or schedule via LocalEmu{' '}
        <code>PutRule</code>. Name and event bus stay fixed.
      </p>
      <Notices error={error} />

      {loading ? <p className="aws-desc">Loading…</p> : null}

      {!loading ? (
        <>
          <section className="aws-card">
            <div className="aws-card-body aws-form-stack">
              <div className="aws-form-section">
                <h2 className="aws-section-title">Rule details</h2>
                <div className="aws-field">
                  <label className="aws-label" htmlFor="rule-name">
                    Name
                  </label>
                  <input
                    className="aws-input"
                    id="rule-name"
                    name="name"
                    type="text"
                    value={name}
                    disabled
                    readOnly
                    data-testid="events-edit-rule-name"
                  />
                </div>
                <div className="aws-field">
                  <label className="aws-label" htmlFor="rule-description">
                    Description
                  </label>
                  <input
                    className="aws-input"
                    id="rule-description"
                    name="description"
                    type="text"
                    autoComplete="off"
                    placeholder="Optional"
                    value={description}
                    onChange={(e) => setDescription(e.target.value)}
                    data-testid="events-edit-rule-description"
                  />
                </div>
                <div className="aws-field">
                  <label className="aws-label" htmlFor="rule-bus">
                    Event bus
                  </label>
                  <input
                    className="aws-input"
                    id="rule-bus"
                    name="eventBusName"
                    type="text"
                    value={eventBusName}
                    disabled
                    readOnly
                    data-testid="events-edit-rule-bus"
                  />
                </div>
                <div className="aws-field">
                  <label className="aws-label">State</label>
                  <ul className="aws-radio-list">
                    <li>
                      <label>
                        <input
                          type="radio"
                          name="state"
                          value="ENABLED"
                          checked={state === 'ENABLED'}
                          onChange={() => setState('ENABLED')}
                          data-testid="events-edit-rule-enabled"
                        />
                        <span>
                          <strong>Enabled</strong>
                          <span className="sub">
                            The rule evaluates matching events or schedules.
                          </span>
                        </span>
                      </label>
                    </li>
                    <li>
                      <label>
                        <input
                          type="radio"
                          name="state"
                          value="DISABLED"
                          checked={state === 'DISABLED'}
                          onChange={() => setState('DISABLED')}
                          data-testid="events-edit-rule-disabled"
                        />
                        <span>
                          <strong>Disabled</strong>
                          <span className="sub">
                            The rule is retained but does not match.
                          </span>
                        </span>
                      </label>
                    </li>
                  </ul>
                </div>
              </div>

              <div className="aws-form-section">
                <h2 className="aws-section-title">Rule type</h2>
                <ul className="aws-radio-list">
                  <li>
                    <label>
                      <input
                        type="radio"
                        name="ruleType"
                        value="pattern"
                        checked={ruleType === 'pattern'}
                        onChange={() => setRuleType('pattern')}
                        data-testid="events-edit-rule-type-pattern"
                      />
                      <span>
                        <strong>Event pattern</strong>
                        <span className="sub">
                          Match events by source, detail-type, and fields.
                        </span>
                      </span>
                    </label>
                  </li>
                  <li>
                    <label>
                      <input
                        type="radio"
                        name="ruleType"
                        value="schedule"
                        checked={ruleType === 'schedule'}
                        disabled={!scheduleAllowed}
                        title={
                          scheduleAllowed
                            ? undefined
                            : 'Schedule rules require the default event bus'
                        }
                        onChange={() => setRuleType('schedule')}
                        data-testid="events-edit-rule-type-schedule"
                      />
                      <span>
                        <strong>Schedule</strong>
                        <span className="sub">
                          Invoke on a rate or cron expression (default bus).
                        </span>
                      </span>
                    </label>
                  </li>
                </ul>
                {ruleType === 'pattern' ? (
                  <div className="aws-field" style={{ marginTop: 12 }}>
                    <label className="aws-label" htmlFor="event-pattern">
                      Event pattern <span className="req">*</span>
                    </label>
                    <textarea
                      className="aws-input"
                      id="event-pattern"
                      name="eventPattern"
                      rows={8}
                      value={eventPattern}
                      onChange={(e) => setEventPattern(e.target.value)}
                      data-testid="events-edit-rule-pattern"
                      style={{
                        fontFamily: 'var(--aws-mono, ui-monospace, monospace)',
                      }}
                    />
                  </div>
                ) : (
                  <div className="aws-field" style={{ marginTop: 12 }}>
                    <label className="aws-label" htmlFor="schedule-expression">
                      Schedule expression <span className="req">*</span>
                    </label>
                    <input
                      className="aws-input"
                      id="schedule-expression"
                      name="scheduleExpression"
                      type="text"
                      placeholder="rate(5 minutes)"
                      value={scheduleExpression}
                      onChange={(e) => setScheduleExpression(e.target.value)}
                      data-testid="events-edit-rule-schedule"
                    />
                  </div>
                )}
              </div>
            </div>
          </section>

          <div className="aws-toolbar" style={{ marginTop: 16 }}>
            <Link className="btn btn-normal" to={backTo}>
              Cancel
            </Link>
            <div className="spacer" />
            <button
              type="button"
              className="btn btn-primary"
              disabled={busy}
              onClick={() => void onSave()}
              data-testid="events-edit-rule-submit"
            >
              {busy ? 'Saving…' : 'Update rule'}
            </button>
          </div>
        </>
      ) : null}
    </>
  )
}
