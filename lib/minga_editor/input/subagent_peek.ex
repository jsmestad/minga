defmodule MingaEditor.Input.SubagentPeek do
  @moduledoc "Keeps peek navigation and child draft input out of the parent Agent handlers."
  @behaviour MingaEditor.Input.Handler

  import Bitwise

  alias Minga.Keymap
  alias Minga.Keymap.Bindings
  alias MingaEditor.Agent.SubagentPeekComposer, as: Composer
  alias MingaEditor.Agent.SubagentPeekSession, as: PeekSession
  alias MingaEditor.Agent.SubagentPeekWorkflow, as: Peek
  alias MingaEditor.Input
  alias MingaEditor.State
  alias MingaEditor.State.Windows
  alias MingaEditor.Window

  @typep key :: {non_neg_integer(), non_neg_integer()}
  @typep result :: MingaEditor.Input.Handler.result()

  @impl true
  @spec handle_key(State.t(), non_neg_integer(), non_neg_integer()) :: result()
  def handle_key(%State{workspace: %{keymap_scope: :subagent_peek}} = state, cp, mods) do
    case Composer.focused(state) do
      nil -> inspect_key(state, {cp, mods})
      target -> composer_key(state, target, {cp, mods})
    end
  end

  def handle_key(state, _cp, _mods), do: {:passthrough, state}

  @impl true
  @spec handle_paste(State.t(), String.t()) :: result()
  def handle_paste(%State{workspace: %{keymap_scope: :subagent_peek}} = state, text) do
    case Composer.focused(state) do
      nil -> {:handled, state}
      target -> {:handled, Composer.edit(state, target, {:insert, text})}
    end
  end

  def handle_paste(state, _text), do: {:passthrough, state}

  @spec inspect_key(State.t(), key()) :: result()
  defp inspect_key(state, key) do
    if Input.key_sequence_pending?(state) or Input.CUA.TUISpaceLeader.pending?(state) do
      {:passthrough, state}
    else
      binding = lookup(state, PeekSession.prefix(state), key)
      apply_binding(PeekSession.remember_prefix(state, nil), key, binding)
    end
  end

  @spec lookup(State.t(), Bindings.node_t() | nil, key()) :: term()
  defp lookup(state, nil, key) do
    # Opening from a pointer must not inherit the parent's Insert state. The
    # peek's own composer is dispatched separately; inspection is read-only.
    binding = if Minga.Editing.binding_state(state) == :cua, do: :cua, else: :normal

    Keymap.resolve_scoped_key(:subagent_peek, binding, key,
      keymap_server: state.interaction.keymap_server
    )
  end

  defp lookup(state, prefix, key) do
    case Bindings.lookup(prefix, key) do
      :not_found -> lookup(state, nil, key)
      binding -> binding
    end
  end

  @spec apply_binding(State.t(), key(), term()) :: result()
  defp apply_binding(state, _key, {:prefix, prefix}),
    do: {:handled, PeekSession.remember_prefix(state, prefix)}

  defp apply_binding(state, _key, {:command, :subagent_peek_next}),
    do: {:handled, Peek.step(state, :next)}

  defp apply_binding(state, _key, {:command, :subagent_peek_previous}),
    do: {:handled, Peek.step(state, :previous)}

  defp apply_binding(state, _key, {:command, :subagent_peek_brief}),
    do: {:handled, PeekSession.toggle_brief(state)}

  defp apply_binding(state, _key, {:command, :subagent_peek_close}),
    do: {:handled, Peek.close(state)}

  defp apply_binding(state, _key, {:command, :subagent_peek_compose}) do
    case Windows.active_struct(state.workspace.windows) do
      %Window{id: id, content: {:subagent_peek, {_, identity}}} ->
        {:handled, Composer.focus(state, {id, identity})}

      _other ->
        {:handled, state}
    end
  end

  defp apply_binding(state, {cp, 0}, :not_found) when cp > 32, do: {:handled, state}
  defp apply_binding(state, _key, :not_found), do: {:passthrough, state}

  defp apply_binding(state, _key, {:command, command}),
    do: {:handled, MingaEditor.Commands.execute(state, command)}

  @spec composer_key(State.t(), Composer.target(), key()) :: result()
  defp composer_key(state, _target, {27, 0}), do: {:handled, Composer.blur(state)}
  defp composer_key(state, target, {13, 0}), do: {:handled, Composer.submit(state, target)}
  defp composer_key(state, target, {13, 4}), do: edit(state, target, {:insert, "\n"})

  defp composer_key(state, target, {cp, 0}) when cp in [8, 127],
    do: edit(state, target, :backspace)

  defp composer_key(state, target, {cp, 0}) when cp in [0xF702, 57_350],
    do: edit(state, target, {:move, :left})

  defp composer_key(state, target, {cp, 0}) when cp in [0xF703, 57_351],
    do: edit(state, target, {:move, :right})

  defp composer_key(state, target, {cp, 0}) when cp in [0xF700, 57_352],
    do: edit(state, target, {:move, :up})

  defp composer_key(state, target, {cp, 0}) when cp in [0xF701, 57_353],
    do: edit(state, target, {:move, :down})

  defp composer_key(state, target, {cp, mods})
       when cp >= 32 and cp <= 0x10FFFF and cp not in 0xD800..0xDFFF and (mods &&& 0x0E) == 0 do
    if cp in 0xF700..0xF8FF or cp in 57_344..57_399 do
      {:handled, state}
    else
      edit(state, target, {:insert, <<cp::utf8>>})
    end
  end

  defp composer_key(state, _target, _key), do: {:handled, state}

  @spec edit(State.t(), Composer.target(), Composer.edit()) :: result()
  defp edit(state, target, operation), do: {:handled, Composer.edit(state, target, operation)}
end
