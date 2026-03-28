defmodule Minga.Input.Dashboard do
  @moduledoc """
  Input handler for the dashboard home screen.

  Active only when no file buffer is open (`buffers.active == nil`).
  Captures j/k and arrow keys for cursor navigation, Enter or SPC for
  item selection, and passes everything else through so global bindings
  (Ctrl+Q) still work.
  """

  @behaviour Minga.Input.Handler

  @type state :: Minga.Input.Handler.handler_state()

  alias Minga.Editor.Commands
  alias Minga.Editor.Commands.BufferManagement
  alias Minga.Editor.Dashboard
  alias Minga.Editor.State, as: EditorState

  # Key codepoints
  @key_j ?j
  @key_k ?k
  @key_enter 13
  @key_space 32

  # Kitty keyboard protocol arrow key codepoints
  @arrow_up 57_352
  @arrow_down 57_353

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) :: Minga.Input.Handler.result()
  def handle_key(
        %{workspace: %{buffers: %{active: nil}}, shell_state: %{dashboard: %{} = dash}} = state,
        codepoint,
        _modifiers
      ) do
    case codepoint do
      cp when cp == @key_j or cp == @arrow_down ->
        {:handled, EditorState.set_dashboard(state, Dashboard.cursor_down(dash))}

      cp when cp == @key_k or cp == @arrow_up ->
        {:handled, EditorState.set_dashboard(state, Dashboard.cursor_up(dash))}

      cp when cp == @key_enter or cp == @key_space ->
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
        state = EditorState.close_dashboard(state)
        {:handled, state}

      command when is_atom(command) ->
        state = Commands.execute(state, command)
        state = EditorState.close_dashboard(state)
        {:handled, state}
    end
  end

  defdelegate safe_project_root, to: Minga.Project, as: :resolve_root
end
