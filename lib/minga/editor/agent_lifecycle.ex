defmodule Minga.Editor.AgentLifecycle do
  @moduledoc """
  Agent session lifecycle helpers for the Editor GenServer.

  Handles agent session startup, auto-context loading, agent buffer
  synchronization, and tab label updates. These are called by the
  Editor during init, file open, and surface effect processing.

  All functions are pure state transformations (state -> state) that
  the Editor calls at the appropriate lifecycle points.
  """

  alias Minga.Agent.BufferSync, as: AgentBufferSync
  alias Minga.Agent.Session, as: AgentSession
  alias Minga.Agent.View.Preview
  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Config.Options, as: ConfigOptions
  alias Minga.Editor.Commands
  alias Minga.Editor.LayoutPreset
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  @type state :: EditorState.t()

  @doc """
  Starts the agent session if the agent pane is visible during init.

  Also loads auto-context if configured. Called once the port is ready.
  """
  @spec maybe_start_session(state()) :: state()
  def maybe_start_session(state) do
    agent = AgentAccess.agent(state)

    if agent.session == nil and LayoutPreset.has_agent_chat?(state) do
      state = Commands.Agent.ensure_agent_session(state)
      cli_flags = Minga.CLI.startup_flags()
      maybe_load_auto_context(state, cli_flags)
    else
      state
    end
  rescue
    e ->
      Minga.Log.warning(:agent, "Failed to start agent session at boot: #{Exception.message(e)}")
      state
  end

  @doc """
  Sets a file's content as the agentic preview pane if the agent pane
  is active and the preview is empty. Called when a file is opened while
  the agent view is already active.
  """
  @spec maybe_set_auto_context(state(), String.t(), pid()) :: state()
  def maybe_set_auto_context(state, file_path, buffer_pid) do
    cli_flags = Minga.CLI.startup_flags()
    auto_context = ConfigOptions.get(:agent_auto_context)
    agent_visible = LayoutPreset.has_agent_chat?(state)
    preview_empty = AgentAccess.agentic(state).preview.content == :empty

    if agent_visible and preview_empty and auto_context and not cli_flags.no_context do
      content = BufferServer.content(buffer_pid)
      update_preview(state, &Preview.set_file(&1, file_path, content))
    else
      state
    end
  end

  @doc """
  Syncs the agent buffer content with the current session messages.

  Called as a surface effect when the agent view receives new messages.
  """
  @spec sync_buffer(state()) :: state()
  def sync_buffer(state) do
    agent = AgentAccess.agent(state)

    if is_pid(agent.buffer) and is_pid(agent.session) do
      messages =
        try do
          AgentSession.messages(agent.session)
        catch
          :exit, _ -> []
        end

      # Don't clear the buffer when the session is dead and returns no messages.
      # The buffer should preserve its last-known content.
      if messages != [] do
        AgentBufferSync.sync(agent.buffer, messages)
      end

      state
    else
      state
    end
  end

  @doc """
  Updates the active agent tab's label to the first user prompt (truncated).

  Only updates if the current label is the default "New Agent" or "minga".
  """
  @spec maybe_update_tab_label(state()) :: state()
  def maybe_update_tab_label(%{tab_bar: %{active_id: active_id} = tb} = state) do
    session = AgentAccess.session(state)

    with true <- is_pid(session),
         %{kind: :agent, label: label} when is_binary(label) <- TabBar.active(tb),
         true <- default_agent_label?(label) do
      update_tab_from_session(state, tb, active_id, session)
    else
      _ -> state
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  @spec maybe_load_auto_context(state(), Minga.CLI.flags()) :: state()
  defp maybe_load_auto_context(state, %{no_context: true}), do: state

  defp maybe_load_auto_context(state, _flags) do
    auto_context = ConfigOptions.get(:agent_auto_context)
    active_buf = state.buffers.active

    if auto_context and active_buf do
      load_buffer_as_preview(state, active_buf)
    else
      state
    end
  end

  @spec load_buffer_as_preview(state(), pid()) :: state()
  defp load_buffer_as_preview(state, buffer_pid) do
    case BufferServer.file_path(buffer_pid) do
      nil ->
        state

      path ->
        content = BufferServer.content(buffer_pid)
        update_preview(state, &Preview.set_file(&1, path, content))
    end
  end

  @spec update_tab_from_session(state(), TabBar.t(), Tab.id(), pid()) :: state()
  defp update_tab_from_session(state, tb, active_id, session) do
    messages =
      try do
        AgentSession.messages(session)
      catch
        :exit, _ -> []
      end

    case first_user_message(messages) do
      nil ->
        state

      text ->
        label = truncate_label(text, 30)
        %{state | tab_bar: TabBar.update_label(tb, active_id, label)}
    end
  end

  @spec update_preview(state(), (Preview.t() -> Preview.t())) :: state()
  defp update_preview(state, fun) do
    AgentAccess.update_agentic(state, &ViewState.update_preview(&1, fun))
  end

  @spec default_agent_label?(String.t()) :: boolean()
  defp default_agent_label?("New Agent"), do: true
  defp default_agent_label?("minga"), do: true
  defp default_agent_label?(_), do: false

  @spec first_user_message([term()]) :: String.t() | nil
  defp first_user_message(messages) do
    Enum.find_value(messages, fn
      {:user, text} -> text
      {:user, text, _attachments} -> text
      _ -> nil
    end)
  end

  @spec truncate_label(String.t(), pos_integer()) :: String.t()
  defp truncate_label(text, max) do
    line = text |> String.split("\n", parts: 2) |> hd() |> String.trim()

    if String.length(line) > max do
      String.slice(line, 0, max - 1) <> "\u{2026}"
    else
      line
    end
  end
end
