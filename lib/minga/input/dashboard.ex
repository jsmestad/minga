defmodule Minga.Input.Dashboard do
  @moduledoc """
  Input handler for the dashboard home screen.

  Active only when no file buffer is open (`buffers.active == nil`).
  Captures j/k for cursor navigation, Enter for item selection, and
  passes everything else through so global bindings (SPC sequences,
  Ctrl+Q) still work.
  """

  @behaviour Minga.Input.Handler

  alias Minga.Editor.Commands
  alias Minga.Editor.Commands.BufferManagement
  alias Minga.Editor.Dashboard
  alias Minga.Editor.State, as: EditorState

  # Key codepoints
  @key_j ?j
  @key_k ?k
  @key_enter 13

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Input.Handler.result()
  def handle_key(%{buffers: %{active: nil}, dashboard: %{} = dash} = state, codepoint, _modifiers) do
    case codepoint do
      @key_j ->
        {:handled, %{state | dashboard: Dashboard.cursor_down(dash)}}

      @key_k ->
        {:handled, %{state | dashboard: Dashboard.cursor_up(dash)}}

      @key_enter ->
        handle_select(state, dash)

      _ ->
        {:passthrough, state}
    end
  end

  def handle_key(state, _codepoint, _modifiers), do: {:passthrough, state}

  @spec handle_select(EditorState.t(), Dashboard.state()) :: Minga.Input.Handler.result()
  defp handle_select(state, dash) do
    case Dashboard.selected_command(dash) do
      nil ->
        {:passthrough, state}

      {:open_file, path} ->
        root = safe_project_root()
        full_path = Path.join(root, path)
        state = BufferManagement.execute(state, {:execute_ex_command, {:edit, full_path}})
        state = %{state | dashboard: nil}
        {:handled, state}

      command when is_atom(command) ->
        state = Commands.execute(state, command)
        state = %{state | dashboard: nil}
        {:handled, state}
    end
  end

  @spec safe_project_root() :: String.t()
  defp safe_project_root do
    Minga.Project.root() || File.cwd!()
  catch
    :exit, _ -> File.cwd!()
  end
end
