import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'

interface MarkdownContentProps {
  children: string
  className?: string
}

const normalizeAiMarkdown = (value: string) => value
  .split(/(```[\s\S]*?```|~~~[\s\S]*?~~~|`[^`\n]*`)/g)
  .map((segment, index) => {
    if (index % 2 === 1) return segment
    return segment
      .replace(/\*\*[ \t]*([^\n*]*?\S)[ \t]+\*\*/g, '**$1**')
      .replace(/__[ \t]*([^\n_]*?\S)[ \t]+__/g, '__$1__')
  })
  .join('')

export function MarkdownContent({ children, className = '' }: MarkdownContentProps) {
  return (
    <div className={`markdown-content ${className}`.trim()}>
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        skipHtml
        components={{
          a: ({ node, ...props }) => {
            void node
            if (!props.href) return <span>{props.children}</span>
            return <a {...props} target="_blank" rel="noreferrer noopener" />
          },
          img: ({ node, alt }) => {
            void node
            return alt ? <em className="markdown-image-alt">{alt}</em> : null
          },
        }}
      >
        {normalizeAiMarkdown(children)}
      </ReactMarkdown>
    </div>
  )
}
