defmodule MingaEditor.Input.TaskReview do
  @moduledoc "Dispatches task review scope keys only to the mounted generated buffer."

  @behaviour MingaEditor.Input.Handler

  alias Minga.Keymap
  alias Minga.Keymap.Bindings
  alias MingaEditor.BottomPanel
  alias MingaEditor.FocusOwner
  alias MingaEditor.Input
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Traditional.TaskReviewWorkflow, as: Review
  alias MingaEditor.State

  @typep result :: MingaEditor.Input.Handler.result()
  @typep key :: {non_neg_integer(), non_neg_integer()}

  @impl true
  @spec handle_key(State.t(), non_neg_integer(), non_neg_integer()) :: result()
  def handle_key(state, cp, mods) do
    case Review.focused(state) do
      {_, {buffer, _, _}} ->
        if review_keys?(state),
          do: resolve(state, buffer, {cp, mods}),
          else: {:passthrough, state}

      nil ->
        {:passthrough, state}
    end
  end

  @spec review_keys?(State.t()) :: boolean()
  defp review_keys?(state) do
    Minga.Editing.mode(state) == :normal and
      not state.workspace.agent_ui.panel.input_focused and
      not BottomPanel.focused?(state.shell_runtime.state.bottom_panel) and
      match?(%{surface: :editor}, FocusOwner.derive(state))
  end

  @spec resolve(State.t(), pid(), key()) :: result()
  defp resolve(state, buffer, key) do
    if Input.key_sequence_pending?(state) or Input.CUA.TUISpaceLeader.pending?(state) do
      {:passthrough, state}
    else
      workspace = state.workspace
      prefix = SessionState.get_feature_state(workspace, :builtin, :task_review_prefix)

      state = %{
        state
        | workspace: SessionState.drop_feature_state(workspace, :builtin, :task_review_prefix)
      }

      case lookup(state, buffer, prefix, key) do
        {:prefix, trie} ->
          workspace =
            SessionState.put_feature_state(
              state.workspace,
              :builtin,
              :task_review_prefix,
              {buffer, trie}
            )

          {:handled, %{state | workspace: workspace}}

        {:command, command} ->
          {:handled, MingaEditor.Commands.execute(state, command)}

        :not_found ->
          {:passthrough, state}
      end
    end
  end

  @spec lookup(State.t(), pid(), {pid(), Bindings.node_t()} | nil, key()) :: term()
  defp lookup(_state, buffer, {buffer, trie}, key) do
    Bindings.lookup(trie, key)
  end

  defp lookup(state, _buffer, _prefix, key) do
    mode = if Minga.Editing.binding_state(state) == :cua, do: :cua, else: :normal

    Keymap.resolve_scoped_key(:task_review, mode, key,
      keymap_server: state.interaction.keymap_server
    )
  end
end
