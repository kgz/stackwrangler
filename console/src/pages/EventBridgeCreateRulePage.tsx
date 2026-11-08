import { useEffect, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { DeadButton } from '../components/S3Ui'
import { Notices } from '../components/ServiceUi'
import {
  createRule,
  listEventBuses,
  type EventBridgeBusRow,
  type RuleType,
} from '../lib/events'

const DEFAULT_PATTERN = `{
  "source": ["awsbox.demo"]
}`

export function EventBridgeCreateRulePage() {
  const navigate = useNavigate()
  const [name, setName] = useState('')
  const [description, setDescription] = useState('')
  const [eventBusName, setEventBusName] = useState('default')
  const [buses, setBuses] = useState<EventBridgeBusRow[]>([])
  const [state, setState] = useState<'ENABLED' | 'DISABLED'>('ENABLED')
  const [ruleType, setRuleType] = useState<RuleType>('pattern')
  const [eventPattern, setEventPattern] = useState(DEFAULT_PATTERN)
  const [scheduleExpression, setScheduleExpression] =
    useState('rate(5 minutes)')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    void listEventBuses()
      .then((list) => {
        setBuses(list)
      })
      .catch(() => {
        setBuses([
          { name: 'default', arn: '', type: 'Default', description: '' },
        ])
      })
  }, [])

  async function onCreate() {
    const ruleName = name.trim()
    if (!ruleName) {
      setError('Rule name is required')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await createRule({
        name: ruleName,
        description,
        eventBusName,
        state,
        ruleType,
        eventPattern,
        scheduleExpression,
      })
      navigate(
        `/events/rules/${encodeURIComponent(ruleName)}?bus=${encodeURIComponent(eventBusName)}`,
      )
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <h1 className="aws-h1">Create rule</h1>
      <p className="aws-desc">
        Define a rule that matches events with a pattern or runs on a schedule.
        LocalEmu accepts <code>PutRule</code> with an event pattern and/or{' '}
        <code>ScheduleExpression</code>.
      </p>
      <Notices error={error} />

      <section className="aws-card">
        <div className="aws-card-body aws-form-stack">
          <div className="aws-form-section">
            <h2 className="aws-section-title">Rule details</h2>
            <div className="aws-field">
              <label className="aws-label" htmlFor="rule-name">
                Name <span className="req">*</span>
              </label>
              <input
                className="aws-input"
                id="rule-name"
                name="name"
                type="text"
                autoComplete="off"
                placeholder="my-rule"
                value={name}
                onChange={(e) => setName(e.target.value)}
                data-testid="events-create-rule-name"
              />
              <p className="aws-hint">
                1–64 characters. Letters, numbers, periods, hyphens, and
                underscores.
              </p>
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
                data-testid="events-create-rule-description"
              />
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="rule-bus">
                Event bus
              </label>
              <select
                className="aws-input"
                id="rule-bus"
                name="eventBusName"
                value={eventBusName}
                onChange={(e) => setEventBusName(e.target.value)}
                data-testid="events-create-rule-bus"
              >
                {(buses.length > 0
                  ? buses
                  : [
                      {
                        name: 'default',
                        arn: '',
                        type: 'Default',
                        description: '',
                      },
                    ]
                ).map((b) => (
                  <option key={b.name} value={b.name}>
                    {b.name}
                  </option>
                ))}
              </select>
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
                      data-testid="events-create-rule-enabled"
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
                      data-testid="events-create-rule-disabled"
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
                    data-testid="events-create-rule-type-pattern"
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
                    onChange={() => setRuleType('schedule')}
                    data-testid="events-create-rule-type-schedule"
                  />
                  <span>
                    <strong>Schedule</strong>
                    <span className="sub">
                      Invoke on a rate or cron expression.
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
                  data-testid="events-create-rule-pattern"
                  style={{
                    fontFamily: 'var(--aws-mono, ui-monospace, monospace)',
                  }}
                />
                <p className="aws-hint">
                  JSON event pattern accepted by LocalEmu <code>PutRule</code>.
                </p>
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
                  data-testid="events-create-rule-schedule"
                />
                <p className="aws-hint">
                  Examples: <code>rate(5 minutes)</code>,{' '}
                  <code>cron(0 12 * * ? *)</code>.
                </p>
              </div>
            )}
          </div>

          <div className="aws-form-section">
            <h2 className="aws-section-title">Targets</h2>
            <p className="aws-desc">Add targets after the rule is created.</p>
            <DeadButton>Add target</DeadButton>
          </div>

          <div className="aws-form-section">
            <h2 className="aws-section-title">Tags</h2>
            <DeadButton>Add tags…</DeadButton>
          </div>
        </div>
      </section>

      <div className="aws-toolbar" style={{ marginTop: 16 }}>
        <Link className="btn btn-normal" to="/events">
          Cancel
        </Link>
        <div className="spacer" />
        <button
          type="button"
          className="btn btn-primary"
          disabled={busy}
          onClick={() => void onCreate()}
          data-testid="events-create-rule-submit"
        >
          {busy ? 'Creating…' : 'Create rule'}
        </button>
      </div>
    </>
  )
}
