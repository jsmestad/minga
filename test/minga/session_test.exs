defmodule Minga.SessionTest do
  use ExUnit.Case, async: true

  alias Minga.Session

  @moduletag :tmp_dir

  defp session_opts(tmp_dir), do: [session_dir: tmp_dir]

  defp sample_snapshot do
    %{
      version: 1,
      buffers: [
        %{file: "/tmp/a.ex", cursor_line: 10, cursor_col: 5},
        %{file: "/tmp/b.ex", cursor_line: 0, cursor_col: 0}
      ],
      active_file: "/tmp/a.ex",
      clean_shutdown: false
    }
  end

  describe "save/2 and load/1 round-trip" do
    test "preserves session snapshot", %{tmp_dir: tmp_dir} do
      opts = session_opts(tmp_dir)
      snapshot = sample_snapshot()

      :ok = Session.save(snapshot, opts)
      assert {:ok, loaded} = Session.load(opts)

      assert loaded.version == snapshot.version
      assert loaded.active_file == snapshot.active_file
      assert loaded.clean_shutdown == snapshot.clean_shutdown
      assert length(loaded.buffers) == length(snapshot.buffers)

      for {expected, actual} <- Enum.zip(snapshot.buffers, loaded.buffers) do
        assert actual.file == expected.file
        assert actual.cursor_line == expected.cursor_line
        assert actual.cursor_col == expected.cursor_col
      end
    end

    test "preserves empty buffer list", %{tmp_dir: tmp_dir} do
      opts = session_opts(tmp_dir)
      snapshot = %{version: 1, buffers: [], active_file: nil, clean_shutdown: false}

      :ok = Session.save(snapshot, opts)
      assert {:ok, loaded} = Session.load(opts)
      assert loaded.buffers == []
      assert loaded.active_file == nil
    end

    test "preserves file paths with special characters", %{tmp_dir: tmp_dir} do
      opts = session_opts(tmp_dir)
      tricky_path = "/tmp/my \"project\"/file\twith\\backslash.ex"

      snapshot = %{
        version: 1,
        buffers: [%{file: tricky_path, cursor_line: 1, cursor_col: 2}],
        active_file: tricky_path,
        clean_shutdown: false
      }

      :ok = Session.save(snapshot, opts)
      assert {:ok, loaded} = Session.load(opts)
      assert hd(loaded.buffers).file == tricky_path
    end

    test "atomic write leaves no .tmp file", %{tmp_dir: tmp_dir} do
      opts = session_opts(tmp_dir)
      :ok = Session.save(sample_snapshot(), opts)
      tmp_files = Path.wildcard(Path.join(tmp_dir, "*.tmp"))
      assert tmp_files == []
    end
  end

  describe "mark_clean_shutdown/1" do
    test "sets clean_shutdown to true", %{tmp_dir: tmp_dir} do
      opts = session_opts(tmp_dir)
      :ok = Session.save(sample_snapshot(), opts)

      :ok = Session.mark_clean_shutdown(opts)
      assert {:ok, loaded} = Session.load(opts)
      assert loaded.clean_shutdown == true
    end

    test "is safe when no session file exists", %{tmp_dir: tmp_dir} do
      opts = session_opts(tmp_dir)
      assert :ok = Session.mark_clean_shutdown(opts)
    end
  end

  describe "clean_shutdown?/1" do
    test "returns false when session was not cleanly shut down", %{tmp_dir: tmp_dir} do
      opts = session_opts(tmp_dir)
      :ok = Session.save(sample_snapshot(), opts)
      refute Session.clean_shutdown?(opts)
    end

    test "returns true after clean shutdown", %{tmp_dir: tmp_dir} do
      opts = session_opts(tmp_dir)
      :ok = Session.save(sample_snapshot(), opts)
      :ok = Session.mark_clean_shutdown(opts)
      assert Session.clean_shutdown?(opts)
    end

    test "returns false when no session file exists", %{tmp_dir: tmp_dir} do
      refute Session.clean_shutdown?(session_opts(tmp_dir))
    end
  end

  describe "load/1 error cases" do
    test "returns error for missing session file", %{tmp_dir: tmp_dir} do
      assert {:error, :enoent} = Session.load(session_opts(tmp_dir))
    end

    test "returns error for corrupt JSON", %{tmp_dir: tmp_dir} do
      opts = session_opts(tmp_dir)
      path = Session.session_file(opts)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "not json")
      assert {:error, _} = Session.load(opts)
    end

    test "returns error for valid JSON missing required keys", %{tmp_dir: tmp_dir} do
      opts = session_opts(tmp_dir)
      path = Session.session_file(opts)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, ~s({"foo": 1}))
      assert {:error, :invalid_format} = Session.load(opts)
    end
  end

  describe "forward compatibility" do
    test "loads session without version field (defaults to 1)", %{tmp_dir: tmp_dir} do
      opts = session_opts(tmp_dir)
      path = Session.session_file(opts)
      File.mkdir_p!(Path.dirname(path))
      # Simulate an old session file without version field
      json = ~s({"buffers":[],"active_file":null,"clean_shutdown":false})
      File.write!(path, json)

      assert {:ok, loaded} = Session.load(opts)
      assert loaded.version == 1
    end

    test "loads session with cursor defaults for missing fields", %{tmp_dir: tmp_dir} do
      opts = session_opts(tmp_dir)
      path = Session.session_file(opts)
      File.mkdir_p!(Path.dirname(path))
      # Buffer entry missing cursor fields
      json = ~s({"buffers":[{"file":"/tmp/x.ex"}],"active_file":null,"clean_shutdown":false})
      File.write!(path, json)

      assert {:ok, loaded} = Session.load(opts)
      buf = hd(loaded.buffers)
      assert buf.cursor_line == 0
      assert buf.cursor_col == 0
    end
  end
end
