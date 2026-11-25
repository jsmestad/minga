defmodule MingaEditor.Input.WhichKey do
  @moduledoc """
  Gives an active which-key sequence first ownership of Escape, and walks a leader sequence that which-key holds itself.

  Escape closes which-key and cancels the pending leader sequence in the editing model, so the next `SPC` opens which-key again instead of continuing the old sequence (#4078).

  Vim's `SPC` walks its leader sequence in the Normal mode state, so this handler passes those keys through. The CUA space leader and the mode pill keep none in the mode: the macOS chord and retract (`CUA.SpaceLeader`), the terminal retract window (`CUA.TUISpaceLeader`) and the pill (`open/1`) start the sequence with `{:leader_start, node, prefix}`, so the which-key state is its only record. This handler resolves the next key inside that node before any surface sees it: a command runs, a prefix advances, Backspace goes back up one group (and closes which-key at the top, without reaching the surface), and any other key closes which-key and passes through to the focused surface.
  """

  @behaviour MingaEditor.Input.Handler

  alias Minga.Keymap.Bindings
  alias MingaEditor.Commands
  alias MingaEditor.Input.Router
  alias MingaEditor.Shell.Traditional.WhichKeyWorkflow

  @type state :: MingaEditor.Input.Handler.handler_state()

  @key_escape 27
  @key_backspace 127

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(
        %{shell_runtime: %{state: %{whichkey: %MingaEditor.State.WhichKey{node: node}}}} = state,
        @key_escape,
        _modifiers
      )
      when node != nil do
    {:handled,
     state
     |> WhichKeyWorkflow.dismiss()
     |> MingaEditor.Editing.update_mode_state(&Minga.Mode.cancel_leader/1)}
  end

  # A prompt or picker's own keys, opened by the mode pill, give every other key back to that prompt or picker
  # and close.
  def handle_key(
        %{
          shell_runtime: %{
            state: %{whichkey: %MingaEditor.State.WhichKey{node: node, owner: :scope}}
          }
        } =
          state,
        _codepoint,
        _modifiers
      )
      when node != nil,
      do: {:passthrough, WhichKeyWorkflow.dismiss(state)}

  def handle_key(
        %{
          shell_runtime: %{state: %{whichkey: %MingaEditor.State.WhichKey{node: node} = whichkey}}
        } =
          state,
        codepoint,
        modifiers
      )
      when node != nil do
    if which_key_leader?(state),
      do: continue_leader(state, whichkey, {codepoint, modifiers}),
      else: {:passthrough, state}
  end

  def handle_key(state, _codepoint, _modifiers), do: {:passthrough, state}

  # ── Mouse: the mode pill, rows and the breadcrumb ────────────────────────────

  @doc """
  Opens which-key at once, the way the mode pill does: the top-level leader groups, or the keys of the open prompt or picker.

  The leader starts at its root in which-key itself, in any mode and whatever has focus, without sending a key. A picker, a minibuffer prompt or the `:` command line shows its own scope's keys instead, because typing there edits text.
  """
  @spec open(state()) :: state()
  # The keys come from the same layers a key press resolves through, so a user override or a picker with nothing to
  # filter (whose keys are j, k and q) lists what its keys do.
  def open(%{shell_runtime: %{state: %{modal: {:picker, %{picker_ui: picker}}}}} = state) do
    node = MingaEditor.State.Picker.keymap_node(picker, state.interaction.keymap_server)
    WhichKeyWorkflow.open_scope(state, node, "Picker")
  end

  def open(%{shell_runtime: %{state: %{modal: {:prompt, _payload}}}} = state) do
    context = [keymap_server: state.interaction.keymap_server, prompt_list: false]
    node = Minga.Keymap.Scope.keymap_node(:prompt, :insert, context)
    WhichKeyWorkflow.open_scope(state, node, "Prompt")
  end

  def open(state) do
    cond do
      # An inline edit or question owns every key above which-key, so a panel there could not be walked.
      inline_overlay_active?(state) ->
        state

      Minga.Editing.mode(state) == :command ->
        node = Minga.Keymap.Scope.Prompt.keymap(:insert, prompt_list: true)
        WhichKeyWorkflow.open_scope(state, node, "Command line")

      true ->
        open_leader(state)
    end
  end

  @spec inline_overlay_active?(state()) :: boolean()
  defp inline_overlay_active?(state) do
    MingaEditor.Input.InlineOverlay.active(state, MingaEditor.Input.InlineEdit.spec()) != nil or
      MingaEditor.Input.InlineOverlay.active(state, MingaEditor.Input.InlineAsk.spec([])) != nil
  end

  # A completion popup, shown or still waiting on its source, is a modal, and a leader does not start under a modal,
  # so the pill closes it first.
  @spec dismiss_completion(state()) :: state()
  defp dismiss_completion(state), do: MingaEditor.CompletionHandling.dismiss(state)

  # An operator waiting for its motion is cancelled the way Escape cancels it, through the mode, so a macro being
  # recorded and dot-repeat see the cancel too.
  @spec cancel_operator(state()) :: state()
  defp cancel_operator(state) do
    if Minga.Editing.mode(state) == :operator_pending,
      do: MingaEditor.KeyDispatch.handle_key(state, @key_escape, 0),
      else: state
  end

  # The pill starts the leader in which-key itself, the way the CUA space leader does, and this handler walks it: no
  # key is sent to the mode or the focused surface, so nothing pending (`r` waiting for its target, a count, a
  # composer in Insert) can take one. Anything pending in the mode is dropped first, so it does not wait behind
  # which-key for the key after it. An operator waiting for its motion is cancelled, so the key after the leader command
  # is not read as its motion.
  @spec open_leader(state()) :: state()
  defp open_leader(state) do
    root = Minga.Keymap.leader_trie(state.interaction.keymap_server)

    state
    |> WhichKeyWorkflow.dismiss()
    |> dismiss_completion()
    |> cancel_operator()
    |> MingaEditor.Editing.update_mode_state(&Minga.Mode.clear_pending/1)
    |> Commands.execute({:leader_start, root, ["SPC"]})
    |> WhichKeyWorkflow.reveal_now()
  end

  @doc """
  Presses a which-key row's key, as if typed, while the panel on `path` is still the open one. A click on a panel that has since changed or closed does nothing.
  """
  @spec press(state(), String.t(), non_neg_integer(), non_neg_integer()) :: state()
  def press(state, path, codepoint, modifiers) do
    if open_path(state) == path,
      do: state |> close_scope_panel() |> Router.route_key(codepoint, modifiers),
      else: state
  end

  # A row of a prompt or picker's keys runs that key in the prompt or picker, so the panel closes first:
  # the key is meant for what is underneath (the Close row's esc closes the picker, not just the panel).
  @spec close_scope_panel(state()) :: state()
  defp close_scope_panel(
         %{shell_runtime: %{state: %{whichkey: %MingaEditor.State.WhichKey{owner: :scope}}}} =
           state
       ),
       do: WhichKeyWorkflow.dismiss(state)

  defp close_scope_panel(state), do: state

  @doc """
  Goes back up the breadcrumb to the crumb on `path`, one Backspace per level, while the open panel is below it.
  """
  @spec back(state(), String.t()) :: state()
  def back(state, path) do
    target = String.split(path, " ", trim: true)

    case open_path(state) do
      nil ->
        state

      open ->
        current = String.split(open, " ", trim: true)
        levels = length(current) - length(target)

        if levels > 0 and List.starts_with?(current, target),
          do: press_backspace(state, levels),
          else: state
    end
  end

  @spec press_backspace(state(), pos_integer()) :: state()
  defp press_backspace(state, times),
    do:
      Enum.reduce(1..times, state, fn _time, acc -> Router.route_key(acc, @key_backspace, 0) end)

  @spec open_path(state()) :: String.t() | nil
  defp open_path(%{
         shell_runtime: %{state: %{whichkey: %MingaEditor.State.WhichKey{} = whichkey}}
       }),
       do: MingaEditor.State.WhichKey.path(whichkey)

  defp open_path(_state), do: nil

  # Vim's SPC walks its leader in the Normal mode state. The CUA space leader and the mode pill keep the leader only
  # in which-key, so this handler walks it.
  @spec which_key_leader?(state()) :: boolean()
  defp which_key_leader?(state), do: not Minga.Editing.in_leader?(state)

  @spec continue_leader(state(), MingaEditor.State.WhichKey.t(), Bindings.key()) ::
          MingaEditor.Input.Handler.result()
  defp continue_leader(state, whichkey, {@key_backspace, 0}) do
    case MingaEditor.State.WhichKey.parent(whichkey) do
      {:ok, parent, prefix_keys} ->
        {:handled, Commands.execute(state, {:leader_progress, parent, prefix_keys})}

      :top ->
        {:handled, Commands.execute(state, :leader_cancel)}
    end
  end

  defp continue_leader(state, %MingaEditor.State.WhichKey{node: node} = whichkey, key) do
    case Bindings.lookup(node, key) do
      {:command, command} ->
        {:handled, state |> Commands.execute(:leader_cancel) |> execute_command(command)}

      {:prefix, sub_node} ->
        prefix_keys = List.insert_at(whichkey.prefix_keys, -1, Bindings.format_key(key))
        {:handled, Commands.execute(state, {:leader_progress, sub_node, prefix_keys})}

      :not_found ->
        {:passthrough, Commands.execute(state, :leader_cancel)}
    end
  end

  @spec execute_command(state(), atom() | tuple()) :: state()
  defp execute_command(state, command) do
    case Commands.execute(state, command) do
      {state, _action} -> state
      state -> state
    end
  end
end
