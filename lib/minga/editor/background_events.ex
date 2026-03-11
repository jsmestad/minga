defmodule Minga.Editor.BackgroundEvents do
  @moduledoc """
  Handles agent events for background (non-active) tabs.

  When an agent event arrives for a tab that isn't currently active,
  the surface isn't live, so we update the agent/agentic fields in
  the tab's stored context map directly. These functions mirror the
  active-tab handlers in `AgentView.handle_event/2` but operate on
  the background tab's snapshot instead.
  """

  alias Minga.Agent.DiffReview
  alias Minga.Agent.Session, as: AgentSession
  alias Minga.Agent.View.Preview
  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar

  @type state :: EditorState.t()

  @doc """
  Dispatches an agent event to the correct background tab handler.

  Updates the tab's stored context (agent/agentic fields) without
  requiring a live surface. Returns the updated editor state.
  """
  @spec handle(state(), Tab.t(), term()) :: state()
  def handle(state, tab, {:status_changed, status}) do
    state = EditorState.update_background_agent(state, tab.id, &AgentState.set_status(&1, status))
    # Tab bar may show spinner indicator for background tab status changes
    schedule_render(state, 16)
  end

  def handle(state, tab, {:text_delta, _delta}) do
    EditorState.update_background_agent(state, tab.id, &AgentState.maybe_auto_scroll/1)
  end

  def handle(state, tab, {:thinking_delta, _delta}) do
    EditorState.update_background_agent(state, tab.id, &AgentState.maybe_auto_scroll/1)
  end

  def handle(state, tab, :messages_changed) do
    state = EditorState.update_background_agent(state, tab.id, &AgentState.maybe_auto_scroll/1)
    session = background_tab_session(tab)
    maybe_update_tab_label(state, tab, session)
  end

  def handle(state, tab, {:tool_started, "shell", args}) do
    command = Map.get(args, "command", "")

    EditorState.update_background_agentic(state, tab.id, fn vs ->
      ViewState.update_preview(vs, &Preview.set_shell(&1, command))
    end)
  end

  def handle(state, tab, {:tool_update, _id, "shell", partial}) do
    state = EditorState.update_background_agent(state, tab.id, &AgentState.maybe_auto_scroll/1)

    EditorState.update_background_agentic(state, tab.id, fn vs ->
      ViewState.update_preview(vs, &Preview.update_shell_output(&1, partial))
    end)
  end

  def handle(state, tab, {:tool_update, _id, _name, _partial}) do
    EditorState.update_background_agent(state, tab.id, &AgentState.maybe_auto_scroll/1)
  end

  def handle(state, tab, {:tool_ended, "shell", result, status}) do
    shell_status = if status == :error, do: :error, else: :done

    EditorState.update_background_agentic(state, tab.id, fn vs ->
      ViewState.update_preview(vs, &Preview.finish_shell(&1, result, shell_status))
    end)
  end

  def handle(state, tab, {:tool_started, "read_file", args}) do
    path = Map.get(args, "path", "")

    EditorState.update_background_agentic(state, tab.id, fn vs ->
      ViewState.update_preview(vs, &Preview.set_file(&1, path, ""))
    end)
  end

  def handle(state, tab, {:tool_ended, "read_file", result, _status}) do
    update_file_preview(state, tab.id, result)
  end

  def handle(state, tab, {:tool_started, "list_directory", args}) do
    path = Map.get(args, "path", ".")

    EditorState.update_background_agentic(state, tab.id, fn vs ->
      ViewState.update_preview(vs, &Preview.set_directory(&1, path, []))
    end)
  end

  def handle(state, tab, {:tool_ended, "list_directory", result, _status}) do
    entries = result |> String.split("\n") |> Enum.reject(&(&1 == ""))
    update_directory_preview(state, tab.id, entries)
  end

  def handle(state, _tab, {:tool_started, _name, _args}), do: state
  def handle(state, _tab, {:tool_ended, _name, _result, _status}), do: state

  def handle(state, tab, {:file_changed, path, before_content, after_content}) do
    update_file_changed(state, tab.id, path, before_content, after_content)
  end

  def handle(state, tab, {:approval_pending, approval}) do
    cached = Map.take(approval, [:tool_call_id, :name, :args])

    EditorState.update_background_agent(
      state,
      tab.id,
      &AgentState.set_pending_approval(&1, cached)
    )
  end

  def handle(state, tab, {:approval_resolved, _decision}) do
    EditorState.update_background_agent(state, tab.id, &AgentState.clear_pending_approval/1)
  end

  def handle(state, tab, {:error, message}) do
    EditorState.update_background_agent(state, tab.id, &AgentState.set_error(&1, message))
    |> log_message("Agent error (tab #{tab.id}): #{message}")
  end

  def handle(state, _tab, _event), do: state

  # ── Helpers ──────────────────────────────────────────────────────────────

  # Extracts the agent session pid from a background tab's stored context.
  # Prefers the surface_state path; falls back to the legacy context.agent path.
  @spec background_tab_session(Tab.t()) :: pid() | nil
  defp background_tab_session(%Tab{session: pid}) when is_pid(pid), do: pid

  defp background_tab_session(%Tab{context: ctx}) do
    alias Minga.Surface.AgentView.State, as: AVState

    case Map.get(ctx, :surface_state) do
      %AVState{agent: agent} -> agent.session
      _ -> Map.get(ctx, :agent, %AgentState{}).session
    end
  end

  @spec update_file_preview(state(), Tab.id(), String.t()) :: state()
  defp update_file_preview(state, tab_id, result) do
    EditorState.update_background_agentic(state, tab_id, fn vs ->
      case vs.preview.content do
        {:file, path, _} -> ViewState.update_preview(vs, &Preview.set_file(&1, path, result))
        _ -> vs
      end
    end)
  end

  @spec update_directory_preview(state(), Tab.id(), [String.t()]) :: state()
  defp update_directory_preview(state, tab_id, entries) do
    EditorState.update_background_agentic(state, tab_id, fn vs ->
      case vs.preview.content do
        {:directory, path, _} ->
          ViewState.update_preview(vs, &Preview.set_directory(&1, path, entries))

        _ ->
          vs
      end
    end)
  end

  @spec update_file_changed(state(), Tab.id(), String.t(), String.t(), String.t()) :: state()
  defp update_file_changed(state, tab_id, path, before_content, after_content) do
    EditorState.update_background_agentic(state, tab_id, fn vs ->
      vs = ViewState.record_baseline(vs, path, before_content)
      baseline = ViewState.get_baseline(vs, path)

      case DiffReview.new(path, baseline, after_content) do
        nil ->
          vs

        review ->
          vs = ViewState.update_preview(vs, &Preview.set_diff(&1, review))
          ViewState.set_focus(vs, :file_viewer)
      end
    end)
  end

  @spec maybe_update_tab_label(state(), Tab.t(), pid() | nil) :: state()
  defp maybe_update_tab_label(state, _tab, nil), do: state

  defp maybe_update_tab_label(state, tab, session_pid) when is_pid(session_pid) do
    if default_agent_label?(tab.label) do
      messages =
        try do
          AgentSession.messages(session_pid)
        catch
          :exit, _ -> []
        end

      case first_user_message(messages) do
        nil ->
          state

        text ->
          %{state | tab_bar: TabBar.update_label(state.tab_bar, tab.id, truncate_label(text, 30))}
      end
    else
      state
    end
  end

  @spec default_agent_label?(String.t()) :: boolean()
  defp default_agent_label?("New Agent"), do: true
  defp default_agent_label?("minga"), do: true
  defp default_agent_label?(_), do: false

  @spec first_user_message([term()]) :: String.t() | nil
  defp first_user_message(messages) do
    Enum.find_value(messages, fn
      {:user, text} -> text
      _ -> nil
    end)
  end

  @spec truncate_label(String.t(), pos_integer()) :: String.t()
  defp truncate_label(text, max) do
    line = text |> String.split("\n", parts: 2) |> hd() |> String.trim()

    if String.length(line) > max do
      String.slice(line, 0, max) <> "…"
    else
      line
    end
  end

  @spec schedule_render(state(), non_neg_integer()) :: state()
  defp schedule_render(%{render_timer: ref} = state, _delay_ms) when is_reference(ref), do: state

  defp schedule_render(state, delay_ms) do
    ref = Process.send_after(self(), :debounced_render, delay_ms)
    %{state | render_timer: ref}
  end

  # Delegate to Editor's log_message (since we don't have direct access)
  @spec log_message(state(), String.t()) :: state()
  defp log_message(state, message) do
    Minga.Editor.log_to_messages(message)
    state
  end
end
