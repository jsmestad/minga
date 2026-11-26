defmodule MingaEditor.Input.Queue do
  @moduledoc "Admits list bindings only while the in-conversation queue owns keyboard focus."
  @behaviour MingaEditor.Input.Handler

  alias Minga.Keymap
  alias Minga.Keymap.Bindings
  alias MingaEditor.Agent.QueueWorkflow
  alias MingaEditor.Agent.UIState.View
  alias MingaEditor.Input
  alias MingaEditor.Shell.Traditional.Workflow
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
      prefix = View.pending_prefix(state.workspace.agent_ui.view)
      key = {cp, mods}
      apply_binding(state, key, prefix, lookup(state, prefix, key))
    end
  end

  def handle_key(state, _cp, _mods), do: {:passthrough, state}

  @spec lookup(State.t(), Bindings.node_t() | nil, key()) :: binding()
  defp lookup(state, nil, key) do
    Keymap.resolve_scoped_key(:queue, Minga.Editing.binding_state(state), key,
      keymap_server: state.interaction.keymap_server
    )
  end

  defp lookup(state, prefix, key) do
    case Bindings.lookup(prefix, key) do
      :not_found -> lookup(state, nil, key)
      binding -> binding
    end
  end

  @spec apply_binding(State.t(), key(), Bindings.node_t() | nil, binding()) ::
          MingaEditor.Input.Handler.result()
  defp apply_binding(state, _key, _previous, {:prefix, prefix}),
    do: {:handled, remember_prefix(state, prefix)}

  defp apply_binding(state, key, previous, binding) do
    state = if previous, do: remember_prefix(state, nil), else: state

    case binding do
      {:command, action} -> {:handled, QueueWorkflow.key(state, action)}
      :not_found -> unbound(state, key)
    end
  end

  @spec remember_prefix(State.t(), Bindings.node_t() | nil) :: State.t()
  defp remember_prefix(state, prefix),
    do: Workflow.install_agent_view(state, View.set_prefix(state.workspace.agent_ui.view, prefix))

  @spec unbound(State.t(), key()) :: MingaEditor.Input.Handler.result()
  defp unbound(state, {27, 0}), do: {:handled, state}
  defp unbound(state, {cp, 0}) when cp > 32, do: {:handled, state}
  defp unbound(state, _key), do: {:passthrough, state}
end
