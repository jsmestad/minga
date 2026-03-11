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
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar

  require Logger

  @type state :: EditorState.t()

  @doc """
  Starts the agent session if the agentic view was activated during init.

  Also loads auto-context if configured. Called once the port is ready.
  """
  @spec maybe_start_session(state()) :: state()
  def maybe_start_session(%{agentic: %{active: true}, agent: %{session: nil}} = state) do
    state = Commands.Agent.ensure_agent_session(state)
    cli_flags = Minga.CLI.startup_flags()
    maybe_load_auto_context(state, cli_flags)
  rescue
    e ->
      Logger.warning("Failed to start agent session at boot: #{Exception.message(e)}")
      state
  end

  def maybe_start_session(state), do: state

  @doc """
  Sets a file's content as the agentic preview pane if the agentic view
  is active and the preview is empty. Called when a file is opened while
  the agentic view is already active.
  """
  @spec maybe_set_auto_context(state(), String.t(), pid()) :: state()
  def maybe_set_auto_context(state, file_path, buffer_pid) do
    cli_flags = Minga.CLI.startup_flags()
    auto_context = ConfigOptions.get(:agent_auto_context)
    agentic_active = state.agentic.active
    preview_empty = state.agentic.preview.content == :empty

    if agentic_active and preview_empty and auto_context and not cli_flags.no_context do
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
  def sync_buffer(%{agent: %{buffer: buf, session: session}} = state)
      when is_pid(buf) and is_pid(session) do
    messages =
      try do
        AgentSession.messages(session)
      catch
        :exit, _ -> []
      end

    AgentBufferSync.sync(buf, messages)
    state
  end

  def sync_buffer(state), do: state

  @doc """
  Updates the active agent tab's label to the first user prompt (truncated).

  Only updates if the current label is the default "New Agent" or "minga".
  """
  @spec maybe_update_tab_label(state()) :: state()
  def maybe_update_tab_label(
        %{tab_bar: %{active_id: active_id} = tb, agent: %{session: session}} = state
      )
      when is_pid(session) do
    case TabBar.active(tb) do
      %{kind: :agent, label: label} when is_binary(label) ->
        if default_agent_label?(label) do
          update_tab_from_session(state, tb, active_id, session)
        else
          state
        end

      _other ->
        state
    end
  end

  def maybe_update_tab_label(state), do: state

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
    %{state | agentic: ViewState.update_preview(state.agentic, fun)}
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
      String.slice(line, 0, max - 1) <> "\u{2026}"
    else
      line
    end
  end
end
