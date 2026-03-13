defmodule Minga.Agent.SessionExport do
  @moduledoc """
  Exports agent conversation sessions to Markdown files.

  Iterates the conversation context and formats each message into
  readable Markdown: user prompts as blockquotes, assistant responses
  as plain text, tool calls as collapsible `<details>` sections,
  and system messages as italic notes.
  """

  alias ReqLLM.Message.ContentPart

  @typedoc "Options for export."
  @type export_opts :: [
          project_root: String.t(),
          model: String.t() | nil,
          session_id: String.t() | nil,
          format: :markdown | :html
        ]

  @doc """
  Exports conversation messages to a Markdown string.

  Returns `{:ok, markdown, filename}` or `{:error, reason}`.
  """
  @spec to_markdown([ReqLLM.Message.t()], export_opts()) ::
          {:ok, String.t(), String.t()} | {:error, String.t()}
  def to_markdown([], _opts), do: {:error, "Nothing to export (empty session)"}

  def to_markdown(messages, opts) when is_list(messages) do
    # Filter out system messages from the export (they're internal)
    exportable = Enum.reject(messages, fn msg -> msg.role == :system end)

    if exportable == [] do
      {:error, "Nothing to export (only system messages)"}
    else
      model = Keyword.get(opts, :model, "unknown")
      session_id = Keyword.get(opts, :session_id) || short_id()
      date = Date.utc_today() |> Date.to_iso8601()
      filename = "minga-session-#{session_id}-#{date}.md"

      header = """
      # Minga Session Export

      - **Date:** #{date}
      - **Model:** #{model}
      - **Messages:** #{length(exportable)}

      ---
      """

      body = Enum.map_join(exportable, "\n\n---\n\n", &format_message/1)
      markdown = header <> "\n" <> body <> "\n"

      {:ok, markdown, filename}
    end
  end

  @doc """
  Exports conversation messages to a self-contained HTML string.

  Returns `{:ok, html, filename}` or `{:error, reason}`.
  """
  @spec to_html([ReqLLM.Message.t()], export_opts()) ::
          {:ok, String.t(), String.t()} | {:error, String.t()}
  def to_html(messages, opts) do
    case to_markdown(messages, opts) do
      {:ok, markdown, md_filename} ->
        html_filename = String.replace(md_filename, ~r/\.md$/, ".html")
        html = wrap_in_html(markdown, opts)
        {:ok, html, html_filename}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Exports and writes to a file in the project root.

  When `format: :html` is passed, produces an HTML file instead of Markdown.

  Returns `{:ok, path}` or `{:error, reason}`.
  """
  @spec export_to_file([ReqLLM.Message.t()], export_opts()) ::
          {:ok, String.t()} | {:error, String.t()}
  def export_to_file(messages, opts) do
    root = Keyword.get(opts, :project_root, File.cwd!())
    format = Keyword.get(opts, :format, :markdown)

    result =
      case format do
        :html -> to_html(messages, opts)
        _ -> to_markdown(messages, opts)
      end

    case result do
      {:ok, content, filename} ->
        path = Path.join(root, filename)
        File.write!(path, content)
        {:ok, path}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Message formatting ──────────────────────────────────────────────────────

  @spec format_message(ReqLLM.Message.t()) :: String.t()
  defp format_message(%{role: :user} = msg) do
    text = extract_text(msg.content)
    images = count_images(msg.content)

    image_note =
      if images > 0,
        do: " _(#{images} image#{if images > 1, do: "s", else: ""} attached)_",
        else: ""

    "## 👤 User#{image_note}\n\n" <> blockquote(text)
  end

  defp format_message(%{role: :assistant, tool_calls: tool_calls} = msg)
       when is_list(tool_calls) and tool_calls != [] do
    text = extract_text(msg.content)
    thinking = extract_thinking(msg.content)

    parts = []

    parts =
      if thinking != "" do
        parts ++
          [
            "## 🤖 Assistant\n\n<details>\n<summary>💭 Thinking</summary>\n\n#{thinking}\n\n</details>"
          ]
      else
        parts ++ ["## 🤖 Assistant"]
      end

    parts =
      if text != "" do
        parts ++ [text]
      else
        parts
      end

    tool_sections =
      Enum.map(tool_calls, fn tc ->
        name = tc.name || "unknown"
        args = if tc.arguments, do: Jason.encode!(tc.arguments, pretty: true), else: "{}"

        """
        <details>
        <summary>🔧 Tool call: #{name}</summary>

        ```json
        #{args}
        ```

        </details>
        """
      end)

    Enum.join(parts ++ tool_sections, "\n\n")
  end

  defp format_message(%{role: :assistant} = msg) do
    text = extract_text(msg.content)
    thinking = extract_thinking(msg.content)

    parts = ["## 🤖 Assistant"]

    parts =
      if thinking != "" do
        parts ++ ["<details>\n<summary>💭 Thinking</summary>\n\n#{thinking}\n\n</details>"]
      else
        parts
      end

    parts =
      if text != "" do
        parts ++ [text]
      else
        parts
      end

    Enum.join(parts, "\n\n")
  end

  defp format_message(%{role: :tool} = msg) do
    text = extract_text(msg.content)
    name = msg.name || "tool"
    tool_call_id = msg.tool_call_id || ""

    """
    <details>
    <summary>📋 Tool result: #{name} (#{tool_call_id})</summary>

    ```
    #{String.slice(text, 0, 5000)}
    ```

    </details>
    """
  end

  defp format_message(%{role: role} = msg) do
    text = extract_text(msg.content)
    "_#{role}: #{text}_"
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @spec extract_text([ContentPart.t()]) :: String.t()
  defp extract_text(parts) when is_list(parts) do
    parts
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", & &1.text)
  end

  defp extract_text(_), do: ""

  @spec extract_thinking([ContentPart.t()]) :: String.t()
  defp extract_thinking(parts) when is_list(parts) do
    parts
    |> Enum.filter(&(&1.type == :thinking))
    |> Enum.map_join("", & &1.text)
  end

  defp extract_thinking(_), do: ""

  @spec count_images([ContentPart.t()]) :: non_neg_integer()
  defp count_images(parts) when is_list(parts) do
    Enum.count(parts, &(&1.type in [:image, :image_url]))
  end

  defp count_images(_), do: 0

  @spec blockquote(String.t()) :: String.t()
  defp blockquote(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("> " <> &1))
  end

  @spec short_id() :: String.t()
  defp short_id do
    :crypto.strong_rand_bytes(4)
    |> Base.hex_encode32(case: :lower, padding: false)
    |> String.slice(0, 6)
  end

  # ── HTML wrapper ────────────────────────────────────────────────────────────

  @spec wrap_in_html(String.t(), export_opts()) :: String.t()
  defp wrap_in_html(markdown, opts) do
    model = Keyword.get(opts, :model, "unknown")
    date = Date.utc_today() |> Date.to_iso8601()

    # Convert markdown to simple HTML. This is a lightweight conversion
    # that handles the structures we produce (headings, blockquotes,
    # code blocks, details/summary, paragraphs, horizontal rules).
    body_html = markdown_to_html(markdown)

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Minga Session Export - #{date}</title>
    <style>
    :root { color-scheme: light dark; }
    body { max-width: 48rem; margin: 2rem auto; padding: 0 1rem; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; line-height: 1.6; color: #1a1a1a; background: #fff; }
    @media (prefers-color-scheme: dark) { body { color: #e0e0e0; background: #1a1a1a; } blockquote { border-color: #555; background: #222; } pre { background: #222; } details { background: #222; } hr { border-color: #333; } }
    h1 { font-size: 1.5rem; border-bottom: 1px solid #ddd; padding-bottom: 0.5rem; }
    h2 { font-size: 1.2rem; margin-top: 2rem; }
    blockquote { border-left: 3px solid #ccc; margin: 0.5rem 0; padding: 0.5rem 1rem; background: #f9f9f9; }
    pre { background: #f4f4f4; padding: 1rem; overflow-x: auto; border-radius: 4px; font-size: 0.85rem; }
    code { font-family: "SF Mono", Monaco, "Cascadia Code", monospace; font-size: 0.9em; }
    pre code { font-size: inherit; }
    details { margin: 0.5rem 0; padding: 0.5rem; background: #f9f9f9; border-radius: 4px; }
    summary { cursor: pointer; font-weight: 600; }
    hr { border: none; border-top: 1px solid #ddd; margin: 1.5rem 0; }
    .meta { color: #666; font-size: 0.85rem; }
    </style>
    </head>
    <body>
    <p class="meta">Model: #{html_escape(model)} | Exported: #{date}</p>
    #{body_html}
    </body>
    </html>
    """
  end

  @spec markdown_to_html(String.t()) :: String.t()
  defp markdown_to_html(markdown) do
    markdown
    |> String.split("\n")
    |> convert_lines([], nil)
    |> Enum.join("\n")
  end

  # Line-by-line markdown to HTML conversion. Handles the specific structures
  # our exporter produces: headings, blockquotes, fenced code blocks,
  # <details> blocks (passed through), horizontal rules, and paragraphs.
  @spec convert_lines([String.t()], [String.t()], :blockquote | :code | nil) :: [String.t()]
  defp convert_lines([], acc, :blockquote), do: Enum.reverse(["</blockquote>" | acc])
  defp convert_lines([], acc, _ctx), do: Enum.reverse(acc)

  defp convert_lines(["```" <> lang | rest], acc, nil) do
    trimmed = String.trim(lang)
    class = if trimmed != "", do: ~s( class="language-#{html_escape(trimmed)}"), else: ""
    convert_lines(rest, ["<pre><code#{class}>" | acc], :code)
  end

  defp convert_lines(["```" | rest], acc, :code) do
    convert_lines(rest, ["</code></pre>" | acc], nil)
  end

  defp convert_lines([line | rest], acc, :code) do
    convert_lines(rest, [html_escape(line) | acc], :code)
  end

  defp convert_lines(["---" | rest], acc, ctx) do
    acc = if ctx == :blockquote, do: ["</blockquote>" | acc], else: acc
    convert_lines(rest, ["<hr>" | acc], nil)
  end

  defp convert_lines(["# " <> text | rest], acc, ctx) do
    acc = if ctx == :blockquote, do: ["</blockquote>" | acc], else: acc
    convert_lines(rest, ["<h1>#{html_escape(text)}</h1>" | acc], nil)
  end

  defp convert_lines(["## " <> text | rest], acc, ctx) do
    acc = if ctx == :blockquote, do: ["</blockquote>" | acc], else: acc
    convert_lines(rest, ["<h2>#{html_escape(text)}</h2>" | acc], nil)
  end

  defp convert_lines(["> " <> text | rest], acc, :blockquote) do
    convert_lines(rest, [html_escape(text) <> "<br>" | acc], :blockquote)
  end

  defp convert_lines(["> " <> text | rest], acc, _ctx) do
    convert_lines(rest, [html_escape(text) <> "<br>", "<blockquote>" | acc], :blockquote)
  end

  defp convert_lines(["<details>" <> _ = line | rest], acc, ctx) do
    acc = if ctx == :blockquote, do: ["</blockquote>" | acc], else: acc
    convert_lines(rest, [line | acc], nil)
  end

  defp convert_lines(["" | rest], acc, :blockquote) do
    convert_lines(rest, ["</blockquote>" | acc], nil)
  end

  defp convert_lines(["" | rest], acc, ctx) do
    convert_lines(rest, acc, ctx)
  end

  defp convert_lines([line | rest], acc, ctx) do
    # Pass through HTML tags (details, summary, etc.) and wrap plain text in <p>
    if String.starts_with?(line, "<") do
      convert_lines(rest, [line | acc], ctx)
    else
      convert_lines(rest, ["<p>#{html_escape(line)}</p>" | acc], ctx)
    end
  end

  @spec html_escape(String.t()) :: String.t()
  defp html_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
