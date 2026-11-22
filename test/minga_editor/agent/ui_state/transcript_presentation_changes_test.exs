defmodule MingaEditor.Agent.UIState.TranscriptPresentationChangesTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Session.Transcript, as: Source
  alias MingaAgent.ToolCall
  alias MingaEditor.Agent.UIState.TranscriptProjection

  @date ~U[2026-01-01 00:00:00Z]
  @context {nil, %{}, &__MODULE__.style/3}

  @doc false
  @spec style(term(), pos_integer(), map()) :: term()
  def style({:assistant, text}, _id, _syntax), do: {:styled_lines, [[{text, 0, 0, 0}]]}
  def style(_message, _id, _syntax), do: nil

  test "applying the changes to the previous display reproduces the full display at every step" do
    {source, projection} = seed(initial_messages(40))

    steps = [
      {:source, &Source.append(&1, {:assistant, "tail"})},
      {:source,
       &Source.update_at(&1, 40, fn {:assistant, text} -> {:assistant, text <> "+"} end)},
      {:source,
       &Source.update_at(&1, 20, fn {:tool_call, call} ->
         {:tool_call, ToolCall.complete(call, "middle\nresult")}
       end)},
      {:source, &Source.toggle_message_collapse(&1, 21)},
      {:display, 30},
      {:source, &Source.toggle_pin(&1, 3)},
      {:source, &Source.toggle_pin(&1, 35)},
      {:display, 10},
      {:source, &Source.toggle_pin(&1, 3)},
      {:source, &Source.update_at(&1, 5, fn _message -> {:assistant, "hidden revision"} end)},
      {:display, 0},
      {:source, &Source.append(&1, {:user, "next turn"})}
    ]

    Enum.reduce(steps, {source, projection}, fn step, {source, previous} ->
      {source, current} = apply_step(step, source, previous)
      changes = TranscriptProjection.presentation_changes(previous, current)

      assert apply_changes(TranscriptProjection.presentation_entries(previous), changes) ==
               TranscriptProjection.presentation_entries(current)

      assert Enum.map(TranscriptProjection.presentation_entries(current), &item_without_key/1) ==
               TranscriptProjection.presentation(current)

      {source, current}
    end)
  end

  test "a one-entry tail or middle revision produces exactly one change" do
    {source, projection} = seed(initial_messages(200))

    for index <- [199, 100] do
      revised =
        Source.update_at(source, index, fn
          {:assistant, text} -> {:assistant, text <> "!"}
          {:tool_call, call} -> {:tool_call, ToolCall.complete(call, "done")}
          other -> other
        end)

      {_source, current} = sync(revised, source, projection)

      assert [{:put, {3, ^index}, _item}] =
               TranscriptProjection.presentation_changes(projection, current)
    end
  end

  test "an unchanged projection and an in-window pin produce no display change" do
    {source, projection} = seed(initial_messages(10))
    assert TranscriptProjection.presentation_changes(projection, projection) == []

    {_source, pinned} = sync(Source.toggle_pin(source, 7), source, projection)
    assert TranscriptProjection.presentation_changes(projection, pinned) == []
  end

  test "pinning a hidden entry changes only its prefix row and the pinned separator" do
    {source, projection} = seed(initial_messages(10))

    paged =
      TranscriptProjection.set_display_start(projection, 5)
      |> TranscriptProjection.prepare(@context)

    {_source, pinned} = sync(Source.toggle_pin(source, 2), source, paged)

    assert [{:put, {0, 1}, {2, _, _}}, {:put, {1, 0}, {_, {:system, "── pinned ──", :info}, nil}}] =
             TranscriptProjection.presentation_changes(paged, pinned)
  end

  test "paging changes only rows crossing the cut and the hidden separator" do
    {_source, projection} = seed(initial_messages(10))

    paged =
      TranscriptProjection.set_display_start(projection, 3)
      |> TranscriptProjection.prepare(@context)

    changes = TranscriptProjection.presentation_changes(projection, paged)

    assert Enum.map(changes, &change_key/1) == [{2, 0}, {3, 0}, {3, 1}, {3, 2}]
  end

  defp initial_messages(count) do
    for index <- 0..(count - 1) do
      cond do
        index == div(count, 2) -> {:tool_call, ToolCall.new("middle", "read_file", %{})}
        rem(index, 2) == 0 -> {:user, "question #{index}"}
        true -> {:assistant, "answer #{index}"}
      end
    end
  end

  defp seed(messages) do
    source = Source.new(messages, @date, make_ref())
    {:snapshot, snapshot} = Source.since(source, :snapshot)

    projection =
      TranscriptProjection.replace(
        TranscriptProjection.new(),
        snapshot.entries,
        snapshot.pinned_ids,
        snapshot.cursor,
        @context
      )

    {source, projection}
  end

  defp sync(source, _previous_source, projection) do
    {:changes, changes} = Source.since(source, projection.source_cursor)

    {projection, _reading} =
      TranscriptProjection.apply_changes(projection, changes, :follow, @context)

    {source, projection}
  end

  defp apply_step({:source, update}, source, projection),
    do: sync(update.(source), source, projection)

  defp apply_step({:display, start}, source, projection) do
    {source,
     projection
     |> TranscriptProjection.set_display_start(start)
     |> TranscriptProjection.prepare(@context)}
  end

  defp apply_changes(entries, changes) do
    changes
    |> Enum.reduce(Map.new(entries), fn
      {:put, key, item}, display -> Map.put(display, key, item)
      {:delete, key}, display -> Map.delete(display, key)
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp item_without_key({_key, item}), do: item
  defp change_key({:put, key, _item}), do: key
  defp change_key({:delete, key}), do: key
end
