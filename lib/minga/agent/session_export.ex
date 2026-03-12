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
          session_id: String.t() | nil
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
  Exports and writes to a file in the project root.

  Returns `{:ok, path}` or `{:error, reason}`.
  """
  @spec export_to_file([ReqLLM.Message.t()], export_opts()) ::
          {:ok, String.t()} | {:error, String.t()}
  def export_to_file(messages, opts) do
    root = Keyword.get(opts, :project_root, File.cwd!())

    case to_markdown(messages, opts) do
      {:ok, markdown, filename} ->
        path = Path.join(root, filename)
        File.write!(path, markdown)
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
end
