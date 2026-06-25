defmodule Minga.Extension.BadgeTest do
  # Badge registry uses global ETS tables without table-parameter support.
  use ExUnit.Case, async: false

  alias Minga.Extension.Badge

  setup do
    on_exit(fn ->
      Badge.remove_all(:test_ext)
      Badge.remove_all(:other_ext)
    end)

    :ok
  end

  describe "set_file/3 and badges_for_path/1" do
    test "registers a file badge" do
      :ok = Badge.set_file(:test_ext, "/tmp/test.ex", color: 0xFF0000, animation: :pulse)

      badges = Badge.badges_for_path("/tmp/test.ex")
      assert Enum.count(badges) == 1
      assert hd(badges).color == 0xFF0000
      assert hd(badges).animation == :pulse
    end

    test "multiple extensions can badge the same file" do
      :ok = Badge.set_file(:test_ext, "/tmp/test.ex", color: 0xFF0000)
      :ok = Badge.set_file(:other_ext, "/tmp/test.ex", color: 0x00FF00)

      badges = Badge.badges_for_path("/tmp/test.ex")
      assert Enum.count(badges) == 2
    end

    test "replaces badge with same extension + path" do
      :ok = Badge.set_file(:test_ext, "/tmp/test.ex", color: 0xFF0000)
      :ok = Badge.set_file(:test_ext, "/tmp/test.ex", color: 0x00FF00)

      badges = Badge.badges_for_path("/tmp/test.ex")
      assert Enum.count(badges) == 1
      assert hd(badges).color == 0x00FF00
    end
  end

  describe "set_tab/3 and badges_for_buffer/1" do
    test "registers a tab badge" do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      :ok = Badge.set_tab(:test_ext, pid, color: 0xFF0000)

      badges = Badge.badges_for_buffer(pid)
      assert Enum.count(badges) == 1
      assert hd(badges).color == 0xFF0000

      Process.exit(pid, :kill)
    end
  end

  describe "remove_file/2 and remove_tab/2" do
    test "removes a file badge" do
      :ok = Badge.set_file(:test_ext, "/tmp/a.ex")
      :ok = Badge.set_file(:test_ext, "/tmp/b.ex")
      :ok = Badge.remove_file(:test_ext, "/tmp/a.ex")

      assert Badge.all_file_badges() |> Enum.count() == 1
    end

    test "removes a tab badge" do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      :ok = Badge.set_tab(:test_ext, pid)
      :ok = Badge.remove_tab(:test_ext, pid)

      assert Badge.badges_for_buffer(pid) == []
      Process.exit(pid, :kill)
    end
  end

  describe "remove_all/1 and unregister_source/1" do
    test "removes all badges for an extension" do
      :ok = Badge.set_file(:test_ext, "/tmp/a.ex")
      :ok = Badge.set_file(:other_ext, "/tmp/b.ex")
      :ok = Badge.remove_all(:test_ext)

      assert Enum.count(Badge.all_file_badges()) == 1
      assert hd(Badge.all_file_badges()).extension == :other_ext
    end

    test "unregister_source cleans up extension badges" do
      :ok = Badge.set_file(:test_ext, "/tmp/a.ex")
      :ok = Badge.unregister_source({:extension, :test_ext})

      assert Badge.all_file_badges() == []
    end
  end

  describe "level decorations and file_levels_map/0" do
    test "set_file stores a semantic level" do
      :ok = Badge.set_file(:test_ext, "/tmp/known.ex", level: 4)

      assert %{level: 4} = Badge.badges_for_path("/tmp/known.ex") |> hd()
    end

    test "file_levels_map keys absolute paths to their level" do
      :ok = Badge.set_file(:test_ext, "/tmp/known.ex", level: 4)

      assert Badge.file_levels_map()[Path.expand("/tmp/known.ex")] == 4
    end

    test "file_levels_map omits entries without a level" do
      :ok = Badge.set_file(:test_ext, "/tmp/plain.ex", color: 0xFF0000)

      refute Map.has_key?(Badge.file_levels_map(), Path.expand("/tmp/plain.ex"))
    end

    test "multiple extensions on one path compose by taking the max level" do
      :ok = Badge.set_file(:test_ext, "/tmp/shared.ex", level: 1)
      :ok = Badge.set_file(:other_ext, "/tmp/shared.ex", level: 3)

      assert Badge.file_levels_map()[Path.expand("/tmp/shared.ex")] == 3
    end

    test "invalid levels are treated as absent before the render path" do
      :ok = Badge.set_file(:test_ext, "/tmp/invalid.ex", level: 9)
      :ok = Badge.set_file(:other_ext, "/tmp/string.ex", level: "warm")

      assert %{level: nil} = Badge.badges_for_path("/tmp/invalid.ex") |> hd()
      refute Map.has_key?(Badge.file_levels_map(), Path.expand("/tmp/invalid.ex"))
      refute Map.has_key?(Badge.file_levels_map(), Path.expand("/tmp/string.ex"))
    end
  end
end
