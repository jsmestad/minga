defmodule Minga.Test.TranscriptFixture do
  @moduledoc false

  alias MingaAgent.Session.Transcript, as: Source
  alias MingaAgent.TurnUsage
  alias MingaEditor.Agent.UIState.TranscriptProjection

  @spec projection([term()], keyword()) :: TranscriptProjection.t()
  def projection(messages, opts \\ []) do
    date = ~U[2026-01-01 00:00:00Z]
    source = Source.new(messages, date, make_ref())
    pins = Keyword.get(opts, :pinned_ids, MapSet.new())
    ids = Keyword.get(opts, :message_ids, []) |> Enum.map(&elem(&1, 0))
    source = Source.restore(source, messages, ids, [], TurnUsage.new(), pins, date)
    {:snapshot, snapshot} = Source.since(source, :snapshot)

    styles =
      snapshot.entries
      |> Enum.zip(Keyword.get(opts, :styled_messages) || [])
      |> Map.new(fn {entry, style} -> {entry.id, style} end)

    context =
      {Keyword.get(opts, :empty_state), %{}, fn _message, id, _syntax -> Map.get(styles, id) end}

    TranscriptProjection.new()
    |> TranscriptProjection.set_display_start(Keyword.get(opts, :display_start_index, 0))
    |> TranscriptProjection.replace(
      snapshot.entries,
      snapshot.pinned_ids,
      snapshot.cursor,
      context
    )
  end

  @spec messages(TranscriptProjection.t()) :: [term()]
  def messages(projection) do
    projection |> TranscriptProjection.presentation() |> Enum.map(&elem(&1, 1))
  end
end
