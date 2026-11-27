defmodule MingaEditor.Agent.SubagentPeekWorkflow do
  @moduledoc "Opens, retargets and closes the right split for an exact foreground invocation."

  alias MingaAgent.SessionManager
  alias MingaAgent.Tool.Invocation
  alias MingaEditor.Agent.Arrival
  alias MingaEditor.Agent.PromptInput
  alias MingaEditor.Agent.SubagentPeekComposer
  alias MingaEditor.Agent.SubagentPeekSession
  alias MingaEditor.Agent.Tasks
  alias MingaEditor.Agent.Tasks.Subagent
  alias MingaEditor.Agent.UIState
  alias MingaEditor.FocusOwner
  alias MingaEditor.Layout
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State
  alias MingaEditor.State.Windows
  alias MingaEditor.Window
  alias MingaEditor.Window.Content
  alias MingaEditor.WindowFocus
  alias MingaEditor.WindowTree

  @type click ::
          :started
          | :started_key
          | :sibling
          | :brief
          | :compose
          | :submit
          | :close
          | :inspect
          | :insert_text

  @doc "Opens this conversation's latest fan-out from its visible parent window."
  @spec open_from_current(State.t()) :: State.t()
  def open_from_current(%State{} = state) do
    windows = state.workspace.windows

    parent =
      case Windows.active_struct(windows) do
        %Window{id: id, content: {:agent_chat, :semantic}} -> id
        %Window{content: {:subagent_peek, {id, _identity}}} -> id
        _other -> Enum.find_value(windows.map, &conversation_window/1)
      end

    with id when is_integer(id) <- parent,
         {_, _} = child <- latest_child(state) do
      open(state, id, child)
    else
      _empty ->
        MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, "No subagents to inspect")
    end
  end

  @spec conversation_window({Window.id(), Window.t()}) :: Window.id() | nil
  defp conversation_window({id, %Window{content: {:agent_chat, :semantic}}}), do: id
  defp conversation_window(_other), do: nil

  @doc "Opens or changes an exact pane from a committed frontend activation."
  @spec click(
          State.t(),
          click(),
          Window.id(),
          binary(),
          binary(),
          {non_neg_integer(), non_neg_integer()}
        ) ::
          State.t()
  def click(state, action, parent, displayed, target, {0, 0})
      when action in [:started, :started_key] and byte_size(displayed) <= 20 do
    with {task, subagents} <- current_task(state),
         {_, _, _} = key <- identify(subagents, task, target) do
      activate_started(state, action, parent, {task, key}, displayed)
    else
      _stale -> state
    end
  end

  def click(state, :insert_text, 65_534, displayed, text, {0, 0})
      when byte_size(displayed) <= 20 do
    case Integer.parse(displayed) do
      {generation, ""} when generation > 0 ->
        PromptInput.insert_displayed(state, generation, text)

      _other ->
        state
    end
  end

  def click(state, action, window_id, displayed, target, position)
      when action not in [:started, :started_key] do
    with {:ok, %Window{content: {:subagent_peek, {parent, {task, _key} = identity}}}} <-
           Windows.fetch(state.workspace.windows, window_id),
         ^displayed <- Subagent.action_token(identity),
         {^task, subagents} <- current_task(state) do
      click_peek(state, action, {window_id, identity}, parent, subagents, target, position)
    else
      _stale -> state
    end
  end

  def click(state, _action, _window, _displayed, _target, _position), do: state

  @spec activate_started(
          State.t(),
          :started | :started_key,
          Window.id(),
          SessionManager.foreground_identity(),
          binary()
        ) :: State.t()
  defp activate_started(state, :started, parent, identity, ""),
    do: open(state, parent, identity)

  defp activate_started(state, :started_key, parent, identity, displayed) do
    case FocusOwner.derive(state) do
      %{surface: :agent, responder: :editor_view, window_id: ^parent} ->
        if state.workspace.agent_ui.panel.input_focused,
          do: forward_started_return(state, displayed),
          else: open(state, parent, identity)

      _other ->
        state
    end
  end

  defp activate_started(state, :started, _parent, _identity, _displayed), do: state

  @spec forward_started_return(State.t(), binary()) :: State.t()
  defp forward_started_return(state, ""), do: MingaEditor.Input.Router.route_key(state, 13, 0)

  defp forward_started_return(state, displayed) do
    case Integer.parse(displayed) do
      {offer, ""} when offer > 0 ->
        PromptInput.with_offer(state, offer, &MingaEditor.Input.Router.route_key(&1, 13, 0))

      _other ->
        state
    end
  end

  @spec identify([Subagent.t()], String.t(), binary()) :: Invocation.key() | nil
  defp identify(subagents, task, target) do
    Enum.find_value(subagents, fn
      %Subagent{invocation_key: nil} -> nil
      %Subagent{invocation_key: key} -> if Subagent.action_token({task, key}) == target, do: key
    end)
  end

  @spec click_peek(
          State.t(),
          click(),
          SubagentPeekComposer.target(),
          Window.id(),
          [Subagent.t()],
          binary(),
          {non_neg_integer(), non_neg_integer()}
        ) :: State.t()
  defp click_peek(state, :sibling, {_, {task, key}}, parent, subagents, target, {0, 0}) do
    case identify(Subagent.siblings(subagents, key), task, target) do
      nil -> state
      sibling -> open(state, parent, {task, sibling})
    end
  end

  defp click_peek(state, :compose, {window, _identity} = target, parent, _subs, "", position) do
    state
    |> focus_peek(window, parent)
    |> SubagentPeekComposer.focus(target)
    |> SubagentPeekComposer.edit(target, {:move_to, position})
  end

  defp click_peek(state, :insert_text, target, _parent, _subs, text, {0, 0}) do
    case FocusOwner.derive(state) do
      %{responder: :editor_view, surface: :agent} ->
        SubagentPeekComposer.edit(state, target, {:insert, text})

      _other ->
        state
    end
  end

  defp click_peek(state, action, {window, _identity} = target, parent, _subs, "", {0, 0})
       when action in [:brief, :submit, :close, :inspect] do
    focused = focus_peek(state, window, parent)

    case action do
      :brief ->
        SubagentPeekSession.toggle_brief(focused)

      :submit ->
        focused |> SubagentPeekComposer.focus(target) |> SubagentPeekComposer.submit(target)

      :close ->
        close(focused)

      :inspect ->
        SubagentPeekComposer.blur(focused)
    end
  end

  defp click_peek(state, _action, _target, _parent, _subs, _token, _position), do: state

  @doc "Opens the most recent fan-out from this parent, starting at its first sibling."
  @spec open_latest(State.t(), Window.id()) :: State.t()
  def open_latest(%State{} = state, parent_window) do
    case latest_child(state) do
      {_, _} = child -> open(state, parent_window, child)
      nil -> state
    end
  end

  @spec latest_child(State.t()) :: SessionManager.foreground_identity() | nil
  defp latest_child(state) do
    with {parent_task, subagents} <- current_task(state),
         {_, _, _} = key <- latest_invocation(subagents),
         [%{invocation_key: first} | _] <- Tasks.Subagent.siblings(subagents, key) do
      {parent_task, first}
    else
      _unavailable -> nil
    end
  end

  @doc "Opens a Started row's exact child beside the named, still-present parent window."
  @spec open(State.t(), Window.id(), SessionManager.foreground_identity()) :: State.t()
  def open(%State{} = state, parent_window, {parent_task, key} = identity) do
    windows = state.workspace.windows

    with {^parent_task, subagents} <- current_task(state),
         {:ok, %Window{content: {:agent_chat, :semantic}} = parent} <-
           Windows.fetch(windows, parent_window) do
      if Enum.any?(subagents, &(&1.invocation_key == key)) do
        show(state, windows, parent, {parent_window, identity})
      else
        state
      end
    else
      _stale -> state
    end
  end

  @doc "Moves one sibling, staying at either end of the current fan-out."
  @spec step(State.t(), :previous | :next) :: State.t()
  def step(%State{} = state, direction) do
    with %Window{content: {:subagent_peek, {parent, {task, key}}}} <-
           Windows.active_struct(state.workspace.windows),
         {^task, subagents} <- current_task(state),
         %{invocation_key: next} <-
           neighbor(Tasks.Subagent.siblings(subagents, key), key, direction) do
      open(state, parent, {task, next})
    else
      _unavailable -> state
    end
  end

  @doc "Removes the active peek and restores its originating parent when it survives."
  @spec close(State.t()) :: State.t()
  def close(%State{} = state) do
    case Windows.active_struct(state.workspace.windows) do
      %Window{content: {:subagent_peek, {parent, _identity}}} = peek ->
        remove_peek(state, peek, parent)

      _not_a_peek ->
        state
    end
  end

  @doc "Removes the dependent peek before its parent conversation closes."
  @spec close_for_parent(State.t(), Window.id()) :: State.t()
  def close_for_parent(%State{} = state, parent) do
    case peek_for_parent(state.workspace.windows, parent) do
      %Window{} = peek -> remove_peek(state, peek, parent)
      nil -> state
    end
  end

  @doc "Attaches a restored workspace's exact peek, or retires the split if its parent record no longer exists."
  @spec resume_in_workspace(State.t()) :: State.t()
  def resume_in_workspace(%State{} = state) do
    peek =
      Enum.find_value(state.workspace.windows.map, fn
        {_id, %Window{content: {:subagent_peek, _}} = window} -> window
        _other -> nil
      end)

    case peek do
      %Window{content: {:subagent_peek, {parent, {task, _} = identity}}} = window ->
        cond do
          visible_parent?(state, parent, task) ->
            SubagentPeekSession.select(state, identity)

          Arrival.pending?(state, Runtime.active_session(state.shell_runtime)) ->
            state
            |> SubagentPeekComposer.blur()
            |> SubagentPeekSession.close()
            |> focus_parent_during_arrival(window, parent)

          true ->
            state = state |> SubagentPeekComposer.blur() |> SubagentPeekSession.close()
            remove_peek(state, window, parent)
        end

      nil ->
        state |> SubagentPeekComposer.blur() |> SubagentPeekSession.close()
    end
  end

  @spec focus_parent_during_arrival(State.t(), Window.t(), Window.id()) :: State.t()
  defp focus_parent_during_arrival(
         %State{workspace: %{windows: %{active: id}}} = state,
         %Window{id: id},
         parent
       ),
       do: WindowFocus.focus(state, parent)

  defp focus_parent_during_arrival(state, _window, _parent), do: state

  @spec visible_parent?(State.t(), Window.id(), String.t()) :: boolean()
  defp visible_parent?(
         %State{
           workspace: %{agent_ui: %{chat_lifecycle: {:conversation, _}} = ui, windows: windows}
         },
         parent,
         task
       ) do
    UIState.task_id(ui) == task and
      match?({:ok, %Window{content: {:agent_chat, :semantic}}}, Windows.fetch(windows, parent))
  end

  defp visible_parent?(_state, _parent, _task), do: false

  @spec remove_peek(State.t(), Window.t(), Window.id()) :: State.t()
  defp remove_peek(state, %Window{id: id, content: {:subagent_peek, {_, identity}}}, parent) do
    windows = state.workspace.windows

    case Windows.remove_window(windows, id) do
      {:ok, remaining} ->
        target =
          cond do
            windows.active != id -> windows.active
            Map.has_key?(remaining.map, parent) -> parent
            true -> hd(WindowTree.leaves(remaining.tree))
          end

        state
        |> WindowFocus.focus_surviving_window(remaining, target)
        |> release_peek(identity)
        |> Layout.invalidate()

      :error ->
        state
    end
  end

  @spec release_peek(State.t(), SessionManager.foreground_identity()) :: State.t()
  defp release_peek(
         %State{agent_connection: %{peek_session: %{identity: identity}}} = state,
         identity
       ) do
    state |> SubagentPeekComposer.blur() |> SubagentPeekSession.close()
  end

  defp release_peek(state, _identity), do: state

  @spec peek_for_parent(Windows.t(), Window.id()) :: Window.t() | nil
  defp peek_for_parent(windows, parent) do
    Enum.find_value(windows.map, fn
      {_id, %Window{content: {:subagent_peek, {^parent, _identity}}} = peek} -> peek
      _other -> nil
    end)
  end

  @spec current_task(State.t()) :: {String.t(), [Tasks.Subagent.t()]} | nil
  defp current_task(
         %State{workspace: %{agent_ui: %{chat_lifecycle: {:conversation, pid}} = ui}} = state
       ) do
    with task_id when is_binary(task_id) <- UIState.task_id(ui),
         {:ok, entry} <- Tasks.fetch(state.agent_connection.tasks, pid, task_id) do
      {task_id, entry.subagents}
    else
      _unavailable -> nil
    end
  end

  defp current_task(%State{}), do: nil

  @spec latest_invocation([Tasks.Subagent.t()]) :: Invocation.key() | nil
  defp latest_invocation(subagents) do
    Enum.reduce(subagents, nil, fn
      %{invocation_key: nil}, previous -> previous
      %{invocation_key: key}, _previous -> key
    end)
  end

  @spec neighbor([Tasks.Subagent.t()], Invocation.key(), :previous | :next) ::
          Tasks.Subagent.t() | nil
  defp neighbor(subagents, key, direction), do: neighbor(subagents, key, direction, nil)

  @spec neighbor(
          [Tasks.Subagent.t()],
          Invocation.key(),
          :previous | :next,
          Tasks.Subagent.t() | nil
        ) ::
          Tasks.Subagent.t() | nil
  defp neighbor([%{invocation_key: key} | _], key, :previous, previous), do: previous
  defp neighbor([%{invocation_key: key} | rest], key, :next, _previous), do: List.first(rest)

  defp neighbor([item | rest], key, direction, _previous),
    do: neighbor(rest, key, direction, item)

  defp neighbor([], _key, _direction, _previous), do: nil

  @spec show(State.t(), Windows.t(), Window.t(), Content.peek_ref()) :: State.t()
  defp show(state, windows, parent, {parent_id, identity} = ref) do
    case peek_for_parent(windows, parent_id) do
      %Window{id: id} = peek ->
        next = Windows.replace_window(windows, id, Window.show_subagent(peek, ref))
        install(state, next, id, parent_id, identity)

      nil ->
        {id, windows} = Windows.allocate_id(windows)

        case WindowTree.split(windows.tree, parent_id, :vertical, id) do
          {:ok, tree} ->
            next =
              windows
              |> Windows.set_tree(tree)
              |> Windows.add_window(Window.new_subagent_peek(id, ref, parent.viewport))

            install(state, next, id, parent_id, identity)

          :error ->
            state
        end
    end
  end

  @spec install(
          State.t(),
          Windows.t(),
          Window.id(),
          Window.id(),
          SessionManager.foreground_identity()
        ) ::
          State.t()
  defp install(state, windows, peek_id, parent_id, identity) do
    state = %{state | workspace: SessionState.set_windows(state.workspace, windows)}

    state
    |> focus_peek(peek_id, parent_id)
    |> SubagentPeekComposer.blur()
    |> SubagentPeekSession.select(identity)
    |> Layout.invalidate()
  end

  @spec focus_peek(State.t(), Window.id(), Window.id()) :: State.t()
  defp focus_peek(state, peek, parent) do
    workspace = state.workspace
    prompt = workspace.agent_ui.panel.prompt_buffer

    # Leader commands use a temporary prompt buffer with no semantic window cursor to save.
    if workspace.windows.active == parent and is_pid(prompt) and
         workspace.buffers.active == prompt do
      case WindowFocus.restore_focus(state, peek) do
        {:ok, focused} -> focused
        :error -> state
      end
    else
      WindowFocus.focus(state, peek)
    end
  end
end
