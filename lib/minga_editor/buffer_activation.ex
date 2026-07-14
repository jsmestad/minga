defmodule MingaEditor.BufferActivation do
  @moduledoc "Focused workflow for activating a buffer and synchronizing shell presentation."

  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Workflow, as: ShellWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.BufferLifecycle

  @type state :: EditorState.t()
  @type option :: {:notify_shell?, boolean()} | {:replace_window_content?, boolean()}

  @doc "Activates a session buffer selection and optionally synchronizes shell presentation."
  @spec activate(state(), SessionState.buffer_activation()) :: state()
  @spec activate(state(), SessionState.buffer_activation(), [option()]) :: state()
  def activate(%EditorState{} = state, activation, opts \\ []) when is_list(opts) do
    state = %{
      state
      | workspace:
          SessionState.activate_buffer(state.workspace, activation,
            replace_window_content?: Keyword.get(opts, :replace_window_content?, false)
          )
    }

    if Keyword.get(opts, :notify_shell?, true) do
      synchronize_shell(state)
    else
      state
    end
  end

  @doc "Refreshes shell presentation after the active buffer changes identity in place."
  @spec refresh_presentation(state()) :: state()
  def refresh_presentation(%EditorState{} = state), do: synchronize_shell(state)

  @spec synchronize_shell(state()) :: state()
  defp synchronize_shell(%EditorState{} = state) do
    state = ShellWorkflow.ensure_available(state)

    case state.buffer_lifecycle.buffer_add_context do
      :preview ->
        %{state | buffer_lifecycle: BufferLifecycle.expect_buffer(state.buffer_lifecycle, :open)}

      :open ->
        {runtime, workspace} = Runtime.route_buffer_switched(state.shell_runtime, state.workspace)

        state
        |> then(fn state -> %{state | shell_runtime: runtime} end)
        |> then(fn state -> %{state | workspace: workspace} end)
    end
  end
end
