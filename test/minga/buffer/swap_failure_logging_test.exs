defmodule Minga.Buffer.SwapFailureLoggingTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Session.ControllableSwapBackend

  @moduletag :tmp_dir

  test "discard and delete backend failures are logged", %{tmp_dir: tmp_dir} do
    {buffer, path} = start_swap_buffer(tmp_dir)

    :ok = BufferProcess.replace_content(buffer, "obsolete content")
    {obsolete_worker, obsolete_generation} = trigger_swap(buffer, path, "obsolete content")
    :ok = BufferProcess.replace_content(buffer, "current content")
    send(buffer, :write_swap)
    :sys.get_state(buffer)

    discard_log =
      capture_log(fn ->
        release_prepare(
          obsolete_worker,
          obsolete_generation,
          discard: {:error, :injected_discard}
        )

        assert_receive {:swap_discarded, ^buffer, ^obsolete_worker, ^obsolete_generation, ^path,
                        "obsolete content", {:error, :injected_discard}}

        :sys.get_state(buffer)
      end)

    assert discard_log =~ "discard_failed"
    assert discard_log =~ "injected_discard"

    assert_receive {:swap_prepare, current_worker, current_generation, ^path, "current content"}
    release_prepare(current_worker, current_generation)

    assert_receive {:swap_published, ^buffer, ^current_worker, ^current_generation, ^path,
                    "current content", :ok}

    {delete_buffer, delete_path} =
      start_swap_buffer(Path.join(tmp_dir, "delete"),
        delete: {:error, :injected_delete}
      )

    delete_log = capture_log(fn -> assert :ok = BufferProcess.save(delete_buffer) end)

    assert_receive {:swap_deleted, ^delete_buffer, ^delete_path, {:error, :injected_delete}}
    assert delete_log =~ "delete_failed"
    assert delete_log =~ "injected_delete"
  end

  defp start_swap_buffer(tmp_dir, backend_options \\ []) do
    File.mkdir_p!(tmp_dir)
    path = Path.join(tmp_dir, "buffer.txt")
    File.write!(path, "saved content")

    buffer =
      start_supervised!(
        {BufferProcess,
         file_path: path,
         swap_dir: tmp_dir,
         swap_backend: ControllableSwapBackend,
         swap_backend_options:
           [controller: self(), os_pid: 99_999] |> Keyword.merge(backend_options)},
        id: make_ref()
      )

    {buffer, path}
  end

  defp trigger_swap(buffer, path, content) do
    send(buffer, :write_swap)
    :sys.get_state(buffer)
    assert_receive {:swap_prepare, worker, generation, ^path, ^content}
    {worker, generation}
  end

  defp release_prepare(worker, generation, controls \\ []) do
    result = if controls == [], do: :ok, else: {:ok, controls}
    send(worker, {:swap_prepare_result, generation, result})
    :ok
  end
end
