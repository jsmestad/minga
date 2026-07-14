defmodule Minga.Frontend.WaitRequestsTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.WaitRequests

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "minga-wait-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    server = start_supervised!({WaitRequests, name: nil, allowed_root: root})
    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root, server: server}
  end

  test "acknowledges an opened file and exits zero after accept", %{root: root, server: server} do
    result = result_path(root)

    buffer =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert :ok = WaitRequests.register(buffer, result, server)
    assert File.read!(Path.join(Path.dirname(result), "ack")) == "accepted\n"
    refute File.exists?(result)

    assert :ok = WaitRequests.accept(buffer, server)
    assert File.read!(result) == "0\n"
    send(buffer, :stop)
  end

  test "cancel and abort completions are non-zero", %{root: root, server: server} do
    result = result_path(root)

    buffer =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert :ok = WaitRequests.register(buffer, result, server)
    assert :ok = WaitRequests.cancel(buffer, "editor aborted", server)
    assert File.read!(result) == "1\teditor aborted\n"
    send(buffer, :stop)
  end

  test "file-open failure completes without an acknowledgement", %{root: root, server: server} do
    result = result_path(root)

    assert :ok = WaitRequests.fail_open(result, :enoent, server)
    refute File.exists?(Path.join(Path.dirname(result), "ack"))
    assert File.read!(result) =~ "1\tfile open failed: :enoent"
  end

  test "rejects response paths outside the app-local wait directory", %{server: server} do
    buffer =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    outside = Path.join(System.tmp_dir!(), "result")

    assert {:error, :invalid_result_path} = WaitRequests.register(buffer, outside, server)
    send(buffer, :stop)
  end

  defp result_path(root) do
    request_dir = Path.join(root, "request-#{System.unique_integer([:positive])}")
    File.mkdir_p!(request_dir)
    Path.join(request_dir, "result")
  end
end
