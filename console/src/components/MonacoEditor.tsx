import Editor from '@monaco-editor/react'

type Props = {
  value: string
  language: string
  onChange: (value: string) => void
  path?: string
}

export function MonacoEditor({ value, language, onChange, path }: Props) {
  return (
    <div className="aws-monaco" data-od-id="code-editor">
      <Editor
        height="420px"
        theme="vs-dark"
        language={language}
        path={path}
        value={value}
        onChange={(next) => onChange(next ?? '')}
        options={{
          minimap: { enabled: false },
          fontSize: 13,
          fontFamily: '"Source Code Pro", ui-monospace, monospace',
          scrollBeyondLastLine: false,
          automaticLayout: true,
          tabSize: 2,
          padding: { top: 12, bottom: 12 },
        }}
      />
    </div>
  )
}
