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

    test "reload guard skips writes while reload is active" do
      path = tmp_path("gui_settings_reloading.exs")
      {:ok, writer} = start_supervised({Writer, name: nil, path: path, debounce_ms: 10})

      assert :ok = Writer.set_reloading(writer, true)
      assert :ok = Writer.persist(writer, :wrap, true)
      assert :ok = Writer.flush(writer)

      refute File.exists?(path)
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
  end

  defp tmp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "minga-writer-test-#{System.unique_integer([:positive])}/#{name}"
    )
  end
end
