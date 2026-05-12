defmodule MingaEditor.Input.GitCommit do
  @moduledoc """
  Input handler for the git commit message buffer.

  When the git commit scope is active (`:git_commit`), this handler
  intercepts keys and routes them through the git commit keymap scope.
  C-c C-c commits, C-c C-k aborts, q (normal mode) aborts.
  Unmatched keys pass through to the Mode FSM for normal text editing.

  Multi-key prefix sequences (C-c followed by C-c or C-k) are tracked
  via `shell_state.git_commit_prefix`.
  """

  @behaviour MingaEditor.Input.Handler

  @type state :: MingaEditor.Input.Handler.handler_state()

  alias MingaEditor.Commands
  alias MingaEditor.State, as: EditorState
  alias Minga.Keymap
  alias Minga.Keymap.Bindings

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(%{workspace: %{keymap_scope: :git_commit}} = state, cp, mods) do
    key = {cp, mods}

    # Check for pending prefix continuation
    case EditorState.git_commit_prefix(state) do
      nil ->
        resolve_fresh(state, key)

      prefix_node when is_map(prefix_node) ->
        state = EditorState.set_git_commit_prefix(state, nil)
        resolve_prefix_continuation(state, prefix_node, key)
    end
  end

  def handle_key(state, _cp, _mods), do: {:passthrough, state}

  @impl true
  def handle_mouse(state, _row, _col, _button, _mods, _event_type, _click_count) do
    {:passthrough, state}
  end

  # ── Fresh key resolution ──────────────────────────────────────────────

  @spec resolve_fresh(state(), {non_neg_integer(), non_neg_integer()}) ::
          MingaEditor.Input.Handler.result()
  defp resolve_fresh(state, key) do
    binding_state = Minga.Editing.binding_state(state)

    case Keymap.resolve_scoped_key(
           :git_commit,
           binding_state,
           key,
           EditorState.keymap_context(state)
         ) do
      {:command, cmd} ->
        {:handled, dispatch_command(state, cmd)}

      {:prefix, node} ->
        {:handled, EditorState.set_git_commit_prefix(state, node)}

      :not_found ->
        {:passthrough, state}
    end
  end

  # ── Prefix continuation ────────────────────────────────────────────────

  @spec resolve_prefix_continuation(
          state(),
          Bindings.node_t(),
          {non_neg_integer(), non_neg_integer()}
        ) ::
          MingaEditor.Input.Handler.result()
  defp resolve_prefix_continuation(state, prefix_node, key) do
    case Bindings.lookup(prefix_node, key) do
      {:command, cmd} ->
        {:handled, dispatch_command(state, cmd)}

      {:prefix, sub_node} ->
        {:handled, EditorState.set_git_commit_prefix(state, sub_node)}

      :not_found ->
        # Invalid prefix continuation; re-process as fresh key
        resolve_fresh(state, key)
    end
  end

  # ── Command dispatch ───────────────────────────────────────────────────

  @spec dispatch_command(state(), atom()) :: state()
  defp dispatch_command(state, :git_commit_to_normal) do
    EditorState.transition_mode(state, :normal)
  end

  defp dispatch_command(state, cmd) do
    Commands.Git.execute(state, cmd)
  end
end
