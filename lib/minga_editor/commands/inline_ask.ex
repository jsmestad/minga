defmodule MingaEditor.Commands.InlineAsk do
  @moduledoc """
  Inline ask commands.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Buffer
  alias Minga.Command
  alias Minga.Mode.VisualState
  alias Minga.Project.FileRef
  alias MingaEditor.AgentLifecycle
  alias MingaEditor.Commands.AgentSession
  alias MingaEditor.State, as: EditorState
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
    do: MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, "Open a file before asking")

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

    state
    |> MingaEditor.Shell.Traditional.Workflow.install_inline_ask(ask)
    |> MingaEditor.Shell.Traditional.NoticeWorkflow.publish("Inline ask: type a question")
  end

  @doc "Promotes an answered inline ask into a normal agent workspace."
  @spec promote(state(), InlineAsk.t(), keyword()) :: state()
  def promote(state, ask, opts \\ [])

  def promote(state, %InlineAsk{status: status}, _opts) when status != :answered do
    MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
      state,
      "Wait for the inline answer before promoting"
    )
  end

  def promote(state, %InlineAsk{} = ask, opts) do
    session_starter = Keyword.get(opts, :session_starter, &start_promoted_agent_session/1)
    seeder = Keyword.get(opts, :seeder, &seed_agent_session/2)

    state = dismiss_without_stop(state, ask.buffer_pid)
    state = create_agent_tab(state)
    state = session_starter.(state)
    state = seeder.(state, ask)
    state = add_file_to_active_workspace(state, ask.file_ref)

    MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
      state,
      "Promoted inline ask to workspace"
    )
  end

  @spec start_promoted_agent_session(state()) :: state()
  defp start_promoted_agent_session(state) do
    AgentSession.start_agent_session(state, session_start_hook_enabled?: false)
  end

  @spec create_agent_tab(state()) :: state()
  defp create_agent_tab(%{shell_runtime: %{state: %{tab_bar: %TabBar{} = tb}}} = state) do
    win_id = 1
    rows = max(state.frontend.terminal_viewport.rows, 1)
    cols = max(state.frontend.terminal_viewport.cols, 1)
    agent_window = Window.new_agent_chat(win_id, rows, cols)

    windows = %Windows{
      tree: WindowTree.new(win_id),
      map: %{win_id => agent_window},
      active: win_id,
      next_id: win_id + 1
    }

    context = EditorState.build_agent_tab_defaults(state, windows)
    {tb, tab} = TabBar.insert(tb, :agent, "Inline Ask")
    tb = TabBar.update_context(tb, tab.id, context)

    then(state, fn root ->
      shell_state =
        MingaEditor.Shell.Traditional.State.set_tab_bar(
          MingaEditor.Shell.Runtime.state(root.shell_runtime),
          tb
        )

      %{
        root
        | shell_runtime:
            MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
      }
    end)
    |> EditorState.switch_tab(tab.id)
  end

  defp create_agent_tab(state), do: state

  @spec seed_agent_session(state(), InlineAsk.t()) :: state()
  defp seed_agent_session(state, %InlineAsk{} = ask) do
    case MingaEditor.Shell.Runtime.active_session(state.shell_runtime) do
      session_pid when is_pid(session_pid) ->
        messages = [{:user, ask.prompt}, {:assistant, ask.response}]
        MingaAgent.Session.seed_messages(session_pid, messages)
        AgentLifecycle.cache_messages(state, MingaAgent.Session.messages(session_pid))

      _ ->
        state
    end
  catch
    :exit, _ -> state
  end

  @spec add_file_to_active_workspace(state(), FileRef.t()) :: state()
  defp add_file_to_active_workspace(
         %{shell_runtime: %{state: %{tab_bar: %TabBar{} = tb}}} = state,
         %FileRef{} = file_ref
       ) do
    case TabBar.active_workspace(tb) do
      %Workspace{id: workspace_id} = workspace ->
        workspace = Workspace.add_file(workspace, file_ref)

        install_tab_bar(
          state,
          MingaEditor.State.TabBar.update_workspace(tb, workspace_id, fn _ -> workspace end)
        )

      nil ->
        state
    end
  end

  defp add_file_to_active_workspace(state, _file_ref), do: state

  @spec install_tab_bar(state(), TabBar.t()) :: state()
  defp install_tab_bar(state, tab_bar) do
    shell_state =
      MingaEditor.Shell.Traditional.State.set_tab_bar(
        MingaEditor.Shell.Runtime.state(state.shell_runtime),
        tab_bar
      )

    %{
      state
      | shell_runtime:
          MingaEditor.Shell.Runtime.install_traditional_state(state.shell_runtime, shell_state)
    }
  end

  @spec dismiss_without_stop(state(), pid()) :: state()
  defp dismiss_without_stop(state, buffer_pid) when is_pid(buffer_pid) do
    {state, _session_pid} =
      MingaEditor.Shell.Traditional.Workflow.cancel_inline_ask(state, buffer_pid)

    state
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
  defp project_root(state) do
    file_tree = state.workspace.file_tree
    file_tree.project_root || file_tree.original_root || File.cwd!()
  end

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
