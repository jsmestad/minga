defmodule MingaAdversarial.WatcherTest do
  # Drives the real global Minga.Diagnostics + Events registries, so not async.
  use ExUnit.Case, async: false

  alias Minga.Diagnostics
  alias Minga.Events
  alias Minga.Events.BufferClosedEvent
  alias Minga.Extension.Diagnostics, as: ExtDiagnostics
  alias Minga.LSP.SyncServer
  alias MingaAdversarial.Watcher

  @ext :minga_adversarial

  setup do
    path = Path.join(System.tmp_dir!(), "adv_#{System.unique_integer([:positive])}.ex")
    File.write!(path, "defmodule Foo do\n  def bar(list), do: hd(list)\nend\n")
    uri = SyncServer.path_to_uri(path)

    on_exit(fn ->
      ExtDiagnostics.clear_all(@ext)
      File.rm(path)
    end)

    %{path: path, uri: uri}
  end

  defp start_watcher(id, opts) do
    name = :"adv_watcher_#{id}"
    start_supervised!(%{id: id, start: {Watcher, :start_link, [[{:name, name} | opts]]}})
    name
  end

  defp one_finding, do: ~s([{"line": 2, "concern": "hd/1 assumes list is non-empty"}])

  defp flush(server), do: :sys.get_state(server)

  test "manual analyze publishes advisory findings to the gutter", %{path: path, uri: uri} do
    Events.subscribe(:diagnostics_updated)

    server =
      start_watcher(:manual_publish,
        skepticism: :manual,
        ai_fun: fn _messages, _max -> {:ok, one_finding()} end
      )

    assert :ok = Watcher.analyze(server, path)

    assert_receive {:minga_event, :diagnostics_updated,
                    %Events.DiagnosticsUpdatedEvent{uri: ^uri}},
                   2_000

    assert Diagnostics.gutter_signs_by_line(uri)[1] == :diag_advisory

    assert [%{message: "hd/1 assumes list is non-empty", severity: :hint}] =
             Diagnostics.for_uri(uri)
  end

  test "analyze uses provided live content instead of the file on disk", %{path: path} do
    File.write!(path, "on_disk_only\n")
    test_pid = self()

    server =
      start_watcher(:live_content,
        skepticism: :manual,
        ai_fun: fn messages, _max ->
          send(test_pid, {:msgs, messages})
          {:error, :stub}
        end
      )

    assert :ok = Watcher.analyze(server, path, "live_buffer_text\n")

    assert_receive {:msgs, messages}, 2_000
    user = Enum.find(messages, &(&1.role == "user")).content
    assert user =~ "live_buffer_text"
    refute user =~ "on_disk_only"
  end

  test "dial off makes analyze a no-op", %{path: path, uri: uri} do
    server =
      start_watcher(:off,
        skepticism: :off,
        ai_fun: fn _messages, _max -> {:ok, one_finding()} end
      )

    assert :off = Watcher.analyze(server, path)
    flush(server)
    assert Diagnostics.for_uri(uri) == []
  end

  test "manual dial does not analyze on save; on_save does", %{path: path} do
    test_pid = self()
    ai = fn _messages, _max -> send(test_pid, :ai_called) && {:error, :stub} end

    manual = start_watcher(:save_manual, skepticism: :manual, ai_fun: ai)
    send(manual, {:minga_event, :buffer_saved, %Events.BufferEvent{buffer: self(), path: path}})
    flush(manual)
    refute_received :ai_called

    on_save = start_watcher(:save_on, skepticism: :on_save, ai_fun: ai)
    send(on_save, {:minga_event, :buffer_saved, %Events.BufferEvent{buffer: self(), path: path}})
    assert_receive :ai_called, 2_000
  end

  test "stale replies from an older generation are dropped", %{path: path, uri: uri} do
    # No-op dispatch: the watcher never runs the model itself, so the test
    # fully controls which generation's reply arrives.
    server =
      start_watcher(:stale,
        skepticism: :manual,
        dispatch: fn _thunk -> :ok end,
        ai_fun: fn _messages, _max -> {:ok, one_finding()} end
      )

    # Generation 1, delivered for gen 1 → published.
    assert :ok = Watcher.analyze(server, path)
    send(server, {:ai_result, path, 1, {:ok, one_finding()}})
    flush(server)
    assert [%{message: "hd/1 assumes list is non-empty"}] = Diagnostics.for_uri(uri)

    # Generation 2 requested; the late gen-1 reply must be ignored.
    assert :ok = Watcher.analyze(server, path)
    send(server, {:ai_result, path, 1, {:ok, ~s([{"line": 1, "concern": "STALE"}])}})
    flush(server)
    assert [%{message: "hd/1 assumes list is non-empty"}] = Diagnostics.for_uri(uri)

    # The current gen-2 reply wins.
    send(server, {:ai_result, path, 2, {:ok, ~s([{"line": 1, "concern": "fresh"}])}})
    flush(server)
    assert [%{message: "fresh"}] = Diagnostics.for_uri(uri)
  end

  test "closing a buffer clears its findings", %{path: path, uri: uri} do
    server =
      start_watcher(:close,
        skepticism: :manual,
        dispatch: fn _thunk -> :ok end
      )

    Watcher.analyze(server, path)
    send(server, {:ai_result, path, 1, {:ok, one_finding()}})
    flush(server)
    assert Diagnostics.for_uri(uri) != []

    send(server, {:minga_event, :buffer_closed, %BufferClosedEvent{buffer: self(), path: path}})
    flush(server)
    assert Diagnostics.for_uri(uri) == []
  end

  test "closing a buffer drops an in-flight reply instead of republishing", %{
    path: path,
    uri: uri
  } do
    server =
      start_watcher(:close_stale,
        skepticism: :manual,
        dispatch: fn _thunk -> :ok end
      )

    # analyze starts generation 1; the buffer closes before the reply lands.
    Watcher.analyze(server, path)
    send(server, {:minga_event, :buffer_closed, %BufferClosedEvent{buffer: self(), path: path}})
    flush(server)

    # The late gen-1 reply must be dropped, not published onto the closed buffer.
    send(server, {:ai_result, path, 1, {:ok, one_finding()}})
    flush(server)
    assert Diagnostics.for_uri(uri) == []
  end

  test "cycle_skepticism advances through the dial", _ctx do
    server = start_watcher(:cycle, skepticism: :manual)

    assert Watcher.cycle_skepticism(server) == :on_save
    assert Watcher.cycle_skepticism(server) == :paranoid
    assert Watcher.cycle_skepticism(server) == :off
    assert Watcher.cycle_skepticism(server) == :manual
  end
end
