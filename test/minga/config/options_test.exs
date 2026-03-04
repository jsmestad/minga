defmodule Minga.Config.OptionsTest do
  use ExUnit.Case, async: true

  alias Minga.Config.Options

  setup do
    {:ok, pid} = Options.start_link(name: :"options_#{System.unique_integer([:positive])}")
    %{server: pid}
  end

  describe "defaults" do
    test "tab_width defaults to 2", %{server: s} do
      assert Options.get(s, :tab_width) == 2
    end

    test "line_numbers defaults to :hybrid", %{server: s} do
      assert Options.get(s, :line_numbers) == :hybrid
    end

    test "autopair defaults to true", %{server: s} do
      assert Options.get(s, :autopair) == true
    end

    test "scroll_margin defaults to 5", %{server: s} do
      assert Options.get(s, :scroll_margin) == 5
    end

    test "all/1 returns all defaults", %{server: s} do
      assert Options.all(s) == %{
               tab_width: 2,
               line_numbers: :hybrid,
               autopair: true,
               scroll_margin: 5,
               theme: :doom_one
             }
    end
  end

  describe "set/3 and get/2" do
    test "set and get tab_width", %{server: s} do
      assert {:ok, 4} = Options.set(s, :tab_width, 4)
      assert Options.get(s, :tab_width) == 4
    end

    test "set and get line_numbers", %{server: s} do
      assert {:ok, :relative} = Options.set(s, :line_numbers, :relative)
      assert Options.get(s, :line_numbers) == :relative
    end

    test "set and get autopair", %{server: s} do
      assert {:ok, false} = Options.set(s, :autopair, false)
      assert Options.get(s, :autopair) == false
    end

    test "set and get scroll_margin", %{server: s} do
      assert {:ok, 10} = Options.set(s, :scroll_margin, 10)
      assert Options.get(s, :scroll_margin) == 10
    end

    test "scroll_margin accepts zero", %{server: s} do
      assert {:ok, 0} = Options.set(s, :scroll_margin, 0)
      assert Options.get(s, :scroll_margin) == 0
    end
  end

  describe "type validation" do
    test "tab_width rejects zero", %{server: s} do
      assert {:error, msg} = Options.set(s, :tab_width, 0)
      assert msg =~ "positive integer"
    end

    test "tab_width rejects negative", %{server: s} do
      assert {:error, _} = Options.set(s, :tab_width, -1)
    end

    test "tab_width rejects non-integer", %{server: s} do
      assert {:error, _} = Options.set(s, :tab_width, "4")
    end

    test "line_numbers rejects invalid atom", %{server: s} do
      assert {:error, msg} = Options.set(s, :line_numbers, :fancy)
      assert msg =~ "must be one of"
    end

    test "line_numbers rejects string", %{server: s} do
      assert {:error, _} = Options.set(s, :line_numbers, "hybrid")
    end

    test "autopair rejects non-boolean", %{server: s} do
      assert {:error, msg} = Options.set(s, :autopair, 1)
      assert msg =~ "boolean"
    end

    test "scroll_margin rejects negative", %{server: s} do
      assert {:error, _} = Options.set(s, :scroll_margin, -1)
    end

    test "unknown option returns error", %{server: s} do
      assert {:error, msg} = Options.set(s, :nonexistent, 42)
      assert msg =~ "unknown option"
    end
  end

  describe "reset/1" do
    test "restores all options to defaults", %{server: s} do
      Options.set(s, :tab_width, 8)
      Options.set(s, :autopair, false)
      Options.reset(s)

      assert Options.get(s, :tab_width) == 2
      assert Options.get(s, :autopair) == true
    end
  end

  describe "default/1" do
    test "returns the default for a known option" do
      assert Options.default(:tab_width) == 2
      assert Options.default(:line_numbers) == :hybrid
    end
  end

  describe "valid_names/0" do
    test "returns all option names" do
      names = Options.valid_names()
      assert :tab_width in names
      assert :line_numbers in names
      assert :autopair in names
      assert :scroll_margin in names
    end
  end

  describe "per-filetype options" do
    test "set_for_filetype overrides global for that filetype", %{server: s} do
      Options.set(s, :tab_width, 2)
      Options.set_for_filetype(s, :go, :tab_width, 8)

      assert Options.get_for_filetype(s, :tab_width, :go) == 8
      assert Options.get_for_filetype(s, :tab_width, :elixir) == 2
      assert Options.get(s, :tab_width) == 2
    end

    test "returns global value when no filetype override exists", %{server: s} do
      Options.set(s, :tab_width, 4)
      assert Options.get_for_filetype(s, :tab_width, :rust) == 4
    end

    test "returns global value when filetype is nil", %{server: s} do
      Options.set(s, :tab_width, 4)
      assert Options.get_for_filetype(s, :tab_width, nil) == 4
    end

    test "validates filetype option values", %{server: s} do
      assert {:error, _} = Options.set_for_filetype(s, :go, :tab_width, -1)
    end

    test "multiple filetypes can have different overrides", %{server: s} do
      Options.set_for_filetype(s, :go, :tab_width, 8)
      Options.set_for_filetype(s, :python, :tab_width, 4)

      assert Options.get_for_filetype(s, :tab_width, :go) == 8
      assert Options.get_for_filetype(s, :tab_width, :python) == 4
    end

    test "reset clears filetype overrides", %{server: s} do
      Options.set_for_filetype(s, :go, :tab_width, 8)
      Options.reset(s)
      assert Options.get_for_filetype(s, :tab_width, :go) == 2
    end
  end
end
