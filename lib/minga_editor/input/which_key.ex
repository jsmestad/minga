defmodule MingaEditor.Input.WhichKey do
  @moduledoc """
  Gives an active which-key sequence first ownership of Escape, and walks the CUA space leader sequence.

  Escape closes which-key and cancels the pending leader sequence in the editing model, so the next `SPC` opens which-key again instead of continuing the old sequence (#4078).

  Vim walks its own leader sequence in the Normal mode state, so in Vim this handler passes every other key through. The CUA space leader keeps none: the macOS chord and retract (`CUA.SpaceLeader`) and the terminal retract window (`CUA.TUISpaceLeader`) start the sequence with `{:leader_start, node, prefix}`, so the which-key state is its only record. This handler resolves the next key inside that node before any surface sees it: a command runs, a prefix advances, Backspace goes back up one group (and closes which-key at the top, without reaching the surface), and any other key closes which-key and passes through to the focused surface.
  """

  @behaviour MingaEditor.Input.Handler

  alias Minga.Keymap.Bindings
  alias MingaEditor.Commands
  alias MingaEditor.Input.Router
  alias MingaEditor.Shell.Traditional.WhichKeyWorkflow

  @type state :: MingaEditor.Input.Handler.handler_state()

  @key_escape 27
  @key_backspace 127
  @key_space 32

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
    if cua_leader?(state),
      do: continue_leader(state, whichkey, {codepoint, modifiers}),
      else: {:passthrough, state}
  end

  def handle_key(state, _codepoint, _modifiers), do: {:passthrough, state}

  # ── Mouse: the mode pill, rows and the breadcrumb ────────────────────────────

  @doc """
  Opens which-key at once, the way the mode pill does: the top-level leader groups, or the keys of the open prompt or picker.

  In Vim, Normal mode starts the leader with `SPC`; another mode returns to Normal first. The CUA space leader starts at the leader root. A picker, a minibuffer prompt or the `:` command line shows its own scope's keys instead, because typing there edits text.
  """
  @spec open(state()) :: state()
  def open(%{shell_runtime: %{state: %{modal: {:picker, %{picker_ui: picker}}}}} = state) do
    context = MingaEditor.PickerUI.picker_keymap_context(state, picker)

    WhichKeyWorkflow.open_scope(
      state,
      Minga.Keymap.Scope.Picker.keymap(:insert, context),
      "Picker"
    )
  end

  def open(%{shell_runtime: %{state: %{modal: {:prompt, _payload}}}} = state),
    do:
      WhichKeyWorkflow.open_scope(state, Minga.Keymap.Scope.Prompt.keymap(:insert, []), "Prompt")

  def open(state) do
    case {Minga.Editing.active_model(state), Minga.Editing.mode(state)} do
      {_model, :command} ->
        node = Minga.Keymap.Scope.Prompt.keymap(:insert, prompt_list: true)
        WhichKeyWorkflow.open_scope(state, node, "Command line")

      {Minga.Editing.Model.CUA, _mode} ->
        root = Minga.Keymap.leader_trie(state.interaction.keymap_server)

        state
        |> Commands.execute({:leader_start, root, ["SPC"]})
        |> WhichKeyWorkflow.reveal_now()

      {_vim, :normal} ->
        state
        |> cancel_pending_leader()
        |> Router.route_key(@key_space, 0)
        |> WhichKeyWorkflow.reveal_now()

      {_vim, _other} ->
        state |> Router.route_key(@key_escape, 0) |> open_from_normal()
    end
  end

  # A leader already pending (SPC typed, or the panel open at a group) starts over at the root: another SPC there
  # would run `SPC SPC` instead of opening the top level.
  @spec cancel_pending_leader(state()) :: state()
  defp cancel_pending_leader(state) do
    if Minga.Editing.in_leader?(state) do
      state
      |> WhichKeyWorkflow.dismiss()
      |> MingaEditor.Editing.update_mode_state(&Minga.Mode.cancel_leader/1)
    else
      state
    end
  end

  @spec open_from_normal(state()) :: state()
  defp open_from_normal(state) do
    if Minga.Editing.mode(state) == :normal,
      do: state |> Router.route_key(@key_space, 0) |> WhichKeyWorkflow.reveal_now(),
      else: state
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

  # Only the CUA space leader leaves its sequence to which-key. A Vim which-key node without a mode
  # leader is stale (a click resets the mode), so the key belongs to the mode, not to the group.
  @spec cua_leader?(state()) :: boolean()
  defp cua_leader?(state) do
    Minga.Editing.active_model(state) == Minga.Editing.Model.CUA and
      not Minga.Editing.in_leader?(state)
  end

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
