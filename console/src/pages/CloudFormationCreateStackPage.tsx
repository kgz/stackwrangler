import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { Notices } from '../components/ServiceUi'
import { TO_IMPLEMENT } from '../components/S3Ui'
import { createStack } from '../lib/cfn'

type TemplateSource = 'upload' | 'paste'

const SAMPLE_TEMPLATE = `AWSTemplateFormatVersion: "2010-09-09"
Description: Demo stack for local labs
Resources:
  DemoBucket:
    Type: AWS::S3::Bucket
`

async function readFileText(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => {
      const result = reader.result
      if (typeof result === 'string') {
        resolve(result)
        return
      }
      reject(new Error('Could not read template file as text'))
    }
    reader.onerror = () => reject(reader.error ?? new Error('File read failed'))
    reader.readAsText(file)
  })
}

export function CloudFormationCreateStackPage() {
  const navigate = useNavigate()
  const [name, setName] = useState('')
  const [description, setDescription] = useState('')
  const [source, setSource] = useState<TemplateSource>('paste')
  const [templateBody, setTemplateBody] = useState(SAMPLE_TEMPLATE)
  const [templateFile, setTemplateFile] = useState<File | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function onCreate() {
    const stackName = name.trim()
    if (!stackName) {
      setError('Stack name is required')
      return
    }

    setBusy(true)
    setError(null)
    try {
      let body = templateBody
      if (source === 'upload') {
        if (!templateFile) {
          setError('Select a template file')
          setBusy(false)
          return
        }
        body = await readFileText(templateFile)
      }
      const trimmed = body.trim()
      if (!trimmed) {
        setError('Template body is required')
        setBusy(false)
        return
      }

      await createStack({ stackName, templateBody: trimmed })
      navigate(`/cloudformation/stacks/${encodeURIComponent(stackName)}`)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <h1 className="aws-h1">Create stack</h1>
      <p className="aws-desc">
        Specify a template, name the stack, then create. LocalEmu accepts YAML
        or JSON template body.
      </p>
      <Notices error={error} />

      <section className="aws-card">
        <div className="aws-card-body">
          <h2 className="aws-section-title">Prerequisite — Prepare template</h2>
          <div
            className="aws-choice-row"
            role="group"
            aria-label="Prepare template"
          >
            <button
              type="button"
              className="aws-choice is-selected"
              aria-pressed="true"
            >
              <span>
                <strong>Template is ready</strong>
                <span>Upload a file or paste the template body.</span>
              </span>
            </button>
            <button
              type="button"
              className="aws-choice"
              disabled
              aria-disabled="true"
              title={TO_IMPLEMENT}
            >
              <span>
                <strong>Use a sample template</strong>
                <span>Start from an AWS sample.</span>
              </span>
            </button>
            <button
              type="button"
              className="aws-choice"
              disabled
              aria-disabled="true"
              title={TO_IMPLEMENT}
            >
              <span>
                <strong>Create template in Designer</strong>
                <span>
                  Build visually in Infrastructure Composer / Designer.
                </span>
              </span>
            </button>
          </div>
        </div>
      </section>

      <section className="aws-card" style={{ marginTop: 16 }}>
        <div className="aws-card-body aws-form-stack">
          <div className="aws-form-section">
            <h2 className="aws-section-title">Specify template</h2>
            <ul className="aws-radio-list">
              <li>
                <label>
                  <input
                    type="radio"
                    name="templateSource"
                    checked={source === 'upload'}
                    onChange={() => setSource('upload')}
                  />
                  <span>
                    <strong>Upload a template file</strong>
                    <span className="sub">
                      YAML (.yaml / .yml) or JSON (.json).
                    </span>
                  </span>
                </label>
              </li>
              <li>
                <label>
                  <input
                    type="radio"
                    name="templateSource"
                    checked={source === 'paste'}
                    onChange={() => setSource('paste')}
                  />
                  <span>
                    <strong>Paste template body</strong>
                    <span className="sub">
                      Paste YAML or JSON into the editor.
                    </span>
                  </span>
                </label>
              </li>
              <li>
                <label>
                  <input
                    type="radio"
                    name="templateSource"
                    disabled
                    aria-disabled="true"
                    title={TO_IMPLEMENT}
                  />
                  <span>
                    <strong>Amazon S3 URL</strong>
                    <span className="sub">Use a template object URL.</span>
                  </span>
                </label>
              </li>
            </ul>
            {source === 'upload' ? (
              <div className="aws-field" style={{ marginTop: 12 }}>
                <label className="aws-label" htmlFor="stack-template-file">
                  Template file
                </label>
                <input
                  className="aws-input"
                  id="stack-template-file"
                  type="file"
                  accept=".yaml,.yml,.json,application/json,text/yaml,text/x-yaml"
                  data-testid="cfn-create-file"
                  onChange={(e) =>
                    setTemplateFile(e.target.files?.[0] ?? null)
                  }
                />
                <p className="aws-hint">
                  Select a CloudFormation template file.
                </p>
              </div>
            ) : (
              <div className="aws-field" style={{ marginTop: 12 }}>
                <label className="aws-label" htmlFor="stack-template-body">
                  Template body
                </label>
                <textarea
                  className="aws-input aws-mono"
                  id="stack-template-body"
                  rows={14}
                  spellCheck={false}
                  value={templateBody}
                  data-testid="cfn-create-body"
                  onChange={(e) => setTemplateBody(e.target.value)}
                  style={{
                    width: '100%',
                    fontFamily: 'ui-monospace, monospace',
                    fontSize: 12,
                    lineHeight: 1.45,
                    resize: 'vertical',
                  }}
                />
                <p className="aws-hint">
                  YAML or JSON. IAM / named IAM / auto-expand capabilities are
                  requested on create.
                </p>
              </div>
            )}
          </div>

          <div className="aws-form-section">
            <h2 className="aws-section-title">Stack details</h2>
            <div className="aws-field">
              <label className="aws-label" htmlFor="stack-name">
                Stack name <span className="req">*</span>
              </label>
              <input
                className="aws-input"
                id="stack-name"
                name="stackName"
                type="text"
                autoComplete="off"
                placeholder="my-stack"
                value={name}
                data-testid="cfn-create-name"
                onChange={(e) => setName(e.target.value)}
              />
              <p className="aws-hint">
                Unique in this account and Region. Letters, numbers, and
                hyphens.
              </p>
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="stack-desc">
                Description
              </label>
              <input
                className="aws-input"
                id="stack-desc"
                name="description"
                type="text"
                placeholder="Optional (from template Description if omitted)"
                value={description}
                onChange={(e) => setDescription(e.target.value)}
              />
            </div>
          </div>

          <div className="aws-form-section">
            <h2 className="aws-section-title">Parameters</h2>
            <p className="aws-desc">No parameters detected in the template.</p>
          </div>

          <div className="aws-form-actions">
            <Link className="btn btn-normal" to="/cloudformation">
              Cancel
            </Link>
            <div className="spacer" style={{ flex: 1 }} />
            <button
              type="button"
              className="btn btn-primary"
              disabled={busy}
              onClick={() => void onCreate()}
              data-testid="cfn-create-submit"
            >
              {busy ? 'Creating…' : 'Create stack'}
            </button>
          </div>
        </div>
      </section>
    </>
  )
}
