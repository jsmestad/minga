defmodule MingaEditor.Commands.InlineAsk do
  @moduledoc """
  Inline ask commands.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Buffer
  alias Minga.Command
  alias Minga.Mode.VisualState
  alias Minga.Project.FileRef
  alias MingaEditor.Agent.BufferSync, as: AgentBufferSync
  alias MingaEditor.AgentLifecycle
  alias MingaEditor.Commands.AgentSession
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.InlineAsk
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Windows
  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  @type state :: EditorState.t()

  @impl true
  @spec __commands__() :: [Command.t()]
  def __commands__ do
    [
      %Command{
        name: :inline_ask,
        description: "Ask about the current line or selection",
        requires_buffer: true,
        execute: &open/1
      }
    ]
  end

  @doc "Opens an inline ask for the active buffer."
  @spec open(state()) :: state()
  def open(%{workspace: %{buffers: %{active: nil}}} = state),
    do: EditorState.set_status(state, "Open a file before asking")

  def open(%{workspace: %{buffers: %{active: buffer_pid}}} = state) when is_pid(buffer_pid) do
    {:ok, file_ref, label} = file_ref_for_active_buffer(state, buffer_pid)
    {line, _col} = Buffer.cursor(buffer_pid)

    ask =
      InlineAsk.new(
        buffer_pid,
        file_ref,
        label,
        anchor_line(state, line),
        selection_range(state, line),
        context_text(state, buffer_pid, line)
      )

    asks = state |> EditorState.inline_asks() |> InlineAsk.put(ask)

    state
    |> EditorState.set_inline_asks(asks)
    |> EditorState.set_status("Inline ask: type a question")
  end

  @doc "Promotes an answered inline ask into a normal agent workspace."
  @spec promote(state(), InlineAsk.t(), keyword()) :: state()
  def promote(state, ask, opts \\ [])

  def promote(state, %InlineAsk{status: status}, _opts) when status != :answered do
    EditorState.set_status(state, "Wait for the inline answer before promoting")
  end

  def promote(state, %InlineAsk{} = ask, opts) do
    session_starter = Keyword.get(opts, :session_starter, &AgentSession.start_agent_session/1)
    seeder = Keyword.get(opts, :seeder, &seed_agent_session/2)

    state = dismiss_without_stop(state, ask.buffer_pid)
    state = create_agent_tab(state)
    state = session_starter.(state)
    state = seeder.(state, ask)
    state = add_file_to_active_workspace(state, ask.file_ref)
    EditorState.set_status(state, "Promoted inline ask to workspace")
  end

  @spec create_agent_tab(state()) :: state()
  defp create_agent_tab(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    state = ensure_agent_buffer(state)
    agent_buf = AgentAccess.agent(state).buffer
    win_id = 1
    rows = max(state.terminal_viewport.rows, 1)
    cols = max(state.terminal_viewport.cols, 1)
    agent_window = Window.new_agent_chat(win_id, agent_buf, rows, cols)

    windows = %Windows{
      tree: WindowTree.new(win_id),
      map: %{win_id => agent_window},
      active: win_id,
      next_id: win_id + 1
    }

    context = EditorState.build_agent_tab_defaults(state, windows, agent_buf)
    {tb, tab} = TabBar.insert(tb, :agent, "Inline Ask")
    tb = TabBar.update_context(tb, tab.id, context)

    state
    |> EditorState.set_tab_bar(tb)
    |> EditorState.switch_tab(tab.id)
  end

  defp create_agent_tab(state), do: state

  @spec ensure_agent_buffer(state()) :: state()
  defp ensure_agent_buffer(state) do
    case AgentAccess.agent(state).buffer do
      pid when is_pid(pid) -> state
      _ -> create_agent_buffer(state)
    end
  end

  @spec create_agent_buffer(state()) :: state()
  defp create_agent_buffer(state) do
    case AgentBufferSync.start_buffer(EditorState.options_server(state)) do
      pid when is_pid(pid) ->
        state = AgentAccess.update_agent(state, &AgentState.set_buffer(&1, pid))
        state = EditorState.monitor_buffer(state, pid)
        AgentLifecycle.setup_agent_highlight(state)

      _ ->
        state
    end
  end

  @spec seed_agent_session(state(), InlineAsk.t()) :: state()
  defp seed_agent_session(state, %InlineAsk{} = ask) do
    case AgentAccess.session(state) do
      session_pid when is_pid(session_pid) ->
        messages = [{:user, ask.prompt}, {:assistant, ask.response}]
        MingaAgent.Session.seed_messages(session_pid, messages)

        case AgentAccess.agent(state).buffer do
          buffer_pid when is_pid(buffer_pid) ->
            AgentBufferSync.sync(buffer_pid, MingaAgent.Session.messages(session_pid))

          _ ->
            :ok
        end

        state

      _ ->
        state
    end
  catch
    :exit, _ -> state
  end

  @spec add_file_to_active_workspace(state(), FileRef.t()) :: state()
  defp add_file_to_active_workspace(
         %{shell_state: %{tab_bar: %TabBar{} = tb}} = state,
         %FileRef{} = file_ref
       ) do
    case TabBar.active_workspace(tb) do
      %Workspace{id: workspace_id} = workspace ->
        workspace = Workspace.add_file(workspace, file_ref)

        EditorState.set_tab_bar(
          state,
          TabBar.update_workspace(tb, workspace_id, fn _ -> workspace end)
        )

      nil ->
        state
    end
  end

  defp add_file_to_active_workspace(state, _file_ref), do: state

  @spec dismiss_without_stop(state(), pid()) :: state()
  defp dismiss_without_stop(state, buffer_pid) when is_pid(buffer_pid) do
    {asks, _session_pid} = state |> EditorState.inline_asks() |> InlineAsk.dismiss(buffer_pid)
    EditorState.set_inline_asks(state, asks)
  end

  @spec file_ref_for_active_buffer(state(), pid()) ::
          {:ok, FileRef.t(), String.t()} | {:error, String.t()}
  defp file_ref_for_active_buffer(state, buffer_pid) do
    case Buffer.file_path(buffer_pid) do
      path when is_binary(path) ->
        root = project_root(state)

        case FileRef.from_path(root, path) do
          {:ok, file_ref} ->
            {:ok, file_ref, file_ref.display_name}

          {:error, :outside_project} ->
            {:ok, FileRef.from_buffer(buffer_pid), Path.basename(path)}
        end

      _ ->
        file_ref = FileRef.from_buffer(buffer_pid)
        {:ok, file_ref, file_ref.display_name}
    end
  end

  @spec project_root(state()) :: String.t()
  defp project_root(%{workspace: %{file_tree: %{project_root: root}}}) when is_binary(root),
    do: root

  defp project_root(%{workspace: %{file_tree: %{original_root: root}}}) when is_binary(root),
    do: root

  defp project_root(_state), do: File.cwd!()

  @spec anchor_line(state(), non_neg_integer()) :: non_neg_integer()
  defp anchor_line(state, fallback_line) do
    case selection_range(state, fallback_line) do
      {first, last} -> max(first, last)
      nil -> fallback_line
    end
  end

  @spec context_text(state(), pid(), non_neg_integer()) :: String.t()
  defp context_text(state, buffer_pid, fallback_line) do
    case selection_range(state, fallback_line) do
      {first, last} -> Buffer.content_on_lines(buffer_pid, first, last)
      nil -> Buffer.content_on_lines(buffer_pid, fallback_line, fallback_line)
    end
  catch
    :exit, _ -> ""
  end

  @spec selection_range(state(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  defp selection_range(
         %{
           workspace: %{
             buffers: %{active: buffer_pid},
             editing: %{mode: mode, mode_state: %VisualState{} = ms}
           }
         },
         _fallback_line
       )
       when mode in [:visual, :visual_line] and is_pid(buffer_pid) do
    {cursor_line, _col} = Buffer.cursor(buffer_pid)
    {anchor_line, _col} = ms.visual_anchor
    {min(cursor_line, anchor_line), max(cursor_line, anchor_line)}
  end

  defp selection_range(_state, _fallback_line), do: nil
end
