defmodule Minga.Config.WriterTest do
  use ExUnit.Case, async: true

  alias Minga.Config.Writer

  describe "GUI settings overlay" do
    test "writes only changed values using the config DSL" do
      path = tmp_path("gui_settings.exs")
      {:ok, writer} = start_supervised({Writer, name: nil, path: path, debounce_ms: 10})

      assert :ok = Writer.persist(writer, :theme, :doom_one)
      assert :ok = Writer.persist(writer, :font_size, 16)
      assert :ok = Writer.persist(writer, :wrap, true)
      assert :ok = Writer.flush(writer)

      content = File.read!(path)
      assert content =~ "use Minga.Config"
      refute content =~ "set :theme"
      assert content =~ "set :font_size, 16"
      assert content =~ "set :wrap, true"
    end

    test "keeps existing GUI settings when writing another option" do
      path = tmp_path("gui_settings_existing.exs")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "use Minga.Config\n\nset :font_size, 18\n")

      {:ok, writer} = start_supervised({Writer, name: nil, path: path, debounce_ms: 10})

      assert :ok = Writer.persist(writer, :wrap, true)
      assert :ok = Writer.flush(writer)

      content = File.read!(path)
      assert content =~ "set :font_size, 18"
      assert content =~ "set :wrap, true"
    end

    test "pending writes flush before reload starts" do
      path = tmp_path("gui_settings_reload_start.exs")
      {:ok, writer} = start_supervised({Writer, name: nil, path: path, debounce_ms: 10_000})

      assert :ok = Writer.persist(writer, :wrap, true)
      assert :ok = Writer.set_reloading(writer, true)

      content = File.read!(path)
      assert content =~ "set :wrap, true"
    end

    test "reload guard skips a flush during reload and reschedules it after reload ends" do
      path = tmp_path("gui_settings_reloading.exs")
      {:ok, writer} = start_supervised({Writer, name: nil, path: path, debounce_ms: 10})

      assert :ok = Writer.set_reloading(writer, true)
      assert :ok = Writer.persist(writer, :wrap, true)
      send(writer, :flush)
      :sys.get_state(writer)

      refute File.exists?(path)

      assert :ok = Writer.set_reloading(writer, false)
      state = :sys.get_state(writer)
      assert state.timer != nil

      send(writer, :flush)
      :sys.get_state(writer)

      content = File.read!(path)
      assert content =~ "set :wrap, true"
    end

    test "write errors do not crash the writer" do
      file_parent = tmp_path("not_a_directory")
      File.mkdir_p!(Path.dirname(file_parent))
      File.write!(file_parent, "not a directory")

      {:ok, writer} =
        start_supervised(
          {Writer, name: nil, path: Path.join(file_parent, "gui_settings.exs"), debounce_ms: 10}
        )

      ref = Process.monitor(writer)
      assert :ok = Writer.persist(writer, :wrap, true)
      assert :ok = Writer.flush(writer)
      refute_receive {:DOWN, ^ref, :process, ^writer, _reason}, 0
      Process.demonitor(ref, [:flush])
    end

    test "normal shutdown flushes pending writes before the debounce fires" do
      path = tmp_path("gui_settings_shutdown.exs")
      {:ok, writer} = Writer.start_link(name: nil, path: path, debounce_ms: 10_000)

      assert :ok = Writer.persist(writer, :wrap, true)
      GenServer.stop(writer, :normal)

      content = File.read!(path)
      assert content =~ "set :wrap, true"
    end
  end

  defp tmp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "minga-writer-test-#{System.unique_integer([:positive])}/#{name}"
    )
  end
end
