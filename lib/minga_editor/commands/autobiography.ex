defmodule MingaEditor.Commands.Autobiography do
  @moduledoc """
  Code-provenance commands: "git blame for the agent's mind".

  * `code_why` (`SPC g w`) answers "why is this line like this?" by showing the
    agent edit-turn that wrote the line under the cursor, with the request that
    prompted it and the agent's recorded thinking.
  * `code_autobiography` (`SPC g a`) shows the full timeline of agent edit-turns
    for the current file.

  Both read `MingaAgent.Autobiography`, which projects the durable agent event
  log. Only agent-written code has provenance; hand-edited lines show nothing.
  """

  use MingaEditor.Commands.Provider

  alias Minga.Buffer
  alias MingaAgent.Autobiography
  alias MingaAgent.Autobiography.Entry
  alias MingaEditor.HoverPopup
  alias MingaEditor.State, as: EditorState

  @command_specs [
    {:code_why, "Why is this line like this?", true},
    {:code_autobiography, "Code autobiography for this file", true}
  ]

  # Cap how much recorded text we pour into the popup; it stays scannable.
  @why_excerpt 800
  @timeline_excerpt 240
  @max_timeline_entries 15

  @spec execute(EditorState.t(), :code_why | :code_autobiography) :: EditorState.t()
  def execute(%{workspace: %{buffers: %{active: nil}}} = state, _cmd) do
    MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, "No active buffer")
  end

  def execute(state, :code_why) do
    with_path(state, fn buf, path ->
      {line, _col} = Buffer.cursor(buf)
      needle = Buffer.content_on_lines(buf, line, line)

      case Autobiography.for_line(path, needle, []) do
        {:ok, nil} ->
          MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
            state,
            "No agent history for this line"
          )

        {:ok, %Entry{} = entry} ->
          show_why_popup(state, entry, path)

        {:error, _reason} ->
          MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
            state,
            "Could not read agent history"
          )
      end
    end)
  end

  def execute(state, :code_autobiography) do
    with_path(state, fn _buf, path ->
      case Autobiography.for_file(path, []) do
        {:ok, []} ->
          MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
            state,
            "No agent history for this file"
          )

        {:ok, entries} ->
          show_popup(state, autobiography_markdown(entries, path))

        {:error, _reason} ->
          MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
            state,
            "Could not read agent history"
          )
      end
    end)
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  @spec show_why_popup(EditorState.t(), Entry.t(), String.t()) :: EditorState.t()
  defp show_why_popup(state, %Entry{} = entry, path) do
    action = {:open_session, entry.session_id, entry.tool_call_id}

    popup_opts =
      if expandable_entry?(entry), do: [expanded: why_expanded_markdown(entry, path)], else: []

    show_popup(state, why_markdown(entry, path), action, popup_opts)
  end

  @spec with_path(EditorState.t(), (Buffer.t(), String.t() -> EditorState.t())) :: EditorState.t()
  defp with_path(state, fun) do
    buf = state.workspace.buffers.active

    case Buffer.file_path(buf) do
      nil -> MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, "No file path")
      path -> fun.(buf, path)
    end
  end

  @spec show_popup(EditorState.t(), String.t(), HoverPopup.open_action() | nil, keyword()) ::
          EditorState.t()
  defp show_popup(state, markdown, open_action \\ nil, popup_opts \\ []) do
    vp = state.terminal_viewport
    opts = Keyword.put(popup_opts, :theme, state.theme)

    markdown
    |> MingaEditor.HoverPopup.Builder.new(div(vp.rows, 2), div(vp.cols, 4), opts)
    |> HoverPopup.focus()
    |> maybe_open_action(open_action)
    |> then(&MingaEditor.Shell.Traditional.HoverPopupWorkflow.show(state, &1))
  end

  @spec maybe_open_action(HoverPopup.t(), HoverPopup.open_action() | nil) :: HoverPopup.t()
  defp maybe_open_action(popup, nil), do: popup
  defp maybe_open_action(popup, action), do: HoverPopup.with_open_action(popup, action)

  @spec why_markdown(Entry.t(), String.t()) :: String.t()
  def why_markdown(%Entry{} = entry, path) do
    why_markdown(entry, path, @why_excerpt, why_hint(entry, :collapsed))
  end

  @spec why_expanded_markdown(Entry.t(), String.t()) :: String.t()
  def why_expanded_markdown(%Entry{} = entry, path) do
    why_markdown(entry, path, :full, why_hint(entry, :expanded))
  end

  @spec why_markdown(Entry.t(), String.t(), pos_integer() | :full, String.t()) :: String.t()
  defp why_markdown(%Entry{} = entry, path, excerpt, hint) do
    [
      "## Why is this line like this?",
      "`#{Path.basename(path)}` · #{format_time(entry.occurred_at)} · session #{short(entry.session_id)}",
      request_block(entry.user_request),
      thinking_block(entry.thinking, excerpt),
      said_block(entry.assistant_text, excerpt),
      hint
    ]
    |> compact_join()
  end

  # The popup is expandable only when something is actually truncated, so `o`
  # never opens a view identical to the collapsed one.
  @spec expandable_entry?(Entry.t()) :: boolean()
  defp expandable_entry?(%Entry{thinking: thinking, assistant_text: assistant}) do
    over_excerpt?(thinking) or over_excerpt?(assistant)
  end

  @spec over_excerpt?(String.t() | nil) :: boolean()
  defp over_excerpt?(nil), do: false
  defp over_excerpt?(text), do: String.length(one_line(text)) > @why_excerpt

  @spec why_hint(Entry.t(), :collapsed | :expanded) :: String.t()
  defp why_hint(%Entry{} = entry, phase) do
    base = "Enter: open the agent at this turn"

    cond do
      not expandable_entry?(entry) -> "_#{base}_"
      phase == :collapsed -> "_#{base} · o: expand_"
      phase == :expanded -> "_#{base} · o: collapse_"
    end
  end

  @spec autobiography_markdown([Entry.t()], String.t()) :: String.t()
  def autobiography_markdown(entries, path) do
    shown = Enum.take(entries, @max_timeline_entries)

    header = [
      "## Autobiography — `#{Path.basename(path)}`",
      "#{length(entries)} agent edit-turn(s)#{overflow_note(entries)}"
    ]

    (header ++ Enum.map(shown, &timeline_entry/1)) |> compact_join()
  end

  @spec timeline_entry(Entry.t()) :: String.t()
  defp timeline_entry(%Entry{} = entry) do
    [
      "### #{format_time(entry.occurred_at)} · session #{short(entry.session_id)}",
      request_block(entry.user_request),
      thinking_block(entry.thinking, @timeline_excerpt),
      said_block(entry.assistant_text, @timeline_excerpt)
    ]
    |> compact_join()
  end

  @spec request_block(String.t() | nil) :: String.t() | nil
  defp request_block(nil), do: nil
  defp request_block(text), do: "**You asked:** #{one_line(text)}"

  @spec thinking_block(String.t() | nil, pos_integer() | :full) :: String.t() | nil
  defp thinking_block(nil, _max), do: nil
  defp thinking_block(text, max), do: "**Thinking:** #{truncate(one_line(text), max)}"

  @spec said_block(String.t() | nil, pos_integer() | :full) :: String.t() | nil
  defp said_block(nil, _max), do: nil
  defp said_block(text, max), do: "**Agent:** #{truncate(one_line(text), max)}"

  @spec overflow_note([Entry.t()]) :: String.t()
  defp overflow_note(entries) do
    if length(entries) > @max_timeline_entries do
      ", showing #{@max_timeline_entries} most recent"
    else
      ""
    end
  end

  @spec format_time(DateTime.t()) :: String.t()
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %-d, %Y %H:%M")

  @spec short(String.t()) :: String.t()
  defp short(session_id), do: String.slice(session_id, 0, 8)

  @spec one_line(String.t()) :: String.t()
  defp one_line(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  @spec truncate(String.t(), pos_integer() | :full) :: String.t()
  defp truncate(text, :full), do: text

  defp truncate(text, max) when is_integer(max) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  @spec compact_join([String.t() | nil]) :: String.t()
  defp compact_join(parts), do: parts |> Enum.reject(&is_nil/1) |> Enum.join("\n\n")

  commands(@command_specs)
end
