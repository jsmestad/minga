defmodule Minga.Extension.BadgeTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.Badge

  setup do
    file_table = :"badge_file_test_#{System.unique_integer([:positive])}"
    tab_table = :"badge_tab_test_#{System.unique_integer([:positive])}"
    :ets.new(file_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(tab_table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, file_table: file_table, tab_table: tab_table}
  end

  describe "set_file and badges_for_path" do
    test "registers a file badge", %{file_table: ft} do
      :ok = Badge.set_file(ft, :test_ext, "/tmp/test.ex", color: 0xFF0000, animation: :pulse)

      badges = Badge.badges_for_path(ft, "/tmp/test.ex")
      assert length(badges) == 1
      assert hd(badges).color == 0xFF0000
      assert hd(badges).animation == :pulse
    end

    test "multiple extensions can badge the same file", %{file_table: ft} do
      :ok = Badge.set_file(ft, :test_ext, "/tmp/test.ex", color: 0xFF0000)
      :ok = Badge.set_file(ft, :other_ext, "/tmp/test.ex", color: 0x00FF00)

      badges = Badge.badges_for_path(ft, "/tmp/test.ex")
      assert length(badges) == 2
    end

    test "replaces badge with same extension + path", %{file_table: ft} do
      :ok = Badge.set_file(ft, :test_ext, "/tmp/test.ex", color: 0xFF0000)
      :ok = Badge.set_file(ft, :test_ext, "/tmp/test.ex", color: 0x00FF00)

      badges = Badge.badges_for_path(ft, "/tmp/test.ex")
      assert length(badges) == 1
      assert hd(badges).color == 0x00FF00
    end
  end

  describe "set_tab and badges_for_buffer" do
    test "registers a tab badge", %{tab_table: tt} do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      :ok = Badge.set_tab(tt, :test_ext, pid, color: 0xFF0000)

      badges = Badge.badges_for_buffer(tt, pid)
      assert length(badges) == 1
      assert hd(badges).color == 0xFF0000

      Process.exit(pid, :kill)
    end
  end

  describe "remove_file and remove_tab" do
    test "removes a file badge", %{file_table: ft} do
      :ok = Badge.set_file(ft, :test_ext, "/tmp/a.ex", [])
      :ok = Badge.set_file(ft, :test_ext, "/tmp/b.ex", [])
      :ok = Badge.remove_file(ft, :test_ext, "/tmp/a.ex")

      assert length(Badge.all_file_badges(ft)) == 1
    end

    test "removes a tab badge", %{tab_table: tt} do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      :ok = Badge.set_tab(tt, :test_ext, pid, [])
      :ok = Badge.remove_tab(tt, :test_ext, pid)

      assert Badge.badges_for_buffer(tt, pid) == []
      Process.exit(pid, :kill)
    end
  end

  describe "remove_all" do
    test "removes all badges for an extension", %{file_table: ft, tab_table: tt} do
      :ok = Badge.set_file(ft, :test_ext, "/tmp/a.ex", [])
      :ok = Badge.set_file(ft, :other_ext, "/tmp/b.ex", [])
      :ok = Badge.remove_all(ft, tt, :test_ext)

      assert length(Badge.all_file_badges(ft)) == 1
      assert hd(Badge.all_file_badges(ft)).extension == :other_ext
    end
  end
end
