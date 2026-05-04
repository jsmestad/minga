defmodule MingaEditor.Input.Dashboard do
  @moduledoc """
  Input handler for the dashboard home screen.

  Active when the dashboard modal is open (`state.shell_state.modal ==
  {:dashboard, _}`). Captures j/k and arrow keys for cursor navigation,
  Enter or SPC for item selection, and passes everything else through so
  global bindings (Ctrl+Q) still work.
  """

  @behaviour MingaEditor.Input.Handler

  @type state :: MingaEditor.Input.Handler.handler_state()

  alias MingaEditor.Commands
  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.Dashboard
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.ModalOverlay.Dashboard, as: DashboardPayload

  # Key codepoints
  @key_j ?j
  @key_k ?k
  @key_enter 13
  @key_space 32

  # Kitty keyboard protocol arrow key codepoints
  @arrow_up 57_352
  @arrow_down 57_353

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(
        %{shell_state: %{modal: {:dashboard, %{state: %{} = dash}}}} = state,
        codepoint,
        _modifiers
      ) do
    case codepoint do
      cp when cp == @key_j or cp == @arrow_down ->
        {:handled, transition_dashboard(state, Dashboard.cursor_down(dash))}

      cp when cp == @key_k or cp == @arrow_up ->
        {:handled, transition_dashboard(state, Dashboard.cursor_up(dash))}

      cp when cp == @key_enter or cp == @key_space ->
        handle_select(state, dash)

      _ ->
        {:passthrough, state}
    end
  end

  def handle_key(state, _codepoint, _modifiers), do: {:passthrough, state}

  @spec handle_select(state(), Dashboard.state()) :: MingaEditor.Input.Handler.result()
  defp handle_select(state, dash) do
    case Dashboard.selected_command(dash) do
      nil ->
        {:passthrough, state}

      {:open_file, path} ->
        root = safe_project_root()
        full_path = Path.join(root, path)
        state = BufferManagement.execute(state, {:execute_ex_command, {:edit, full_path}})
        {:handled, ModalOverlay.dismiss(state)}

      command when is_atom(command) ->
        state = Commands.execute(state, command)
        {:handled, ModalOverlay.dismiss(state)}
    end
  end

  @spec transition_dashboard(state(), Dashboard.state()) :: state()
  defp transition_dashboard(state, new_dash) do
    {:dashboard, payload} = state.shell_state.modal
    ModalOverlay.transition(state, :dashboard, DashboardPayload.put_state(payload, new_dash))
  end

  defdelegate safe_project_root, to: Minga.Project, as: :resolve_root
end
