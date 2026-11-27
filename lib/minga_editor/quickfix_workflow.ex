defmodule MingaEditor.QuickfixWorkflow do
  @moduledoc "Visits shared quickfix entries through an explicit file window."

  alias Minga.Buffer
  alias Minga.Command.Parser
  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.KeyDispatch
  alias MingaEditor.Layout
  alias MingaEditor.Quickfix
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.TaskReviewWorkflow
  alias MingaEditor.State
  alias MingaEditor.State.Windows
  alias MingaEditor.{Window, WindowFocus}

  @spec step(State.t(), :next | :previous) :: State.t()
  def step(state, direction) do
    case Quickfix.move(state.interaction.quickfix, direction) do
      :empty -> NoticeWorkflow.publish(state, "The quickfix list is empty")
      {entry, list} -> state |> State.put_quickfix(list) |> visit(entry) |> announce_visit()
    end
  end

  @doc "Runs one Ex command per current location. Refuses to run on a stale or different target."
  @spec each(State.t(), String.t()) :: State.t()
  def each(state, command) do
    case Parser.parse(command) do
      {kind, _} when kind in [:unknown, :quickfix_do] ->
        NoticeWorkflow.publish(state, "Specify an Ex command to run at each quickfix location")

      {:minga_review, range, decision} = parsed ->
        case state.interaction.quickfix.source do
          {:task_review, _, _, _} when range == :current_line ->
            TaskReviewWorkflow.decide_quickfix(state, decision)

          {:task_review, _, _, _} ->
            NoticeWorkflow.publish(
              state,
              "A range cannot replace the exact quickfix review units"
            )

          _ ->
            each_item(state, parsed)
        end

      parsed ->
        each_item(state, parsed)
    end
  end

  @spec each_item(State.t(), Parser.parsed()) :: State.t()
  defp each_item(state, parsed) do
    case Quickfix.entries(state.interaction.quickfix) do
      [] -> NoticeWorkflow.publish(state, "The quickfix list is empty")
      entries -> Enum.reduce_while(entries, state, &execute_item(&1, &2, parsed))
    end
  end

  @spec execute_item(Quickfix.entry(), State.t(), Parser.parsed()) :: {:cont | :halt, State.t()}
  defp execute_item(entry, state, parsed) do
    case visit(state, entry) do
      {:ok, focused} ->
        command =
          if match?({:normal, :whole_buffer, _}, parsed), do: normal_at_item(parsed), else: parsed

        next = KeyDispatch.dispatch_command(focused, {:execute_ex_command, command})

        if next.workspace.editing.pending_keep != nil or Minga.Editing.mode(next) != :normal do
          {:halt,
           NoticeWorkflow.publish(
             next,
             "Quickfix stopped at a command that needs another input or decision"
           )}
        else
          {:cont, next}
        end

      {:error, _} = error ->
        {:halt, announce_visit(error)}
    end
  end

  @spec normal_at_item({:normal, :whole_buffer, String.t()}) :: Parser.parsed()
  defp normal_at_item({:normal, :whole_buffer, keys}), do: {:normal, :current_line, keys}

  @spec visit(State.t(), Quickfix.entry()) :: {:ok | :error, State.t()}
  defp visit(state, {_path, _, {:review_unit, buffer, unit}}) do
    window_id =
      case TaskReviewWorkflow.focused(state) do
        {_, {_, _, parent}} -> parent
        nil -> state.workspace.windows.active
      end

    visit_unit(state, window_id, buffer, unit)
  end

  defp visit(state, {path, position, :file}) do
    opened = BufferManagement.execute(state, {:execute_ex_command, {:edit, path}})

    with buffer when is_pid(buffer) <- opened.workspace.buffers.active,
         ^path <- Buffer.file_path(buffer),
         :ok <- Buffer.move_to(buffer, position) do
      {:ok, opened}
    else
      _ -> {:error, opened}
    end
  catch
    :exit, _ -> {:error, state}
  end

  @doc "Visits the relocated position of the same pending unit without replacing another split."
  @spec jump_unit(State.t(), Window.id(), pid(), Minga.Buffer.UndoHistory.review_location()) ::
          State.t()
  def jump_unit(state, window_id, buffer, unit) do
    state |> visit_unit(window_id, buffer, unit) |> announce_visit()
  end

  @spec visit_unit(State.t(), Window.id(), pid(), Minga.Buffer.UndoHistory.review_location()) ::
          {:ok | :error, State.t()}
  defp visit_unit(state, window_id, buffer, unit) do
    windows = state.workspace.windows

    with {:ok, %Window{content: {:buffer, _}} = window} <- Windows.fetch(windows, window_id),
         {:ok, position} <- Buffer.move_to_review_unit(buffer, unit) do
      target = window |> Window.show_buffer(buffer) |> Window.set_cursor(position)
      windows = Windows.replace_window(windows, window_id, target)
      focused = WindowFocus.focus_surviving_window(state, windows, window_id)

      case focused do
        %State{workspace: %{windows: %{active: ^window_id}, buffers: %{active: ^buffer}}} ->
          {:ok, Layout.invalidate(focused)}

        _ ->
          {:error, state}
      end
    else
      _ -> {:error, state}
    end
  catch
    :exit, _ -> {:error, state}
  end

  @spec announce_visit({:ok | :error, State.t()}) :: State.t()
  defp announce_visit({:ok, state}), do: state

  defp announce_visit({:error, state}),
    do: NoticeWorkflow.publish(state, "The quickfix location is unavailable")
end
