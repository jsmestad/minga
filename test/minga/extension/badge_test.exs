defmodule Minga.Extension.BadgeTest do
  use ExUnit.Case, async: true

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
      assert length(badges) == 1
      assert hd(badges).color == 0xFF0000
      assert hd(badges).animation == :pulse
    end

    test "multiple extensions can badge the same file" do
      :ok = Badge.set_file(:test_ext, "/tmp/test.ex", color: 0xFF0000)
      :ok = Badge.set_file(:other_ext, "/tmp/test.ex", color: 0x00FF00)

      badges = Badge.badges_for_path("/tmp/test.ex")
      assert length(badges) == 2
    end

    test "replaces badge with same extension + path" do
      :ok = Badge.set_file(:test_ext, "/tmp/test.ex", color: 0xFF0000)
      :ok = Badge.set_file(:test_ext, "/tmp/test.ex", color: 0x00FF00)

      badges = Badge.badges_for_path("/tmp/test.ex")
      assert length(badges) == 1
      assert hd(badges).color == 0x00FF00
    end
  end

  describe "set_tab/3 and badges_for_buffer/1" do
    test "registers a tab badge" do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      :ok = Badge.set_tab(:test_ext, pid, color: 0xFF0000)

      badges = Badge.badges_for_buffer(pid)
      assert length(badges) == 1
      assert hd(badges).color == 0xFF0000

      Process.exit(pid, :kill)
    end
  end

  describe "remove_file/2 and remove_tab/2" do
    test "removes a file badge" do
      :ok = Badge.set_file(:test_ext, "/tmp/a.ex")
      :ok = Badge.set_file(:test_ext, "/tmp/b.ex")
      :ok = Badge.remove_file(:test_ext, "/tmp/a.ex")

      assert Badge.all_file_badges() |> length() == 1
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

      assert length(Badge.all_file_badges()) == 1
      assert hd(Badge.all_file_badges()).extension == :other_ext
    end

    test "unregister_source cleans up extension badges" do
      :ok = Badge.set_file(:test_ext, "/tmp/a.ex")
      :ok = Badge.unregister_source({:extension, :test_ext})

      assert Badge.all_file_badges() == []
    end
  end
end
