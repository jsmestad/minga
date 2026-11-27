defmodule MingaEditor.RenderModel.UI.TasksDrawerBuilder do
  @moduledoc """
  Builds the tasks drawer's semantic model (`Minga.RenderModel.UI.TasksDrawer`) from the editor's tasks and the drawer's presentation state.

  Pure: the caller passes the tasks, the drawers and the wall-clock time the frame is for, so ages and retry countdowns are words the BEAM wrote.
  """

  alias Minga.Design.Tokens
  alias Minga.RenderModel.UI.EmptyList
  alias Minga.RenderModel.UI.TasksDrawer
  alias Minga.RenderModel.UI.TasksDrawer.Row
  alias MingaEditor.Agent.Tasks
  alias MingaEditor.Agent.Tasks.Entry
  alias MingaEditor.Agent.Tasks.Starting
  alias MingaEditor.Agent.Tasks.Subagent
  alias MingaEditor.RenderModel.UI.EmptyStateBuilder
  alias MingaEditor.Shell.Traditional.Drawers

  @approval_actions [
    {"y", "Approve once"},
    {"a", "Always for this session"},
    {"t", "This turn"},
    {"n", "Deny"},
    {"=", "Show diff"},
    {"↩", "Open conversation"}
  ]

  # Each state offers its one relevant action (docs/design/surfaces.md, "Tasks").
  @state_actions %{
    working: [{"i", "Inspect"}, {"↩", "Open"}],
    waiting: [{"r", "Retry now"}],
    failed: [{"o", "Output"}, {"r", "Retry"}],
    stopped: [{"r", "Continue"}, {"o", "Output"}],
    done: [{"↩", "Review"}]
  }

  @list_hints [{"j/k", "move"}, {"↩", "open"}, {"c", "new task"}, {"x", "stop"}, {"q", "close"}]
  @diff_hints [
    {"y", "once"},
    {"a", "always"},
    {"t", "this turn"},
    {"n", "deny"},
    {"]h", "next"},
    {"esc", "back"}
  ]
  @output_hints [{"r", "retry"}, {"j/k", "scroll"}, {"q", "back"}]

  @hidden_names %{messages: "Messages"}

  # The empty state (docs/design/surfaces.md, "Tasks"; board Batch1_minga_tasks_empty): what happened, why, next steps.
  @empty_title "No one's at the table yet."
  @empty_why "Give Minga a task. Each one gets its own conversation, review and place in the modeline."
  @empty_steps [
    {:agent_new_task, "New task", "c"},
    {:agent_session_history, "Resume an earlier session"}
  ]
  @empty_hints [{"j/k", "move"}, {"↩", "run"}, {"q", "close"}]

  # Titles and words come from goals, tool names and provider errors, so their length is the user's or the
  # provider's. A row shows at most this many characters, then "…"; the conversation keeps the whole text.
  @max_text 400

  # A diff or output view shows at most this many lines, then says how many more there are, and each line at most
  # this many bytes; provider errors are not bounded upstream.
  @max_view_lines 5_000
  @max_line_bytes 16_384

  @doc "The drawer's model for this frame."
  @spec build(Tasks.t(), Drawers.t(), integer()) :: TasksDrawer.t()
  def build(%Tasks{} = tasks, %Drawers{} = drawers, now) when is_integer(now) do
    if Drawers.showing?(drawers, :tasks) do
      nodes = Tasks.tree(tasks)
      selected = selected_id(nodes, drawers.selected)
      focused? = Drawers.focused?(drawers, :tasks)

      empty = if nodes == [], do: empty_list(drawers.empty_selected)

      %TasksDrawer{
        visible?: true,
        focused?: focused?,
        note: note(Drawers.hidden_under(drawers, :tasks)),
        counts: counts(tasks),
        rows: rows(nodes, selected, now),
        hints: if(focused?, do: hints(drawers.view, empty), else: []),
        prompt: prompt(tasks, drawers.pending),
        empty: empty
      }
      |> with_view(tasks, drawers, now)
    else
      TasksDrawer.hidden()
    end
  end

  @doc "The task entry a row id names, or nil for a subagent row or a row that is gone."
  @spec entry_for(Tasks.t(), String.t() | nil) :: Entry.t() | nil
  def entry_for(%Tasks{} = tasks, row_id) when is_binary(row_id) do
    Enum.find_value(Tasks.tree(tasks), fn
      %{item: %Entry{} = entry} = node -> if row_id(node) == row_id, do: entry
      _subagent -> nil
    end)
  end

  def entry_for(%Tasks{}, nil), do: nil

  @doc "The task a row belongs to: the row's own task, or a foreground subagent's parent task."
  @spec owner_for(Tasks.t(), String.t() | nil) :: Entry.t() | nil
  def owner_for(%Tasks{} = tasks, row_id) when is_binary(row_id) do
    Enum.find_value(Tasks.tree(tasks), fn node ->
      if row_id(node) == row_id, do: owner(tasks, node)
    end)
  end

  def owner_for(%Tasks{}, nil), do: nil

  @spec owner(Tasks.t(), Tasks.node_t()) :: Entry.t() | nil
  defp owner(_tasks, %{item: %Entry{} = entry}), do: entry

  defp owner(tasks, %{item: %Subagent{}, parent: parent}) do
    case Tasks.fetch(tasks, parent) do
      {:ok, entry} -> entry
      :error -> nil
    end
  end

  @doc """
  The lines a request's diff view shows: what it asks, then the preview's lines, within `bound/1`.

  The drawer's scrolling, change jumps and the view itself all read these lines, so they agree on what is on screen.
  """
  @spec diff_lines(Entry.t()) :: [String.t()]
  def diff_lines(%Entry{} = entry) do
    case entry.approval do
      %MingaEditor.Agent.PendingApproval{approval: %{preview: preview}} -> bound(preview.lines)
      nil -> []
    end
  end

  @doc "The lines a task's output view shows: each tool result in order, then the failure, if any, within `bound/1`."
  @spec output_lines(Entry.t()) :: [String.t()]
  def output_lines(%Entry{} = entry) do
    results =
      Enum.flat_map(Entry.outputs(entry), fn {name, result} ->
        ["$ #{name}" | String.split(result, "\n")] ++ [""]
      end)

    failure = if entry.failure, do: String.split(entry.failure, "\n"), else: []

    case results ++ failure do
      [] -> ["Nothing has run yet."]
      lines -> bound(lines)
    end
  end

  @doc "The identity of a tree node, as rows and clicks carry it."
  @spec row_id(Tasks.node_t()) :: String.t()
  def row_id(%{item: %Entry{seq: seq}}), do: "t#{seq}"
  def row_id(%{item: %Starting{seq: seq}}), do: "t#{seq}"

  def row_id(%{item: %Subagent{invocation_key: key}, parent_seq: seq})
      when is_integer(seq) and not is_nil(key) do
    "t#{seq}.i.#{Base.url_encode64(:erlang.term_to_binary(key), padding: false)}"
  end

  def row_id(%{item: %Subagent{id: id}, parent_seq: seq}) when is_integer(seq),
    do: "t#{seq}.#{id}"

  @doc "The row ids in display order, for moving the selection."
  @spec row_ids(Tasks.t()) :: [String.t()]
  def row_ids(%Tasks{} = tasks), do: tasks |> Tasks.tree() |> Enum.map(&row_id/1)

  @doc "The id of the row the drawer selects: the remembered one while it exists, else the first."
  @spec selected_id([Tasks.node_t()], String.t() | nil) :: String.t() | nil
  def selected_id([], _remembered), do: nil

  def selected_id([first | _rest] = nodes, remembered) do
    if Enum.any?(nodes, &(row_id(&1) == remembered)), do: remembered, else: row_id(first)
  end

  @spec rows([Tasks.node_t()], String.t() | nil, integer()) :: [Row.t()]
  defp rows(nodes, selected, now) do
    last_children = last_children(nodes)

    Enum.map(nodes, fn node ->
      id = row_id(node)
      row(node, id, id == selected, MapSet.member?(last_children, id), now)
    end)
  end

  @spec row(Tasks.node_t(), String.t(), boolean(), boolean(), integer()) :: Row.t()
  defp row(%{item: %Entry{} = entry, depth: depth}, id, selected?, last?, now) do
    state = Entry.state(entry)

    %Row{
      id: id,
      depth: depth,
      last?: last?,
      state: state,
      title: fit(Entry.title(entry)),
      words: fit(Entry.words(entry, now)),
      age: age(now - entry.changed_at),
      detail: detail(state, entry, selected?),
      actions: actions(state),
      selected?: selected?
    }
  end

  defp row(%{item: %Starting{} = start}, id, selected?, _last?, now) do
    %Row{
      id: id,
      state: Starting.state(start),
      title: fit(start.title),
      words: fit(Starting.words(start)),
      age: age(now - start.started_at),
      selected?: selected?
    }
  end

  defp row(%{item: %Subagent{} = subagent, depth: depth}, id, selected?, last?, now) do
    %Row{
      id: id,
      depth: depth,
      last?: last?,
      state: subagent.state,
      title: fit(subagent.title),
      words: Tokens.state_word(subagent.state),
      age: age(now - subagent.changed_at),
      selected?: selected?
    }
  end

  # The needs-you row expands, while selected, to show what it is asking.
  @spec detail(Entry.state() | nil, Entry.t(), boolean()) :: [String.t()]
  defp detail(:needs_you, entry, true) do
    case Entry.request(entry) do
      nil -> []
      request -> [fit(request)]
    end
  end

  defp detail(_state, _entry, _selected?), do: []

  @spec actions(Entry.state() | nil) :: [TasksDrawer.hint()]
  defp actions(:needs_you), do: @approval_actions
  defp actions(state), do: Map.get(@state_actions, state, [])

  @spec counts(Tasks.t()) :: [TasksDrawer.count()]
  # Needs-you first, like the rows, then the design tokens' state order.
  defp counts(tasks) do
    counts = Tasks.counts(tasks)
    order = [:needs_you | List.delete(Tokens.state_ids(), :needs_you)]

    for state <- order, count = Map.get(counts, state), do: {state, count}
  end

  @spec hints(Drawers.view(), EmptyList.t() | nil) :: [TasksDrawer.hint()]
  defp hints(:list, %EmptyList{}), do: @empty_hints
  defp hints(:list, nil), do: @list_hints
  defp hints({:diff, _row}, _empty), do: @diff_hints
  defp hints({:output, _row}, _empty), do: @output_hints

  @doc "The empty state of a drawer with no tasks, with the next step at `selected` preselected."
  @spec empty_list(non_neg_integer()) :: EmptyList.t()
  def empty_list(selected) when is_integer(selected) and selected >= 0 do
    EmptyStateBuilder.empty_list(@empty_title, @empty_why, @empty_steps,
      selected: min(selected, length(@empty_steps) - 1)
    )
  end

  @doc "The commands the empty state's next steps run, in order."
  @spec empty_commands() :: [atom()]
  def empty_commands, do: Enum.map(@empty_steps, &elem(&1, 0))

  @spec prompt(Tasks.t(), {:stop, String.t(), {String.t(), String.t()}} | nil) :: String.t()
  defp prompt(_tasks, nil), do: ""

  defp prompt(tasks, {:stop, row_id, _target}) do
    case entry_for(tasks, row_id) do
      %Entry{} = entry -> "Stop “#{fit(Entry.title(entry))}”? y stop · n keep it running"
      nil -> ""
    end
  end

  # A diff or output view whose task is gone falls back to the list.
  @spec with_view(TasksDrawer.t(), Tasks.t(), Drawers.t(), integer()) :: TasksDrawer.t()
  defp with_view(drawer, tasks, %Drawers{view: {kind, row_id}, offset: offset}, now) do
    case entry_for(tasks, row_id) do
      %Entry{} = entry ->
        lines = if kind == :diff, do: diff_lines(entry), else: output_lines(entry)

        %{
          drawer
          | view: kind,
            view_title: view_title(kind, entry, now),
            view_lines: lines,
            view_offset: min(offset, max(length(lines) - 1, 0))
        }

      nil ->
        %{drawer | hints: if(drawer.focused?, do: @list_hints, else: [])}
    end
  end

  defp with_view(drawer, _tasks, %Drawers{}, _now), do: drawer

  @spec view_title(:diff | :output, Entry.t(), integer()) :: String.t()
  defp view_title(:diff, entry, _now),
    do: "#{fit(Entry.title(entry))} · #{fit(Entry.request(entry) || Entry.words(entry, 0))}"

  defp view_title(:output, entry, now),
    do: "#{fit(Entry.title(entry))} · #{fit(Entry.words(entry, now))}"

  @doc "Text cut to what a row shows: at most #{@max_text} characters, ending in an ellipsis when cut."
  @spec fit(String.t()) :: String.t()
  def fit(text) when is_binary(text) do
    if String.length(text) > @max_text,
      do: String.slice(text, 0, @max_text - 1) <> "…",
      else: text
  end

  @doc """
  A view's lines, at most #{@max_view_lines}, each at most #{@max_line_bytes} bytes; a longer view ends with a line that says how many more there are, and a longer line ends in an ellipsis.
  """
  @spec bound([String.t()]) :: [String.t()]
  def bound(lines) when is_list(lines) do
    {shown, rest} = Enum.split(lines, @max_view_lines)
    Enum.map(shown, &cut_line/1) ++ more_lines(length(rest))
  end

  @spec cut_line(String.t()) :: String.t()
  defp cut_line(line) when byte_size(line) <= @max_line_bytes, do: line

  defp cut_line(line),
    do: String.replace_invalid(binary_part(line, 0, @max_line_bytes - 3)) <> "…"

  @spec more_lines(non_neg_integer()) :: [String.t()]
  defp more_lines(0), do: []
  defp more_lines(count), do: ["… #{count} more lines, in the conversation"]

  @spec note(Drawers.kind() | nil) :: String.t()
  defp note(nil), do: ""
  defp note(kind), do: "#{Map.fetch!(@hidden_names, kind)} hidden · q returns"

  @spec last_children([Tasks.node_t()]) :: MapSet.t(String.t())
  defp last_children(nodes) do
    nodes
    |> Enum.filter(&(&1.depth > 0))
    |> Enum.group_by(& &1.parent)
    |> Enum.map(fn {_parent, children} -> children |> List.last() |> row_id() end)
    |> MapSet.new()
  end

  @doc ~S(A short age: "now", "40s", "4m", "2h", "3d".)
  @spec age(integer()) :: String.t()
  def age(ms) when ms < 5_000, do: "now"
  def age(ms) when ms < 60_000, do: "#{div(ms, 1000)}s"
  def age(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)}m"
  def age(ms) when ms < 86_400_000, do: "#{div(ms, 3_600_000)}h"
  def age(ms), do: "#{div(ms, 86_400_000)}d"
end
