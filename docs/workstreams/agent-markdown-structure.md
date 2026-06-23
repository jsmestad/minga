# Agent Markdown Structure Decision

## Decision

Keep `MingaAgent.Markdown` as the structural parser for agent chat markdown, and keep tree-sitter markdown as the fenced-code syntax highlighting layer.

## Rationale

Agent chat rendering has to work on partial streaming text. The structural parser runs line-by-line on incomplete assistant output, can preserve open fenced-code behavior, and does not require a full tree reparse or node walk on each stream delta. That makes it the right source for the bounded chat-rendering subset.

Tree-sitter stays valuable after structure is known. It should continue to provide language injection and syntax faces inside fenced code blocks, where correctness is worth the extra parser machinery and the structure has already identified code content.

## Supported Subset

The structural parser intentionally supports common agent-output markdown only: inline emphasis, inline code, safe links, fenced code blocks, indented code blocks outside list continuations, H1-H3 headings, unordered and numbered lists, blockquotes, horizontal rules, and plain paragraphs.

## Non-Goals

This is not a full CommonMark implementation. Do not add H4-H6, tables, task lists, footnotes, or nested block semantics unless the visual model defines how they render differently and tests cover that behavior.

## Revisit Criteria

Revisit tree-sitter as the structural source only if the renderer has an incremental node-walk cache that is cheap during streaming, preserves open-fence behavior on partial text, and produces the same styled-line shape without adding render-time flicker.
