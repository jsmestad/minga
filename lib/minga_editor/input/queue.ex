defmodule MingaEditor.Input.Queue do
  @moduledoc "Admits list bindings only while the in-conversation queue owns keyboard focus."
  @behaviour MingaEditor.Input.Handler

  alias Minga.Keymap
  alias Minga.Keymap.Bindings
  alias MingaEditor.Agent.QueueSurface
  alias MingaEditor.Agent.QueueWorkflow
  alias MingaEditor.Input
  alias MingaEditor.State

  @typep key :: {non_neg_integer(), non_neg_integer()}
  @typep binding ::
           {:prefix, Bindings.node_t()} | {:command, QueueWorkflow.key_action()} | :not_found

  @impl true
  @spec handle_key(State.t(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(%State{workspace: %{keymap_scope: :queue}} = state, cp, mods) do
    if Input.key_sequence_pending?(state) do
      {:passthrough, state}
    else
      prefix = state.workspace.agent_ui.queue.removal_prefix
      key = {cp, mods}
      apply_binding(state, key, prefix, lookup(state, prefix, key))
    end
  end

  def handle_key(state, _cp, _mods), do: {:passthrough, state}

  @spec lookup(State.t(), QueueSurface.removal_prefix() | nil, key()) :: binding()
  defp lookup(state, nil, key) do
    Keymap.resolve_scoped_key(:queue, Minga.Editing.binding_state(state), key,
      keymap_server: state.interaction.keymap_server
    )
  end

  defp lookup(state, {prefix, _identity}, key) do
    case Bindings.lookup(prefix, key) do
      :not_found -> lookup(state, nil, key)
      binding -> binding
    end
  end

  @spec apply_binding(State.t(), key(), QueueSurface.removal_prefix() | nil, binding()) ::
          MingaEditor.Input.Handler.result()
  defp apply_binding(state, _key, _previous, {:prefix, prefix}) do
    queue = QueueSurface.arm_removal(state.workspace.agent_ui.queue, prefix)
    {:handled, QueueWorkflow.install(state, queue)}
  end

  defp apply_binding(state, key, previous, binding) do
    state =
      if previous do
        QueueWorkflow.install(state, QueueSurface.cancel_removal(state.workspace.agent_ui.queue))
      else
        state
      end

    case {binding, previous} do
      {{:command, :queue_remove}, {_prefix, identity}} ->
        {:handled, QueueWorkflow.remove_displayed(state, identity)}

      {{:command, action}, _previous} ->
        {:handled, QueueWorkflow.key(state, action)}

      {:not_found, _previous} ->
        unbound(state, key)
    end
  end

  @spec unbound(State.t(), key()) :: MingaEditor.Input.Handler.result()
  defp unbound(state, {27, 0}), do: {:handled, state}
  defp unbound(state, {cp, 0}) when cp > 32, do: {:handled, state}
  defp unbound(state, _key), do: {:passthrough, state}
end
