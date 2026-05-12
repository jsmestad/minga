defmodule MingaEditor.Input.Dired do
  @moduledoc """
  Input handler for Oil.nvim-style directory buffers.

  When the dired scope is active, this handler resolves dired-specific
  keys (Enter, -, q, g-prefixed toggles) through the scope trie.
  All other keys pass through to the Mode FSM, making the buffer fully
  editable with standard vim motions and operators.

  Unlike FileTreeHandler, no buffer-swap trick is needed: the dired
  buffer IS the active buffer and is directly editable.
  """

  @behaviour MingaEditor.Input.Handler

  @type state :: MingaEditor.Input.Handler.handler_state()

  alias MingaEditor.Commands
  alias MingaEditor.State, as: EditorState
  alias Minga.Keymap

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()

  def handle_key(
        %{workspace: %{keymap_scope: :dired, dired: %{confirming?: true}}} = state,
        cp,
        mods
      ) do
    handle_confirmation_key(state, cp, mods)
  end

  def handle_key(%{workspace: %{keymap_scope: :dired}} = state, cp, mods) do
    key = {cp, mods}
    binding_state = Minga.Editing.binding_state(state)

    case Keymap.resolve_scoped_key(
           :dired,
           binding_state,
           key,
           EditorState.keymap_context(state)
         ) do
      {:command, command} ->
        {:handled, Commands.execute(state, command)}

      {:prefix, _node} ->
        {:passthrough, state}

      :not_found ->
        {:passthrough, state}
    end
  end

  def handle_key(state, _cp, _mods), do: {:passthrough, state}

  @impl true
  @spec handle_mouse(
          state(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: MingaEditor.Input.Handler.result()
  def handle_mouse(state, _row, _col, _button, _mods, _event_type, _click_count) do
    {:passthrough, state}
  end

  # ── Confirmation keys ──────────────────────────────────────────────────

  @spec handle_confirmation_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  defp handle_confirmation_key(state, ?y, 0) do
    {:handled, Commands.execute(state, :dired_confirm_apply)}
  end

  defp handle_confirmation_key(state, ?n, 0) do
    {:handled, Commands.execute(state, :dired_cancel_apply)}
  end

  defp handle_confirmation_key(state, 27, 0) do
    {:handled, Commands.execute(state, :dired_cancel_apply)}
  end

  defp handle_confirmation_key(state, _cp, _mods) do
    {:handled, state}
  end
end
