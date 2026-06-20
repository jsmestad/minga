defmodule MingaKnowledgeGraph.TrackerTest do
  # Drives the real Badge/Storage registries (global ETS), so not async.
  use ExUnit.Case, async: false

  alias Minga.Buffer
  alias Minga.Events.BufferChangedEvent
  alias Minga.Events.BufferEvent
  alias Minga.Extension.Badge
  alias Minga.Extension.Panel
  alias MingaKnowledgeGraph.Tracker

  @ext :minga_knowledge_graph

  setup do
    base = Path.join(System.tmp_dir!(), "kg_tracker_#{System.unique_integer([:positive])}")
    Application.put_env(:minga, :extension_data_dir, base)

    on_exit(fn ->
      Badge.remove_all(@ext)
      if :ets.whereis(Panel) != :undefined, do: Panel.remove_all(@ext)
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
  defp start_tracker(id, opts \\ []) do
    name = :"kg_tracker_#{id}"
    start_opts = Keyword.merge([name: name, seed: false], opts)
    start_supervised!(%{id: id, start: {Tracker, :start_link, [start_opts]}})
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

  test "user-sourced changes count as edits and update heat" do
    server = start_tracker(:user_edit)
    path = real_file_path("edit")
    buffer = start_supervised!({Buffer, file_path: path})
    open(server, path)

    deliver(
      server,
      {:minga_event, :buffer_changed,
       %BufferChangedEvent{source: :user, buffer: buffer, delta: nil, version: 1}}
    )

    assert Tracker.familiarity(server, path) =~ "edited 1"
    assert Map.has_key?(Badge.file_levels_map(), path)
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

  test "opening a real unfamiliar file records familiarity without auto-briefing" do
    test_pid = self()

    client = fn _model, messages, _opts ->
      send(test_pid, {:ai_called, messages})
      {:error, :unexpected_auto_briefing}
    end

    server = start_tracker(:no_auto_briefing, ai_client: client)
    path = real_file_path("no-auto")

    open(server, path)

    assert Tracker.familiarity(server, path) =~ "opened 1"
    refute_receive {:ai_called, _messages}, 100
    assert Panel.visible() |> Enum.filter(&(&1.extension == @ext)) == []
  end

  test "explicit briefing request starts the AI path without a network call" do
    test_pid = self()

    client = fn _model, messages, _opts ->
      send(test_pid, {:ai_called, messages})
      {:error, :stubbed}
    end

    server = start_tracker(:explicit_briefing, ai_client: client)
    path = real_file_path("explicit")

    Tracker.request_briefing(server, path)

    assert_receive {:ai_called, messages}, 2_000
    assert [%{role: "system"}, %{role: "user", content: content}] = messages
    assert content =~ path
    assert content =~ "defmodule Explicit"
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

  defp real_file_path(label) do
    dir = Path.join(System.tmp_dir!(), "kg_tracker_file_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    module = label |> String.replace("-", "_") |> Macro.camelize()
    path = Path.join(dir, "#{label}.ex")
    File.write!(path, "defmodule #{module} do\n  def run, do: :ok\nend\n")
    path
  end
end
