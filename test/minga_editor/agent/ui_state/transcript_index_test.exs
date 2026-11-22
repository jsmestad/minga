defmodule MingaEditor.Agent.UIState.TranscriptIndexTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Session.Transcript, as: Source
  alias MingaAgent.ToolCall
  alias MingaEditor.Agent.UIState.TranscriptProjection.Index

  test "display matches full derivation through pins, empty lines, local fences and capacity growth" do
    source =
      Source.new(
        [
          {:user, "early\n"},
          {:assistant, "```elixir\nx = 1\n"},
          {:assistant, "plain\n```\ntext"},
          {:user, ""}
        ],
        ~U[2026-01-01 00:00:00Z],
        make_ref()
      )
      |> Source.toggle_pin(1)

    assert {:snapshot, seed} = Source.since(source, :snapshot)
    index = Index.new(seed.entries, seed.pinned_ids, 2)
    assert_display(index, source, 2)

    revised =
      source
      |> Source.update_at(1, fn _message -> {:assistant, "lead\n```\ncode\n```\ntrail\n"} end)
      |> Source.toggle_pin(1)
      |> Source.toggle_pin(2)
      |> Source.toggle_pin(3)
      |> Source.append({:assistant, "```\nlast"})

    assert {:changes, changes} = Source.since(revised, seed.cursor)
    style = fn _message, _id, _syntax -> nil end
    reading = Index.start_line(index, 3) + 1
    {updated, reading} = Index.apply_changes(index, changes, reading, %{}, style)
    assert Index.line_at(updated, reading) == {3, {:assistant, "plain\n```\ntext"}, 1, :code}

    assert_display(updated, revised, 2)
    assert_display(Index.set_cut(updated, 5), revised, 5)
    assert_display(Index.set_cut(updated, 0), revised, 0)
    assert_display(index, source, 2)

    assert Index.visible_pair(updated, 1) == nil
    assert Index.visible_pair(updated, 3) == {3, {:assistant, "plain\n```\ntext"}}

    shrunk = Source.update_at(revised, 2, fn _message -> {:assistant, "shorter"} end)
    assert {:changes, change} = Source.since(shrunk, changes.cursor)
    {updated, reading} = Index.apply_changes(updated, change, reading, %{}, style)
    assert Index.line_at(updated, reading) == {3, {:assistant, "shorter"}, 0, :text}
  end

  test "a collapsed entry reuses its content derivation while equal text under a new ID does not" do
    source =
      Source.new(
        [{:thinking, "reason", false}, {:assistant, "identical"}],
        ~U[2026-01-01 00:00:00Z],
        make_ref()
      )

    assert {:snapshot, seed} = Source.since(source, :snapshot)
    parent = self()

    style = fn _message, id, syntax ->
      send(parent, {:styled, id, syntax})
      nil
    end

    syntax = %{foreground: :green}
    index = Index.new(seed.entries, seed.pinned_ids, 0) |> Index.restyle(syntax, style)
    assert_receive {:styled, 1, ^syntax}
    assert_receive {:styled, 2, ^syntax}

    next = source |> Source.toggle_message_collapse(1) |> Source.append({:assistant, "identical"})
    assert {:changes, changes} = Source.since(next, seed.cursor)
    {updated, :follow} = Index.apply_changes(index, changes, :follow, syntax, style)

    assert_receive {:styled, 3, ^syntax}
    refute_received {:styled, _unchanged, ^syntax}
    assert Index.visible_pair(updated, 1) == {1, {:thinking, "reason", true}}
    assert_display(updated, next, 0)
  end

  test "matches full derivation across generated edits, collapsed tools, pins and page cuts" do
    tool = ToolCall.new("middle", "read_file") |> ToolCall.complete("first result\n")

    source =
      Source.new(
        [{:assistant, "opening"}, {:tool_call, tool}],
        ~U[2026-01-01 00:00:00Z],
        make_ref()
      )

    {:snapshot, snapshot} = Source.since(source, :snapshot)
    index = Index.new(snapshot.entries, snapshot.pinned_ids, 0)
    style = fn _message, _id, _syntax -> nil end

    Enum.reduce(1..64, {source, index, snapshot.cursor}, fn step, {source, index, cursor} ->
      source =
        source
        |> Source.append(generated_message(step))
        |> Source.update_at(0, fn _previous ->
          {:assistant, String.duplicate("row\n", rem(step, 5))}
        end)
        |> Source.update_at(1, fn {:tool_call, call} ->
          {:tool_call, %{call | collapsed: not call.collapsed}}
        end)
        |> Source.toggle_pin(1 + rem(step * 19, step + 2))

      assert {:changes, changes} = Source.since(source, cursor)
      {index, :follow} = Index.apply_changes(index, changes, :follow, %{}, style)
      cut = rem(step * 11, changes.count + 1)
      index = Index.set_cut(index, cut)
      assert_display(index, source, cut)

      {source, index, changes.cursor}
    end)
  end

  defp generated_message(step) do
    case rem(step, 7) do
      0 -> {:user, "é界 #{step}"}
      1 -> {:assistant, "prose\n  ```elixir\ncode #{step}"}
      2 -> {:assistant, "plain following an unclosed fence\n"}
      3 -> {:thinking, "hmm\nmore", true}
      4 -> {:usage, MingaAgent.TurnUsage.new()}
      5 -> {:system, "notice\n\nsecond paragraph", :warning}
      6 -> {:assistant, ""}
    end
  end

  defp assert_display(index, source, cut) do
    pairs = Source.messages_with_ids(source)
    pins = Source.pinned_ids(source)
    {hidden, suffix} = Enum.split(pairs, cut)
    prefix = Enum.filter(hidden, fn {id, _} -> MapSet.member?(pins, id) end)

    pinned_separator =
      if prefix == [], do: [], else: [{4_000_000_001, {:system, "── pinned ──", :info}}]

    hidden_separator =
      if hidden == [],
        do: [],
        else: [
          {4_000_000_002, {:system, "── #{length(hidden)} earlier messages hidden ──", :info}}
        ]

    expected = prefix ++ pinned_separator ++ hidden_separator ++ suffix

    assert Enum.map(Index.presentation(index), fn {id, message, _style} -> {id, message} end) ==
             expected

    {lines, separators} =
      Enum.reduce(expected, {0, 0}, fn {id, message}, {start, separators} ->
        assert Index.start_line(index, id) == start
        types = reference_types(message)

        for {type, offset} <- Enum.with_index(types ++ [:empty]),
            start + offset < Index.line_count(index) do
          assert Index.line_at(index, start + offset) == {id, message, offset, type}
        end

        {start + length(types) + 1, separators + 1}
      end)

    assert Index.line_count(index) == if(separators == 0, do: 0, else: lines - 1)
    assert Index.line_at(index, Index.line_count(index)) == nil
  end

  defp reference_types({:assistant, text}) do
    {types, _open?} =
      text
      |> String.split("\n")
      |> Enum.map_reduce(false, fn line, open? ->
        fence? = String.starts_with?(String.trim_leading(line), "```")
        {if(open? or fence?, do: :code, else: :text), open? != fence?}
      end)

    types
  end

  defp reference_types({:user, text}), do: Enum.map(String.split(text, "\n"), fn _ -> :text end)

  defp reference_types({:thinking, text, _}),
    do: Enum.map(String.split(text, "\n"), fn _ -> :thinking end)

  defp reference_types({:system, text, _}),
    do: Enum.map(String.split(text, "\n"), fn _ -> :system end)

  defp reference_types({:tool_call, call}),
    do: Enum.map(String.split(String.slice(call.result, 0, 500), "\n"), fn _ -> :tool end)

  defp reference_types({:usage, _}), do: [:usage]
end
