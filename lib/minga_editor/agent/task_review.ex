defmodule MingaEditor.Agent.TaskReview do
  @moduledoc "The task review tree. File history supplies offers; the tree records completed decisions and never decides from a line number."

  alias Minga.Buffer.Document
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Buffer.UndoHistory

  @type key :: {pid(), UndoHistory.review_location()}
  @type entry :: {key(), String.t(), Document.position() | nil, BufferProcess.review_target()}
  @type decision :: :keep | :reject
  @type location :: MingaEditor.Quickfix.entry()
  @type file_offer :: {pid(), String.t(), BufferProcess.task_review_offer()}
  @type t :: %__MODULE__{
          task: String.t(),
          title: String.t(),
          status: String.t() | nil,
          root: Path.t() | nil,
          pending: [entry()],
          decisions: [{Path.t(), non_neg_integer(), non_neg_integer()}],
          unavailable: [String.t()],
          all: [{pid(), BufferProcess.review_target()}],
          selected: key() | nil,
          inline_diff: {key(), [String.t()]} | nil
        }

  @enforce_keys [:task, :title]
  defstruct [
    :task,
    :title,
    :status,
    :root,
    :selected,
    :inline_diff,
    pending: [],
    decisions: [],
    unavailable: [],
    all: []
  ]

  @spec new(String.t(), String.t()) :: t()
  def new(task, title), do: %__MODULE__{task: task, title: title}

  @spec describe(t(), String.t(), String.t() | nil, Path.t() | nil) :: t()
  def describe(%__MODULE__{} = review, title, status, root),
    do: %{review | title: title, status: status, root: root}

  @doc "Updates from one set of file observations. A missing history blocks completion, even when there are no offers."
  @spec refresh(t(), [file_offer()], [String.t()]) :: t()
  def refresh(%__MODULE__{} = review, files, unavailable) do
    files = Enum.sort_by(files, &elem(&1, 1))

    pending =
      for {buffer, path, {entries, _, _}} <- files,
          {unit, target, ranges} <- Enum.sort_by(entries, &elem(&1, 2)) do
        {{buffer, unit}, path, first_position(ranges), target}
      end

    all = for {buffer, _, {_, target, _}} <- files, target != nil, do: {buffer, target}

    decisions =
      for {_, path, {_, _, {kept, rejected}}} <- files,
          kept + rejected > 0,
          do: {path, kept, rejected}

    %{
      review
      | pending: pending,
        decisions: decisions,
        all: all,
        unavailable: Enum.sort(unavailable),
        selected: retained_selection(review.selected, pending),
        inline_diff: nil
    }
  end

  @spec first_position([{Document.position(), Document.position()}]) :: Document.position() | nil
  defp first_position([{position, _} | _]), do: position
  defp first_position([]), do: nil

  @spec retained_selection(key() | nil, [entry()]) :: key() | nil
  defp retained_selection(_key, []), do: nil

  defp retained_selection(key, [{first, _, _, _} | _] = pending) do
    if List.keymember?(pending, key, 0), do: key, else: first
  end

  @spec selected(t()) :: entry() | nil
  def selected(%__MODULE__{pending: pending, selected: key}), do: List.keyfind(pending, key, 0)

  @spec navigate(t(), :next | :previous) :: t()
  def navigate(%__MODULE__{pending: []} = review, _), do: review

  def navigate(%__MODULE__{} = review, direction) do
    key = review.selected

    entry =
      case direction do
        :next -> next_entry(review.pending, key, hd(review.pending))
        :previous -> previous_entry(review.pending, key, nil)
      end

    %{review | selected: elem(entry, 0), inline_diff: nil}
  end

  @spec next_entry([entry()], key() | nil, entry()) :: entry()
  defp next_entry([{key, _, _, _}, next | _], key, _first), do: next
  defp next_entry([_ | rest], key, first), do: next_entry(rest, key, first)
  defp next_entry([], _key, first), do: first

  @spec previous_entry([entry()], key() | nil, entry() | nil) :: entry()
  defp previous_entry([{key, _, _, _} | _], key, previous) when previous != nil, do: previous
  defp previous_entry([entry | rest], key, _previous), do: previous_entry(rest, key, entry)
  defp previous_entry([], _key, previous), do: previous

  @spec show_diff(t(), key(), [String.t()]) :: t()
  def show_diff(%__MODULE__{selected: key} = review, key, lines),
    do: %{review | inline_diff: {key, lines}}

  def show_diff(%__MODULE__{} = review, _superseded, _lines), do: review

  @spec hide_diff(t()) :: t()
  def hide_diff(%__MODULE__{} = review), do: %{review | inline_diff: nil}

  @doc "The shared locations projection includes only unreviewed changes, in tree order."
  @spec locations(t()) :: [location()]
  def locations(%__MODULE__{pending: pending}) do
    for {{buffer, unit}, path, position, _} <- pending, position != nil do
      {path, position, {:review_unit, buffer, unit}}
    end
  end

  @doc "Builds the read-only buffer text and returns the cursor row of the selected change."
  @spec text(t()) :: {String.t(), non_neg_integer()}
  def text(%__MODULE__{} = review) do
    header = [
      review.title,
      Enum.join(Enum.reject([review.status, file_count(review)], &is_nil/1), " · "),
      review_actions(review),
      if(review.pending == [], do: "", else: "]h Next  [h Previous  ↩ Go to  q Close"),
      "",
      "Unreviewed"
    ]

    pending = tree(review.pending, review, review.root)
    row = length(header) + (Enum.find_index(pending, &String.starts_with?(&1, "  › ")) || 0)

    unavailable =
      Enum.map(review.unavailable, &"  History unavailable: #{relative(&1, review.root)}")

    sections = [header, pending, unavailable, ["", "Kept"], decision_lines(review, 1)]
    rejected = decision_lines(review, 2)
    sections = if rejected == [], do: sections, else: [sections, ["", "Rejected"], rejected]

    footer = finishing_lines(review)
    {Enum.join(List.flatten([sections, footer]), "\n") <> "\n", row}
  end

  @spec review_actions(t()) :: String.t()
  defp review_actions(%__MODULE__{pending: [], unavailable: [], decisions: []}),
    do: "SPC a a Tasks  q Close"

  defp review_actions(%__MODULE__{pending: [], unavailable: []}),
    do: "↩ Reply to Minga  q Close"

  defp review_actions(%__MODULE__{pending: []}), do: "q Close"
  defp review_actions(%__MODULE__{}), do: "y Keep  n Reject  = Diff  Y Keep all"

  @spec finishing_lines(t()) :: [String.t()]
  defp finishing_lines(%__MODULE__{pending: [], unavailable: [], decisions: []}),
    do: ["", "No changes to review."]

  defp finishing_lines(%__MODULE__{pending: [], unavailable: []}), do: ["", "Passt."]
  defp finishing_lines(%__MODULE__{}), do: []

  @spec file_count(t()) :: String.t()
  defp file_count(review) do
    paths =
      Enum.reduce(review.decisions, MapSet.new(review.unavailable), &MapSet.put(&2, elem(&1, 0)))

    count = review.pending |> Enum.reduce(paths, &MapSet.put(&2, elem(&1, 1))) |> MapSet.size()

    if count == 1, do: "1 file", else: "#{count} files"
  end

  @spec decision_lines(t(), 1 | 2) :: [String.t()]
  defp decision_lines(review, index) do
    for {path, _, _} = decision <- review.decisions, count = elem(decision, index), count > 0 do
      suffix = if count == 1, do: "change", else: "changes"
      "  #{relative(path, review.root)} · #{count} #{suffix}"
    end
  end

  @spec relative(Path.t(), Path.t() | nil) :: Path.t()
  defp relative(path, nil), do: Path.basename(path)
  defp relative(path, root), do: Path.relative_to(path, root)

  @spec tree([entry()], t(), Path.t() | nil) :: [String.t()]
  defp tree(entries, review, root) do
    entries
    |> Enum.chunk_by(&elem(&1, 1))
    |> Enum.flat_map(fn [{_, path, _, _} | _] = file ->
      ["  #{relative(path, root)}" | Enum.flat_map(file, &change_lines(&1, review))]
    end)
  end

  @spec change_lines(entry(), t()) :: [String.t()]
  defp change_lines({key, _, position, _}, review) do
    selected = review.selected == key
    marker = if selected, do: "  › ", else: "    "

    line_text =
      case position do
        {line, col} -> marker <> "Change at #{line + 1}:#{col + 1}"
        nil -> marker <> "Change has no visible location"
      end

    case review do
      %__MODULE__{inline_diff: {^key, lines}} -> [line_text | Enum.map(lines, &"      #{&1}")]
      _ -> [line_text]
    end
  end
end
