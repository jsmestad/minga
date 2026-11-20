defmodule MingaAdversarial.WatcherTest do
  # Drives the real global Minga.Diagnostics + Events registries, so not async.
  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Diagnostics
  alias Minga.Events
  alias Minga.Events.BufferChangedEvent
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

  defp start_capturing_watcher(id, skepticism \\ :manual) do
    test_pid = self()

    start_watcher(id,
      skepticism: skepticism,
      dispatch: fn thunk -> send(test_pid, {:dispatch, thunk}) end,
      ai_fun: fn _messages, _max ->
        assert_receive {:model_result, result}
        result
      end
    )
  end

  defp capture_analysis(server, path) do
    assert :ok = Watcher.analyze(server, path)
    assert_receive {:dispatch, thunk}
    thunk
  end

  defp deliver_reply(server, thunk, result \\ {:ok, one_finding()}) do
    send(self(), {:model_result, result})
    thunk.()
    flush(server)
  end

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
    server = start_capturing_watcher(:off, :off)

    assert :off = Watcher.analyze(server, path)
    refute_received {:dispatch, _thunk}
    assert Diagnostics.for_uri(uri) == []
  end

  test "manual dial does not analyze on save; on_save does", %{path: path} do
    test_pid = self()

    ai = fn _messages, _max ->
      send(test_pid, :ai_called)
      {:error, :stub}
    end

    manual = start_watcher(:save_manual, skepticism: :manual, ai_fun: ai)
    send(manual, {:minga_event, :buffer_saved, %Events.BufferEvent{buffer: self(), path: path}})
    flush(manual)
    refute_received :ai_called

    on_save = start_watcher(:save_on, skepticism: :on_save, ai_fun: ai)
    send(on_save, {:minga_event, :buffer_saved, %Events.BufferEvent{buffer: self(), path: path}})
    assert_receive :ai_called, 2_000
  end

  test "an older reply does not publish or displace the newer request", %{path: path, uri: uri} do
    server = start_capturing_watcher(:stale)
    older = capture_analysis(server, path)
    newer = capture_analysis(server, path)

    deliver_reply(server, older)
    assert Diagnostics.for_uri(uri) == []

    deliver_reply(server, newer, {:ok, ~s([{"line": 1, "concern": "fresh"}])})
    assert [%{message: "fresh"}] = Diagnostics.for_uri(uri)

    deliver_reply(server, newer, {:ok, "[]"})
    assert [%{message: "fresh"}] = Diagnostics.for_uri(uri)
  end

  test "failed source reads and oversized requests leave the admitted analysis pending", %{
    path: path,
    uri: uri
  } do
    server = start_capturing_watcher(:rejected)
    pending = capture_analysis(server, path)

    File.rm!(path)
    assert :ok = Watcher.analyze(server, path)
    assert :ok = Watcher.analyze(server, path, String.duplicate("x", 100_001))
    refute_received {:dispatch, _thunk}

    deliver_reply(server, pending)
    assert [%{message: "hd/1 assumes list is non-empty"}] = Diagnostics.for_uri(uri)
  end

  test "a model error retains findings but consumes its request; an empty success clears", %{
    path: path,
    uri: uri
  } do
    server = start_capturing_watcher(:terminal)
    deliver_reply(server, capture_analysis(server, path))
    assert [%{message: "hd/1 assumes list is non-empty"}] = Diagnostics.for_uri(uri)

    failed = capture_analysis(server, path)
    deliver_reply(server, failed, {:error, :unavailable})
    assert [%{message: "hd/1 assumes list is non-empty"}] = Diagnostics.for_uri(uri)

    deliver_reply(server, failed, {:ok, "[]"})
    assert [%{message: "hd/1 assumes list is non-empty"}] = Diagnostics.for_uri(uri)

    deliver_reply(server, capture_analysis(server, path), {:ok, "[]"})
    assert Diagnostics.for_uri(uri) == []
  end

  test "explicit clear drops findings and any pending reply", %{path: path, uri: uri} do
    server = start_capturing_watcher(:clear)
    deliver_reply(server, capture_analysis(server, path))
    assert [_] = Diagnostics.for_uri(uri)
    pending = capture_analysis(server, path)

    assert :ok = Watcher.clear(server, path)
    flush(server)
    assert Diagnostics.for_uri(uri) == []

    deliver_reply(server, pending)
    assert Diagnostics.for_uri(uri) == []
  end

  test "a user edit drops findings and any pending reply", %{path: path, uri: uri} do
    buffer = start_supervised!({BufferProcess, file_path: path})
    server = start_capturing_watcher(:edit)
    deliver_reply(server, capture_analysis(server, path))
    assert [_] = Diagnostics.for_uri(uri)
    pending = capture_analysis(server, path)

    event = %BufferChangedEvent{buffer: buffer, source: :user, sequence: 1}
    send(server, {:minga_event, :buffer_changed, event})

    flush(server)
    assert Diagnostics.for_uri(uri) == []

    deliver_reply(server, pending)
    assert Diagnostics.for_uri(uri) == []
  end

  test "close drops findings and pending replies, even after reopening the same path", %{
    path: path,
    uri: uri
  } do
    buffer = start_supervised!({BufferProcess, file_path: path})
    server = start_capturing_watcher(:reopen)
    deliver_reply(server, capture_analysis(server, path))
    assert [_] = Diagnostics.for_uri(uri)
    before_close = capture_analysis(server, path)

    send(server, {:minga_event, :buffer_closed, %BufferClosedEvent{buffer: buffer, path: path}})
    stop_supervised!(BufferProcess)
    flush(server)
    assert Diagnostics.for_uri(uri) == []

    deliver_reply(server, before_close)
    assert Diagnostics.for_uri(uri) == []

    start_supervised!({BufferProcess, file_path: path})
    after_reopen = capture_analysis(server, path)
    deliver_reply(server, before_close)
    assert Diagnostics.for_uri(uri) == []

    deliver_reply(server, after_reopen)
    assert [%{message: "hd/1 assumes list is non-empty"}] = Diagnostics.for_uri(uri)
  end

  test "cycle_skepticism advances through the dial", _ctx do
    server = start_watcher(:cycle, skepticism: :manual)

    assert Watcher.cycle_skepticism(server) == :on_save
    assert Watcher.cycle_skepticism(server) == :paranoid
    assert Watcher.cycle_skepticism(server) == :off
    assert Watcher.cycle_skepticism(server) == :manual
  end
end
