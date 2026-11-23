defmodule MingaEditor.Agent.UIState.TranscriptProjection do
  @moduledoc false

  alias MingaAgent.Session.Transcript.{Changes, Cursor, Entry}
  alias MingaEditor.Agent.{ProvenanceJump, Transcript}
  alias MingaEditor.Agent.UIState.TranscriptProjection.Index

  @empty_state_id 4_000_000_010

  @type t :: %__MODULE__{
          index: Index.t() | nil,
          generation: reference() | nil,
          source_cursor: Cursor.t() | nil,
          display_start: non_neg_integer(),
          provenance_jump: ProvenanceJump.t() | nil,
          version: non_neg_integer(),
          syntax: map() | nil,
          empty_state: Transcript.empty_state(),
          empty_item: {Index.item(), Transcript.line_profile()} | nil
        }

  @type rendered_message ::
          {:markdown_blocks, nonempty_list(Minga.RenderModel.UI.AgentChat.MarkdownBlock.t())}
          | {:styled_lines, MingaEditor.Agent.MarkdownHighlight.styled_lines()}

  @type presentation_context :: {Transcript.empty_state(), map(), Index.styler()}

  @typedoc "Stable display position; class `4` is the first-run empty state, which displays alone."
  @type display_key :: Index.display_key() | {4, 0}
  @type display_change :: {:put, display_key(), Index.item()} | {:delete, display_key()}

  @typedoc "Identifies one installed transcript generation; a replacement never shares it."
  @type presentation_identity :: reference() | nil

  defstruct index: nil,
            generation: nil,
            source_cursor: nil,
            display_start: 0,
            provenance_jump: nil,
            version: 0,
            syntax: nil,
            empty_state: nil,
            empty_item: nil

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Installs a replacement generation without keeping any old row or offer identity."
  @spec replace(
          t(),
          [Entry.t()],
          MapSet.t(pos_integer()),
          Cursor.t() | nil,
          presentation_context()
        ) :: t()
  def replace(%__MODULE__{} = projection, entries, pins, cursor, context) do
    install(projection, entries, pins, cursor, make_ref(), context)
  end

  @doc "Rebuilds a remote read on the same attachment without changing its presentation identity."
  @spec refresh_remote(t(), [Entry.t()], MapSet.t(pos_integer()), presentation_context()) :: t()
  def refresh_remote(%__MODULE__{} = projection, entries, pins, context) do
    install(projection, entries, pins, nil, projection.generation || make_ref(), context)
  end

  defp install(projection, entries, pins, cursor, generation, context) do
    next = %{
      projection
      | index: Index.new(entries, pins, projection.display_start),
        generation: generation,
        source_cursor: cursor,
        syntax: nil,
        provenance_jump:
          replace_jump(projection.provenance_jump, entries, projection.generation == generation)
    }

    prepare_changed(next, context)
  end

  @doc "Applies one atomic source reply and preserves the reader's row during the update."
  @spec apply_changes(t(), Changes.t(), Index.reading(), presentation_context()) ::
          {t(), Index.reading()}
  def apply_changes(
        %__MODULE__{index: index} = projection,
        changes,
        reading,
        {_, syntax, style} = context
      ) do
    {next, reading} = Index.apply_changes(index, changes, reading, syntax, style)

    projection =
      prepare_changed(%{projection | index: next, source_cursor: changes.cursor}, context)

    {projection, reading}
  end

  @doc "Restyles only from the installed source when theme or display cut changed."
  @spec prepare(t(), presentation_context()) :: t()
  def prepare(%__MODULE__{index: nil} = projection, _context), do: projection

  def prepare(%__MODULE__{} = projection, context) do
    projection |> reveal_provenance() |> refresh_presentation(context)
  end

  defp refresh_presentation(
         %__MODULE__{syntax: syntax, empty_state: empty} = projection,
         {empty, syntax, _style}
       ),
       do: projection

  defp refresh_presentation(projection, context), do: prepare_changed(projection, context)

  defp prepare_changed(%__MODULE__{} = projection, {empty, syntax, style}) do
    projection = reveal_provenance(projection)

    index =
      if projection.syntax == syntax,
        do: projection.index,
        else: Index.restyle(projection.index, syntax, style)

    next = %{projection | index: index, syntax: syntax, empty_state: empty}
    put_empty_item(next, if(empty != nil and Index.first_run?(index), do: empty, else: nil))
  end

  @spec clear(t()) :: t()
  def clear(%__MODULE__{version: version}) do
    %__MODULE__{version: version}
  end

  @doc "Records a source revision that did not change the displayed entries or pins."
  @spec advance_source_cursor(t(), Cursor.t()) :: t()
  def advance_source_cursor(%__MODULE__{} = projection, cursor),
    do: %{projection | source_cursor: cursor}

  @doc "Returns the count of retained source entries without reading them."
  @spec source_count(t()) :: non_neg_integer()
  def source_count(%__MODULE__{index: nil}), do: 0
  def source_count(%__MODULE__{index: index}), do: Index.count(index)

  @doc "Returns the opening user and assistant text and the retained user turn count."
  @spec names_and_turns(t()) :: {String.t() | nil, String.t() | nil, non_neg_integer()}
  def names_and_turns(%__MODULE__{index: nil}), do: {nil, nil, 0}
  def names_and_turns(%__MODULE__{index: index}), do: Index.names_and_turns(index)

  @spec turn_count(t()) :: non_neg_integer()
  def turn_count(%__MODULE__{index: nil}), do: 0
  def turn_count(%__MODULE__{index: index}), do: Index.turn_count(index)

  @spec line_count(t()) :: non_neg_integer()
  def line_count(%__MODULE__{empty_item: {_item, {count, _types}}}), do: count
  def line_count(%__MODULE__{index: nil}), do: 0
  def line_count(%__MODULE__{index: index}), do: Index.line_count(index)

  @spec line_at(t(), non_neg_integer()) :: Index.position() | nil
  def line_at(%__MODULE__{empty_item: {{id, message, _}, {count, _} = profile}}, offset)
      when offset < count do
    {id, message, offset, Transcript.line_type_at(profile, offset)}
  end

  def line_at(%__MODULE__{empty_item: {_item, _profile}}, _offset), do: nil
  def line_at(%__MODULE__{index: nil}, _offset), do: nil
  def line_at(%__MODULE__{index: index}, offset), do: Index.line_at(index, offset)

  @spec visible_pair(t(), pos_integer()) :: {pos_integer(), term()} | nil
  def visible_pair(%__MODULE__{index: nil}, _id), do: nil
  def visible_pair(%__MODULE__{empty_item: {_item, _profile}}, _id), do: nil
  def visible_pair(%__MODULE__{index: index}, id), do: Index.visible_pair(index, id)

  @doc "Projects all displayed items at the existing renderer presentation boundary."
  @spec presentation(t()) :: [Index.item()]
  def presentation(%__MODULE__{empty_item: {item, _lines}}), do: [item]
  def presentation(%__MODULE__{index: nil}), do: []
  def presentation(%__MODULE__{index: index}), do: Index.presentation(index)

  @doc "Returns the identity a renderer base must match before it accepts presentation changes."
  @spec presentation_identity(t()) :: presentation_identity()
  def presentation_identity(%__MODULE__{generation: generation}), do: generation

  @doc "Enumerates the keyed display for a renderer seed. This is a whole-display operation."
  @spec presentation_entries(t()) :: [{display_key(), Index.item()}]
  def presentation_entries(%__MODULE__{empty_item: {item, _lines}}), do: [{{4, 0}, item}]
  def presentation_entries(%__MODULE__{index: nil}), do: []
  def presentation_entries(%__MODULE__{index: index}), do: Index.presentation_entries(index)

  @doc """
  Returns the ordered display changes from `previous` to `current` within one presentation identity.

  An unchanged projection costs one identity comparison. Indexed displays visit only changed leaves, rows crossing a moved cut and the separators. Entering or leaving the first-run empty state enumerates both small displays.
  """
  @spec presentation_changes(t(), t()) :: [display_change()]
  def presentation_changes(%__MODULE__{} = projection, %__MODULE__{} = projection), do: []

  def presentation_changes(
        %__MODULE__{index: previous, empty_item: nil},
        %__MODULE__{index: current, empty_item: nil}
      )
      when previous != nil and current != nil,
      do: Index.presentation_changes(previous, current)

  def presentation_changes(%__MODULE__{} = previous, %__MODULE__{} = current) do
    before = Map.new(presentation_entries(previous))
    entries = presentation_entries(current)
    keys = MapSet.new(entries, &elem(&1, 0))

    deletes =
      for {key, _item} <- before, not MapSet.member?(keys, key), do: {:delete, key}

    puts = for {key, item} <- entries, Map.get(before, key) != item, do: {:put, key, item}
    Enum.sort_by(deletes ++ puts, &change_key/1)
  end

  defp change_key({:put, key, _item}), do: key
  defp change_key({:delete, key}), do: key

  @doc "Drops retained display state from a copy that crosses the renderer boundary."
  @spec render_snapshot(t()) :: t()
  def render_snapshot(%__MODULE__{index: nil, empty_item: nil, source_cursor: nil} = projection),
    do: projection

  def render_snapshot(%__MODULE__{}), do: %__MODULE__{}

  @spec start_line(t(), pos_integer()) :: non_neg_integer() | nil
  def start_line(%__MODULE__{index: nil}, _id), do: nil
  def start_line(%__MODULE__{index: index}, id), do: Index.start_line(index, id)

  @doc "Records a content revision. A revision changes entry bodies, not the presentation epoch."
  @spec bump_version(t()) :: t()
  def bump_version(%__MODULE__{version: version} = projection),
    do: %{projection | version: version + 1}

  @doc """
  Identifies the installed resident transcript independently of connection availability.

  The epoch changes only when the display changes shape: a replaced generation (reset, resume, or session switch), a moved display start, or a cleared projection. A content revision, such as a streamed text batch or a collapse toggle, keeps the epoch so the transcript stream sends the changed entries as an in-epoch delta.
  """
  @spec presentation_epoch(t()) :: non_neg_integer()
  def presentation_epoch(%__MODULE__{generation: nil}), do: 0

  def presentation_epoch(%__MODULE__{generation: generation, display_start: start}),
    do: :erlang.phash2({generation, start})

  @spec set_display_start(t(), non_neg_integer()) :: t()
  def set_display_start(%__MODULE__{display_start: start} = projection, start), do: projection

  def set_display_start(%__MODULE__{index: nil} = projection, start),
    do: %{projection | display_start: start}

  def set_display_start(%__MODULE__{index: index} = projection, start) do
    %{projection | index: Index.set_cut(index, start), display_start: start, syntax: nil}
  end

  @spec set_provenance_jump(t(), MingaEditor.Agent.ProvenanceJump.t() | nil) :: t()
  def set_provenance_jump(%__MODULE__{} = projection, jump),
    do: %{projection | provenance_jump: jump}

  @spec clear_provenance_jump(t()) :: t()
  def clear_provenance_jump(%__MODULE__{} = projection), do: %{projection | provenance_jump: nil}

  defp reveal_provenance(
         %__MODULE__{
           provenance_jump: %ProvenanceJump{landed?: false, target: {:message_id, id}} = jump
         } = projection
       ) do
    case Index.ordinal(projection.index, id) do
      ordinal when is_integer(ordinal) ->
        next = set_display_start(projection, min(projection.display_start, ordinal))
        %{next | provenance_jump: ProvenanceJump.mark_landed(jump)}

      nil ->
        projection
    end
  end

  defp reveal_provenance(projection), do: projection

  defp replace_jump(
         %ProvenanceJump{target: {:tool_call_id, tool_call_id}} = jump,
         entries,
         _same?
       ) do
    case Transcript.turn_anchor_id(entries, tool_call_id) do
      nil -> nil
      id -> ProvenanceJump.resolve(jump, id)
    end
  end

  defp replace_jump(%ProvenanceJump{landed?: true}, _entries, false), do: nil
  defp replace_jump(jump, _entries, _same?), do: jump

  defp put_empty_item(projection, nil), do: %{projection | empty_item: nil}

  defp put_empty_item(projection, empty) do
    message = Transcript.empty_state_message(empty)

    case projection.empty_item do
      {{@empty_state_id, ^message, nil}, _profile} ->
        projection

      _previous ->
        %{
          projection
          | empty_item: {{@empty_state_id, message, nil}, Transcript.line_profile(message)}
        }
    end
  end
end
