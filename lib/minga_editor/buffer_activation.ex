defmodule MingaEditor.BufferActivation do
  @moduledoc "Focused workflow for activating a buffer and synchronizing shell presentation."

  alias MingaEditor.Handlers.EffectHandler
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Workflow, as: ShellWorkflow
  alias MingaEditor.State, as: EditorState

  @type state :: EditorState.t()
  @type option :: {:notify_shell?, boolean()} | {:replace_window_content?, boolean()}

  @doc "Activates a session buffer selection and optionally synchronizes shell presentation."
  @spec activate(state(), SessionState.buffer_activation()) :: state()
  @spec activate(state(), SessionState.buffer_activation(), [option()]) :: state()
  def activate(%EditorState{} = state, activation, opts \\ []) when is_list(opts) do
    workspace =
      SessionState.activate_buffer(state.workspace, activation,
        replace_window_content?: Keyword.get(opts, :replace_window_content?, false)
      )

    state = EditorState.set_workspace(state, workspace)

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

    case state.buffer_add_context do
      :preview ->
        EditorState.set_buffer_add_context(state, :open)

      :open ->
        {runtime, workspace, effects} =
          Runtime.route_buffer_switched(state.shell_runtime, state.workspace)

        state
        |> EditorState.apply_shell_runtime_transition(runtime)
        |> EditorState.set_workspace(workspace)
        |> EffectHandler.apply_buffer_activation_effects(effects)
    end
  end
end
