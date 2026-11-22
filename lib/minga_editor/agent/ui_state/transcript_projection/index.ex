defmodule MingaEditor.Agent.UIState.TranscriptProjection.Index do
  @moduledoc false

  alias MingaAgent.Session.Transcript.Changes
  alias MingaAgent.Session.Transcript.Entry
  alias MingaEditor.Agent.Transcript
  alias MingaEditor.Agent.UIState.TranscriptProjection
  alias MingaEditor.Agent.UIState.TranscriptProjection.{Row, Tree}

  @pinned_id 4_000_000_001
  @hidden_id 4_000_000_002
  @separator_slots 2

  @type item :: {pos_integer(), term(), TranscriptProjection.rendered_message() | nil}
  @type position :: {pos_integer(), term(), non_neg_integer(), Transcript.line_type()}
  @type styler :: (term(), pos_integer(), map() -> TranscriptProjection.rendered_message() | nil)
  @type reading :: :follow | non_neg_integer()

  @typedoc """
  Stable position of one displayed item.

  Classes sort in display order: `0` pinned rows before the display cut, `1` the pinned separator, `2` the hidden-history separator, `3` rows at or after the cut. The second element is the source ordinal for rows and `0` for separators.
  """
  @type display_key :: {0 | 3, non_neg_integer()} | {1 | 2, 0}
  @type display_change :: {:put, display_key(), item()} | {:delete, display_key()}
  @typep update_context :: {t(), reading()}

  @enforce_keys [:tree, :ordinals, :cut, :cut_weights]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            tree: Tree.t(),
            ordinals: %{optional(pos_integer()) => non_neg_integer()},
            cut: non_neg_integer(),
            cut_weights: {non_neg_integer(), non_neg_integer()}
          }

  @doc "Builds one generation from an ordered, atomic snapshot."
  @spec new([Entry.t()], MapSet.t(pos_integer()), non_neg_integer()) :: t()
  def new(entries, pinned, cut) do
    {rows, ordinals} =
      Enum.map_reduce(entries, %{}, fn %Entry{id: id, ordinal: ordinal} = entry, ordinals ->
        {Row.new(entry, MapSet.member?(pinned, id)), Map.put(ordinals, id, ordinal)}
      end)

    tree = Tree.new(rows)
    set_cut(%__MODULE__{tree: tree, ordinals: ordinals, cut: 0, cut_weights: {0, 0}}, cut)
  end

  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{tree: tree}), do: Tree.count(tree)

  @spec ordinal(t(), pos_integer()) :: non_neg_integer() | nil
  def ordinal(%__MODULE__{ordinals: ordinals}, id), do: Map.get(ordinals, id)

  @spec names_and_turns(t()) :: {String.t() | nil, String.t() | nil, non_neg_integer()}
  def names_and_turns(%__MODULE__{tree: tree}), do: Tree.names_and_turns(tree)

  @spec turn_count(t()) :: non_neg_integer()
  def turn_count(%__MODULE__{tree: tree}), do: Tree.turn_count(tree)

  @spec first_run?(t()) :: boolean()
  def first_run?(%__MODULE__{tree: tree}), do: Tree.first_run?(tree)

  @doc "Changes the display window without changing retained source or cursor."
  @spec set_cut(t(), non_neg_integer()) :: t()
  def set_cut(%__MODULE__{cut: cut} = index, cut), do: index

  def set_cut(%__MODULE__{tree: tree} = index, cut) do
    cut = min(cut, Tree.count(tree))

    %{
      index
      | cut: cut,
        cut_weights: {Tree.prefix(tree, cut, :lines), Tree.prefix(tree, cut, :pin_lines)}
    }
  end

  @doc "Updates the source facts and moves an unpinned reading offset with its row."
  @spec apply_changes(t(), Changes.t(), reading(), map(), styler()) :: update_context()
  def apply_changes(%__MODULE__{} = index, %Changes{} = changes, reading, syntax, style) do
    next = Enum.reduce(changes.entries, {index, reading}, &revise_entry(&2, &1, syntax, style))
    Enum.reduce(changes.pin_changes, next, &update_pin(&2, &1, syntax, style))
  end

  @doc "Prepares the displayed rows after a theme or display cut change."
  @spec restyle(t(), map(), styler()) :: t()
  def restyle(%__MODULE__{tree: tree, cut: cut} = index, syntax, style) do
    prepare = &prepare_row(&1, cut, syntax, style)

    tree =
      tree
      |> Tree.map_range(0, cut, :pinned, prepare)
      |> Tree.map_range(cut, Tree.count(tree), :all, prepare)

    %{index | tree: tree}
  end

  @doc "Returns the visible message for an exact ID, not a hidden occurrence."
  @spec visible_pair(t(), pos_integer()) :: {pos_integer(), term()} | nil
  def visible_pair(%__MODULE__{tree: tree, cut: cut} = index, id) do
    with ordinal when is_integer(ordinal) <- ordinal(index, id),
         %Row{entry: %Entry{message: message}, pinned?: pinned?}
         when ordinal >= cut or pinned? <- Tree.fetch(tree, ordinal) do
      {id, message}
    else
      _hidden_or_missing -> nil
    end
  end

  @doc "Counts visible semantic lines, excluding the separator after the last item."
  @spec line_count(t()) :: non_neg_integer()
  def line_count(%__MODULE__{tree: tree, cut_weights: {hidden_slots, pin_slots}} = index) do
    source_slots = Tree.line_slots(tree)
    max(source_slots - hidden_slots + suffix_start(index, pin_slots) - 1, 0)
  end

  @doc "Finds an exact visible line and its owning row."
  @spec line_at(t(), non_neg_integer()) :: position() | nil
  def line_at(%__MODULE__{cut_weights: {hidden_slots, pin_slots}, tree: tree} = index, offset)
      when offset >= 0 do
    rows = line_count(index)
    pinned_end = pin_slots + separator_slots(pin_slots)
    suffix_start = suffix_start(index, pin_slots)

    case offset do
      line when line >= rows ->
        nil

      line when line < pin_slots ->
        position(Tree.line_at(tree, line, :pin_lines))

      line when line < pinned_end ->
        synthetic_position(pinned_separator(), line - pin_slots)

      line when line < suffix_start ->
        synthetic_position(hidden_separator(index.cut), line - pinned_end)

      line ->
        position(Tree.line_at(tree, hidden_slots + line - suffix_start, :lines))
    end
  end

  @doc "Returns one displayed row's first line by stable ID."
  @spec start_line(t(), pos_integer()) :: non_neg_integer() | nil
  def start_line(%__MODULE__{cut_weights: {_hidden, pin_slots}}, @pinned_id) when pin_slots > 0,
    do: pin_slots

  def start_line(%__MODULE__{cut: cut, cut_weights: {_hidden, pin_slots}}, @hidden_id)
      when cut > 0,
      do: pin_slots + separator_slots(pin_slots)

  def start_line(
        %__MODULE__{tree: tree, cut: cut, cut_weights: {hidden_slots, pin_slots}} = index,
        id
      ) do
    case ordinal(index, id) do
      ordinal when is_integer(ordinal) and ordinal >= cut ->
        suffix_start(index, pin_slots) + Tree.prefix(tree, ordinal, :lines) - hidden_slots

      ordinal when is_integer(ordinal) ->
        case Tree.fetch(tree, ordinal) do
          %Row{pinned?: true} -> Tree.prefix(tree, ordinal, :pin_lines)
          _invisible -> nil
        end

      nil ->
        nil
    end
  end

  @doc "Enumerates the existing renderer contract only at the presentation boundary."
  @spec presentation(t()) :: [item()]
  def presentation(%__MODULE__{tree: tree, cut: cut, cut_weights: {_hidden, pin_slots}}) do
    prefix = Tree.reduce_range(tree, 0, cut, :pinned, [], &prepend_item/2)
    prefix = if pin_slots > 0, do: [pinned_separator() | prefix], else: prefix
    prefix = if cut > 0, do: [hidden_separator(cut) | prefix], else: prefix

    tree
    |> Tree.reduce_range(cut, Tree.count(tree), :all, prefix, &prepend_item/2)
    |> Enum.reverse()
  end

  @doc "Enumerates every displayed item with its stable display key, in display order."
  @spec presentation_entries(t()) :: [{display_key(), item()}]
  def presentation_entries(%__MODULE__{tree: tree, cut: cut} = index) do
    prefix = Tree.reduce_range(tree, 0, cut, :pinned, [], &prepend_entry(&1, &2, 0))

    prefix
    |> prepend_separators(index)
    |> then(
      &Tree.reduce_range(tree, cut, Tree.count(tree), :all, &1, fn row, acc ->
        prepend_entry(row, acc, 3)
      end)
    )
    |> Enum.reverse()
  end

  @doc """
  Returns the ordered display changes between two indexes of one generation.

  Only changed leaves, rows crossing a moved display cut, and the two synthetic separators are inspected.
  """
  @spec presentation_changes(t(), t()) :: [display_change()]
  def presentation_changes(%__MODULE__{} = index, %__MODULE__{} = index), do: []

  def presentation_changes(%__MODULE__{} = old, %__MODULE__{} = new) do
    rows =
      old.tree
      |> Tree.changed_ordinals(new.tree)
      |> merge_ordinals(cut_range(old.cut, new.cut))
      |> Enum.flat_map(fn ordinal ->
        entry_changes(
          display_entry(Tree.fetch(old.tree, ordinal), old.cut),
          display_entry(Tree.fetch(new.tree, ordinal), new.cut)
        )
      end)

    separators =
      entry_changes(pinned_entry(old), pinned_entry(new)) ++
        entry_changes(hidden_entry(old), hidden_entry(new))

    Enum.sort_by(separators ++ rows, &change_key/1)
  end

  @spec display_entry(Row.t() | nil, non_neg_integer()) :: {display_key(), item()} | nil
  defp display_entry(nil, _cut), do: nil

  defp display_entry(%Row{entry: %Entry{ordinal: ordinal}} = row, cut) when ordinal >= cut,
    do: {{3, ordinal}, row_item(row)}

  defp display_entry(%Row{entry: %Entry{ordinal: ordinal}, pinned?: true} = row, _cut),
    do: {{0, ordinal}, row_item(row)}

  defp display_entry(%Row{}, _cut), do: nil

  defp pinned_entry(%__MODULE__{cut_weights: {_hidden, pin_slots}}) when pin_slots > 0,
    do: {{1, 0}, pinned_separator()}

  defp pinned_entry(%__MODULE__{}), do: nil

  defp hidden_entry(%__MODULE__{cut: 0}), do: nil
  defp hidden_entry(%__MODULE__{cut: cut}), do: {{2, 0}, hidden_separator(cut)}

  @spec entry_changes({display_key(), item()} | nil, {display_key(), item()} | nil) ::
          [display_change()]
  defp entry_changes(nil, nil), do: []
  defp entry_changes(same, same), do: []
  defp entry_changes({key, _old}, {key, item}), do: [{:put, key, item}]
  defp entry_changes({key, _old}, nil), do: [{:delete, key}]
  defp entry_changes(nil, {key, item}), do: [{:put, key, item}]
  defp entry_changes({old_key, _old}, {key, item}), do: [{:delete, old_key}, {:put, key, item}]

  defp change_key({:put, key, _item}), do: key
  defp change_key({:delete, key}), do: key

  defp cut_range(cut, cut), do: []
  defp cut_range(old, new), do: Enum.to_list(min(old, new)..(max(old, new) - 1)//1)

  defp merge_ordinals([], right), do: right
  defp merge_ordinals(left, []), do: left
  defp merge_ordinals([same | left], [same | right]), do: [same | merge_ordinals(left, right)]

  defp merge_ordinals([l | left], [r | _] = right) when l < r,
    do: [l | merge_ordinals(left, right)]

  defp merge_ordinals(left, [r | right]), do: [r | merge_ordinals(left, right)]

  defp prepend_separators(prefix, %__MODULE__{cut: cut} = index) do
    prefix = if entry = pinned_entry(index), do: [entry | prefix], else: prefix
    if cut > 0, do: [hidden_entry(index) | prefix], else: prefix
  end

  defp prepend_entry(%Row{entry: %Entry{ordinal: ordinal}} = row, acc, class),
    do: [{{class, ordinal}, row_item(row)} | acc]

  defp row_item(%Row{entry: %Entry{id: id, message: message}} = row),
    do: {id, message, Row.displayed_style(row)}

  @spec revise_entry(update_context(), Entry.t(), map(), styler()) :: update_context()
  defp revise_entry({index, reading}, %Entry{id: id, ordinal: ordinal} = entry, syntax, style) do
    {tree, before, after_row, lines, pin_lines} =
      Tree.update(index.tree, ordinal, fn
        nil -> prepare_row(Row.new(entry, false), index.cut, syntax, style)
        row -> prepare_row(Row.revise(row, entry), index.cut, syntax, style)
      end)

    ordinals = if before, do: index.ordinals, else: Map.put(index.ordinals, id, ordinal)

    update_layout(
      {%{index | tree: tree, ordinals: ordinals}, reading},
      before,
      after_row,
      lines,
      pin_lines
    )
  end

  @spec update_pin(update_context(), Changes.pin_fact(), map(), styler()) :: update_context()
  defp update_pin({index, reading}, {id, pinned?}, syntax, style) do
    ordinal = Map.fetch!(index.ordinals, id)

    {tree, before, after_row, lines, pin_lines} =
      Tree.update(index.tree, ordinal, fn row ->
        row |> Row.pin(pinned?) |> prepare_row(index.cut, syntax, style)
      end)

    update_layout({%{index | tree: tree}, reading}, before, after_row, lines, pin_lines)
  end

  @spec prepare_row(Row.t(), non_neg_integer(), map(), styler()) :: Row.t()
  defp prepare_row(%Row{style: {syntax, _rendered}} = row, _cut, syntax, _style), do: row

  defp prepare_row(
         %Row{entry: %Entry{id: id, ordinal: ordinal, message: message}, pinned?: pinned?} = row,
         cut,
         syntax,
         style
       )
       when ordinal >= cut or pinned?,
       do: Row.style(row, syntax, style.(message, id, syntax))

  defp prepare_row(row, _cut, _syntax, _style), do: row

  defp update_layout(
         {%__MODULE__{cut_weights: {hidden, pinned}} = index, reading},
         before,
         %Row{entry: %Entry{ordinal: ordinal}} = next,
         _lines,
         pin_lines
       )
       when ordinal < index.cut do
    old_slots = pinned_slots(before)
    new_slots = pinned_slots(next)
    next_pinned = pinned + new_slots - old_slots
    old_span = old_slots + if(next_pinned == 0, do: separator_slots(pinned), else: 0)
    new_span = new_slots + if(pinned == 0, do: separator_slots(next_pinned), else: 0)

    {%{index | cut_weights: {hidden + slots(next) - slots(before), next_pinned}},
     shift_reading(reading, pin_lines, old_span, new_span)}
  end

  defp update_layout(
         {%__MODULE__{cut_weights: {hidden, pinned}} = index, reading},
         before,
         next,
         lines,
         _pin_lines
       ) do
    row_start = suffix_start(index, pinned) + lines - hidden
    {index, shift_reading(reading, row_start, slots(before), slots(next))}
  end

  defp shift_reading(:follow, _start, _old, _new), do: :follow
  defp shift_reading(reading, start, _old, _new) when reading < start, do: reading

  defp shift_reading(reading, start, old, new) when reading >= start + old,
    do: reading + new - old

  defp shift_reading(_reading, start, _old, 0), do: start

  defp shift_reading(reading, start, old, new) when reading == start + old - 1,
    do: start + new - 1

  defp shift_reading(reading, start, _old, new), do: min(reading, start + new - 2)

  defp slots(nil), do: 0
  defp slots(%Row{lines: {count, _type}}), do: count + 1
  defp pinned_slots(%Row{pinned?: true} = row), do: slots(row)
  defp pinned_slots(_row), do: 0

  defp suffix_start(%__MODULE__{cut: cut}, pin_slots),
    do: pin_slots + separator_slots(pin_slots) + separator_slots(cut)

  defp separator_slots(0), do: 0
  defp separator_slots(_weight), do: @separator_slots

  defp position({%Row{entry: %Entry{id: id, message: message}, lines: lines}, offset}),
    do: {id, message, offset, Transcript.line_type_at(lines, offset)}

  defp synthetic_position({id, message, nil}, offset),
    do: {id, message, offset, if(offset == 0, do: :system, else: :empty)}

  defp prepend_item(%Row{entry: %Entry{id: id, message: message}} = row, acc),
    do: [{id, message, Row.displayed_style(row)} | acc]

  defp pinned_separator, do: {@pinned_id, {:system, "── pinned ──", :info}, nil}

  defp hidden_separator(cut),
    do: {@hidden_id, {:system, "── #{cut} earlier messages hidden ──", :info}, nil}
end
