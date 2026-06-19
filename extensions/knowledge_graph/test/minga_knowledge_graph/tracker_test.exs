defmodule MingaKnowledgeGraph.TrackerTest do
  # Drives the real Badge/Storage registries (global ETS), so not async.
  use ExUnit.Case, async: false

  alias Minga.Events.BufferChangedEvent
  alias Minga.Events.BufferEvent
  alias Minga.Extension.Badge
  alias MingaKnowledgeGraph.Tracker

  @ext :minga_knowledge_graph

  setup do
    base = Path.join(System.tmp_dir!(), "kg_tracker_#{System.unique_integer([:positive])}")
    Application.put_env(:minga, :extension_data_dir, base)

    on_exit(fn ->
      Badge.remove_all(@ext)
      Application.delete_env(:minga, :extension_data_dir)
      File.rm_rf(base)
    end)

    {:ok, base: base}
  end

  # A path that does not exist on disk, so opening it records activity but
  # never kicks off a (network-bound) briefing.
  defp ghost_path do
    Path.expand("/nonexistent/kg_#{System.unique_integer([:positive])}.ex")
  end

  # `seed: false` skips the git cold-start so tests don't shell out.
  defp start_tracker(id) do
    name = :"kg_tracker_#{id}"
    start_supervised!(%{id: id, start: {Tracker, :start_link, [[name: name, seed: false]]}})
    name
  end

  defp deliver(server, message) do
    send(server, message)
    # Force the GenServer to process the async message before asserting.
    _ = :sys.get_state(server)
    :ok
  end

  defp open(server, path) do
    deliver(server, {:minga_event, :buffer_opened, %BufferEvent{buffer: self(), path: path}})
  end

  test "opening a file records it and pushes a heat level to the badge registry" do
    server = start_tracker(:open)
    path = ghost_path()

    open(server, path)

    assert Map.has_key?(Badge.file_levels_map(), path)
  end

  test "familiarity summary reflects opens" do
    server = start_tracker(:summary)
    path = ghost_path()

    open(server, path)

    summary = Tracker.familiarity(server, path)
    assert summary =~ Path.basename(path)
    assert summary =~ "opened 1"
  end

  test "agent-sourced changes do not count as edits" do
    server = start_tracker(:agent)
    path = ghost_path()
    open(server, path)

    deliver(
      server,
      {:minga_event, :buffer_changed,
       %BufferChangedEvent{source: {:agent, self(), nil}, buffer: self(), delta: nil, version: 1}}
    )

    assert Tracker.familiarity(server, path) =~ "edited 0"
  end

  test "unknown files report as unfamiliar" do
    server = start_tracker(:unknown)
    assert Tracker.familiarity(server, ghost_path()) =~ "unfamiliar"
  end

  test "the graph persists across a tracker restart" do
    path = ghost_path()

    server = start_tracker(:persist_a)
    open(server, path)
    open(server, path)
    deliver(server, :persist)
    stop_supervised!(:persist_a)

    server2 = start_tracker(:persist_b)
    assert Tracker.familiarity(server2, path) =~ "opened 2"
  end
end
