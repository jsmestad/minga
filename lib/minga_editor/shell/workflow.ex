defmodule MingaEditor.Shell.Workflow do
  @moduledoc """
  Editor workflows around the pure shell runtime value.

  This module resolves registry entries, initializes shell states, and owns
  user-visible logging and status policy. `MingaEditor.Shell.Runtime` receives
  only resolved values. Shell lifecycle callbacks return updated values
  directly and execute in the Editor process that owns their timers.
  """

  alias MingaEditor.Shell.Entry
  alias MingaEditor.Shell.Registry
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.DeactivationWorkflow
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState

  @doc "Ensures the runtime's active registration is still current."
  @spec ensure_available(EditorState.t()) :: EditorState.t()
  def ensure_available(%EditorState{shell_runtime: runtime} = state) do
    case Registry.get(Runtime.id(runtime)) do
      %Entry{} = resolved -> validate_resolved_entry(state, runtime, resolved)
      nil -> fall_back_from_removed_entry(state, runtime, Registry.default())
    end
  end

  @doc "Switches to a registry-resolved shell id, preserving exact-identity state restoration."
  @spec switch(EditorState.t(), atom()) :: EditorState.t()
  def switch(%EditorState{} = state, shell_id) when is_atom(shell_id) do
    Registry.seed_builtin()
    entries = Registry.list()
    switch_resolved(state, shell_id, entries)
  end

  @doc "Returns current resolved registry entries for stashed event workflows."
  @spec resolved_entries() :: [Entry.t()]
  def resolved_entries, do: Registry.list()

  @spec validate_resolved_entry(EditorState.t(), Runtime.t(), Entry.t()) :: EditorState.t()
  defp validate_resolved_entry(state, runtime, resolved) do
    if Runtime.active_entry?(runtime, resolved) do
      state
    else
      initialized_state = initialize_shell_state(resolved.module, Runtime.state(runtime))
      {runtime, :reset} = Runtime.validate_registration(runtime, resolved, initialized_state)
      apply_registration_reset(state, runtime, resolved)
    end
  end

  @spec apply_registration_reset(EditorState.t(), Runtime.t(), Entry.t()) :: EditorState.t()
  defp apply_registration_reset(state, runtime, resolved) do
    Minga.Log.warning(
      :editor,
      "Shell #{inspect(resolved.id)} registry identity changed; resetting shell state"
    )

    state
    |> then(fn state -> %{state | shell_runtime: runtime} end)
    |> then(fn state ->
      %{state | render: MingaEditor.State.Render.invalidate_layout(state.render)}
    end)
    |> NoticeWorkflow.publish("Shell #{resolved.display_name} reloaded")
  end

  @spec fall_back_from_removed_entry(EditorState.t(), Runtime.t(), Entry.t()) :: EditorState.t()
  defp fall_back_from_removed_entry(state, runtime, default) do
    Minga.Log.warning(
      :editor,
      "Active shell #{inspect(Runtime.id(runtime))} (#{inspect(Runtime.module(runtime))}) is unavailable; switching to #{inspect(default.id)}"
    )

    state = DeactivationWorkflow.run(state)
    runtime = state.shell_runtime
    initialized_state = initialize_shell_state(default.module, Runtime.state(runtime))
    runtime = Runtime.fallback_from_removed(runtime, default, initialized_state)

    state
    |> then(fn state -> %{state | shell_runtime: runtime} end)
    |> then(fn state ->
      %{state | render: MingaEditor.State.Render.invalidate_layout(state.render)}
    end)
    |> NoticeWorkflow.publish("Shell unavailable, switched to #{default.display_name}")
  end

  @spec switch_resolved(EditorState.t(), atom(), [Entry.t()]) :: EditorState.t()
  defp switch_resolved(
         %EditorState{shell_runtime: %Runtime{entry: %Entry{id: current_id}}} = state,
         shell_id,
         [_only]
       )
       when shell_id != current_id do
    NoticeWorkflow.publish(state, "Only one shell is available")
  end

  defp switch_resolved(
         %EditorState{shell_runtime: %Runtime{entry: %Entry{id: shell_id}}} = state,
         shell_id,
         _entries
       ) do
    NoticeWorkflow.publish(state, "Already using #{display_name(shell_id)}")
  end

  defp switch_resolved(state, shell_id, _entries) do
    case Registry.get(shell_id) do
      %Entry{} = target -> activate_resolved(state, target)
      nil -> NoticeWorkflow.publish(state, "Shell #{shell_id} is unavailable")
    end
  end

  @spec activate_resolved(EditorState.t(), Entry.t()) :: EditorState.t()
  defp activate_resolved(state, target) do
    state = DeactivationWorkflow.run(state)
    initialized_state = activation_default(state.shell_runtime, target)
    runtime = Runtime.activate(state.shell_runtime, target, initialized_state)

    state
    |> then(fn state -> %{state | shell_runtime: runtime} end)
    |> then(fn state ->
      %{state | render: MingaEditor.State.Render.invalidate_layout(state.render)}
    end)
  end

  @spec activation_default(Runtime.t(), Entry.t()) :: term()
  defp activation_default(runtime, target) do
    if Runtime.restorable?(runtime, target),
      do: Runtime.state(runtime),
      else: initialize_shell_state(target.module, Runtime.state(runtime))
  end

  @spec initialize_shell_state(module(), term()) :: term()
  defp initialize_shell_state(MingaEditor.Shell.Traditional, previous_state) do
    suppressed? =
      case previous_state do
        %TraditionalState{tool_prompts: prompts} ->
          MingaEditor.Shell.Traditional.ToolPrompts.suppressed?(prompts)

        _other ->
          false
      end

    TraditionalState.set_suppress_tool_prompts(%TraditionalState{}, suppressed?)
  end

  defp initialize_shell_state(module, _previous_state), do: module.init([])

  @spec display_name(atom()) :: String.t()
  defp display_name(shell_id) do
    case Registry.get(shell_id) do
      %Entry{display_name: name} -> name
      nil -> Atom.to_string(shell_id)
    end
  end
end
