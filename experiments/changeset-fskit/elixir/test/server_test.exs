defmodule ChangesetFs.ServerTest do
  use ExUnit.Case, async: true

  alias ChangesetFs.Protocol
  alias ChangesetFs.Server

  @moduledoc """
  Tests the BEAM-side content server, including protocol round-trips
  over the Unix domain socket and latency benchmarks.

  These tests simulate what the FSKit extension would do: connect to the
  socket, send requests, receive responses.
  """

  setup do
    project = make_project(%{
      "lib/math.ex" => "defmodule Math do\n  def add(a, b), do: a + b\nend\n",
      "lib/util.ex" => "defmodule Util do\n  def shout(s), do: String.upcase(s)\nend\n",
      "lib/app.ex" => "defmodule App do\n  def run, do: :ok\nend\n",
      "test/math_test.exs" => "defmodule MathTest do\n  use ExUnit.Case\nend\n"
    })

    {:ok, server} = start_supervised(
      {Server, project_root: project, modifications: %{
        "lib/math.ex" => "defmodule Math do\n  def add(a, b), do: a + b\n  def sub(a, b), do: a - b\nend\n"
      }}
    )

    socket_path = Server.socket_path(server)

    # Small delay for acceptor to be ready
    Process.sleep(50)

    {:ok, socket} = :gen_tcp.connect(
      {:local, String.to_charlist(socket_path)},
      0,
      [:binary, packet: 4, active: false]
    )

    on_exit(fn -> :gen_tcp.close(socket); File.rm_rf!(project) end)

    %{server: server, socket: socket, project: project}
  end

  describe "lookup" do
    test "finds modified file", %{socket: socket} do
      :ok = :gen_tcp.send(socket, Protocol.encode_lookup("lib", "math.ex"))
      {:ok, data} = :gen_tcp.recv(socket, 0, 5000)
      {:ok, {:item, :file, size, "lib/math.ex"}} = Protocol.decode_response(data)
      assert size > 0
    end

    test "finds unmodified file from disk", %{socket: socket} do
      :ok = :gen_tcp.send(socket, Protocol.encode_lookup("lib", "util.ex"))
      {:ok, data} = :gen_tcp.recv(socket, 0, 5000)
      {:ok, {:item, :file, _size, "lib/util.ex"}} = Protocol.decode_response(data)
    end

    test "finds directory", %{socket: socket} do
      :ok = :gen_tcp.send(socket, Protocol.encode_lookup("", "lib"))
      {:ok, data} = :gen_tcp.recv(socket, 0, 5000)
      {:ok, {:item, :directory, 0, "lib"}} = Protocol.decode_response(data)
    end

    test "returns not_found for missing file", %{socket: socket} do
      :ok = :gen_tcp.send(socket, Protocol.encode_lookup("lib", "nonexistent.ex"))
      {:ok, data} = :gen_tcp.recv(socket, 0, 5000)
      {:error, {:not_found, _}} = Protocol.decode_response(data)
    end
  end

  describe "read" do
    test "reads modified file content from memory", %{socket: socket} do
      :ok = :gen_tcp.send(socket, Protocol.encode_read("lib/math.ex", 0, 999_999))
      {:ok, data} = :gen_tcp.recv(socket, 0, 5000)
      {:ok, {:data, content}} = Protocol.decode_response(data)
      assert content =~ "def sub(a, b)"
      assert content =~ "def add(a, b)"
    end

    test "reads unmodified file from disk", %{socket: socket} do
      :ok = :gen_tcp.send(socket, Protocol.encode_read("lib/util.ex", 0, 999_999))
      {:ok, data} = :gen_tcp.recv(socket, 0, 5000)
      {:ok, {:data, content}} = Protocol.decode_response(data)
      assert content =~ "def shout(s)"
    end

    test "reads with offset and count", %{socket: socket} do
      :ok = :gen_tcp.send(socket, Protocol.encode_read("lib/util.ex", 0, 10))
      {:ok, data} = :gen_tcp.recv(socket, 0, 5000)
      {:ok, {:data, content}} = Protocol.decode_response(data)
      assert byte_size(content) == 10
    end
  end

  describe "readdir" do
    test "lists directory with modified and unmodified files", %{socket: socket} do
      :ok = :gen_tcp.send(socket, Protocol.encode_readdir("lib"))
      {:ok, data} = :gen_tcp.recv(socket, 0, 5000)
      {:ok, {:entries, entries}} = Protocol.decode_response(data)

      names = Enum.map(entries, &elem(&1, 0)) |> Enum.sort()
      assert "math.ex" in names
      assert "util.ex" in names
      assert "app.ex" in names
    end

    test "lists root directory", %{socket: socket} do
      :ok = :gen_tcp.send(socket, Protocol.encode_readdir(""))
      {:ok, data} = :gen_tcp.recv(socket, 0, 5000)
      {:ok, {:entries, entries}} = Protocol.decode_response(data)

      names = Enum.map(entries, &elem(&1, 0)) |> Enum.sort()
      assert "lib" in names
      assert "test" in names
    end

    test "includes new files from modifications", %{server: server, socket: socket} do
      Server.update_file(server, "lib/new_module.ex", "defmodule New do\nend\n")

      :ok = :gen_tcp.send(socket, Protocol.encode_readdir("lib"))
      {:ok, data} = :gen_tcp.recv(socket, 0, 5000)
      {:ok, {:entries, entries}} = Protocol.decode_response(data)

      names = Enum.map(entries, &elem(&1, 0))
      assert "new_module.ex" in names
    end

    test "excludes deleted files", %{server: server, socket: socket} do
      Server.delete_file(server, "lib/app.ex")

      :ok = :gen_tcp.send(socket, Protocol.encode_readdir("lib"))
      {:ok, data} = :gen_tcp.recv(socket, 0, 5000)
      {:ok, {:entries, entries}} = Protocol.decode_response(data)

      names = Enum.map(entries, &elem(&1, 0))
      refute "app.ex" in names
    end
  end

  describe "getattr" do
    test "returns attributes for modified file", %{socket: socket} do
      :ok = :gen_tcp.send(socket, Protocol.encode_getattr("lib/math.ex"))
      {:ok, data} = :gen_tcp.recv(socket, 0, 5000)
      {:ok, {:attr, :file, size, _mtime, _mode}} = Protocol.decode_response(data)
      assert size > 0
    end

    test "returns attributes for unmodified file", %{socket: socket} do
      :ok = :gen_tcp.send(socket, Protocol.encode_getattr("lib/util.ex"))
      {:ok, data} = :gen_tcp.recv(socket, 0, 5000)
      {:ok, {:attr, :file, size, _mtime, _mode}} = Protocol.decode_response(data)
      assert size > 0
    end

    test "returns attributes for directory", %{socket: socket} do
      :ok = :gen_tcp.send(socket, Protocol.encode_getattr("lib"))
      {:ok, data} = :gen_tcp.recv(socket, 0, 5000)
      {:ok, {:attr, :directory, _size, _mtime, _mode}} = Protocol.decode_response(data)
    end
  end

  describe "latency benchmarks" do
    test "lookup round-trip latency", %{socket: socket} do
      # Warm up
      Enum.each(1..10, fn _ ->
        :ok = :gen_tcp.send(socket, Protocol.encode_lookup("lib", "math.ex"))
        {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
      end)

      # Measure 1000 round-trips
      {time_us, _} = :timer.tc(fn ->
        Enum.each(1..1000, fn _ ->
          :ok = :gen_tcp.send(socket, Protocol.encode_lookup("lib", "math.ex"))
          {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
        end)
      end)

      per_request_us = time_us / 1000
      IO.puts("\n  LOOKUP: #{Float.round(per_request_us, 1)}µs per request (1000 iterations)")
      # Target: < 100µs
      assert per_request_us < 500
    end

    test "read round-trip latency (small file)", %{socket: socket} do
      Enum.each(1..10, fn _ ->
        :ok = :gen_tcp.send(socket, Protocol.encode_read("lib/math.ex", 0, 999_999))
        {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
      end)

      {time_us, _} = :timer.tc(fn ->
        Enum.each(1..1000, fn _ ->
          :ok = :gen_tcp.send(socket, Protocol.encode_read("lib/math.ex", 0, 999_999))
          {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
        end)
      end)

      per_request_us = time_us / 1000
      IO.puts("  READ (modified, in-memory): #{Float.round(per_request_us, 1)}µs per request")
      assert per_request_us < 500
    end

    test "read round-trip latency (passthrough to disk)", %{socket: socket} do
      Enum.each(1..10, fn _ ->
        :ok = :gen_tcp.send(socket, Protocol.encode_read("lib/util.ex", 0, 999_999))
        {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
      end)

      {time_us, _} = :timer.tc(fn ->
        Enum.each(1..1000, fn _ ->
          :ok = :gen_tcp.send(socket, Protocol.encode_read("lib/util.ex", 0, 999_999))
          {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
        end)
      end)

      per_request_us = time_us / 1000
      IO.puts("  READ (passthrough, disk): #{Float.round(per_request_us, 1)}µs per request")
      assert per_request_us < 500
    end

    test "readdir round-trip latency", %{socket: socket} do
      Enum.each(1..10, fn _ ->
        :ok = :gen_tcp.send(socket, Protocol.encode_readdir("lib"))
        {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
      end)

      {time_us, _} = :timer.tc(fn ->
        Enum.each(1..1000, fn _ ->
          :ok = :gen_tcp.send(socket, Protocol.encode_readdir("lib"))
          {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
        end)
      end)

      per_request_us = time_us / 1000
      IO.puts("  READDIR: #{Float.round(per_request_us, 1)}µs per request")
      assert per_request_us < 500
    end

    test "simulated mix compile: 500 file reads", %{server: server, socket: socket, project: project} do
      # Create 500 files in the project
      Enum.each(1..500, fn i ->
        path = "lib/mod_#{i}.ex"
        content = "defmodule Mod#{i} do\n  def value, do: #{i}\nend\n"
        File.write!(Path.join(project, path), content)
      end)

      # Modify 20 of them in the changeset
      Enum.each(1..20, fn i ->
        content = "defmodule Mod#{i} do\n  def value, do: #{i * 100}\nend\n"
        Server.update_file(server, "lib/mod_#{i}.ex", content)
      end)

      # Simulate: readdir(lib) + 500 reads
      {time_us, _} = :timer.tc(fn ->
        # readdir
        :ok = :gen_tcp.send(socket, Protocol.encode_readdir("lib"))
        {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

        # read each file
        Enum.each(1..500, fn i ->
          :ok = :gen_tcp.send(socket, Protocol.encode_read("lib/mod_#{i}.ex", 0, 999_999))
          {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
        end)
      end)

      total_ms = time_us / 1000
      per_file_us = time_us / 501
      IO.puts("  SIMULATED COMPILE (501 requests): #{Float.round(total_ms, 1)}ms total, #{Float.round(per_file_us, 1)}µs per file")
      # Target: < 200ms total for 500 files
      assert total_ms < 500
    end
  end

  defp make_project(files) do
    project = Path.join(System.tmp_dir!(), "fskit-test-#{System.unique_integer([:positive])}")

    Enum.each(files, fn {path, content} ->
      full = Path.join(project, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end)

    project
  end
end
