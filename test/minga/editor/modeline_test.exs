defmodule Minga.Editor.ModelineTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.Modeline
  alias Minga.Mode

  @base_data %{
    mode: :normal,
    mode_state: Mode.initial_state(),
    file_name: "test.ex",
    filetype: :elixir,
    dirty_marker: "",
    cursor_line: 0,
    cursor_col: 0,
    line_count: 10,
    buf_index: 1,
    buf_count: 1
  }

  describe "render/3" do
    test "returns draws and click regions" do
      {commands, regions} = Modeline.render(0, 80, @base_data)
      assert is_list(commands)
      assert commands != []
      assert Enum.all?(commands, &is_tuple/1)
      assert is_list(regions)
    end

    test "renders for all modes without crashing" do
      for mode <- [:normal, :insert, :visual, :operator_pending, :command, :replace] do
        data = Map.put(@base_data, :mode, mode)
        {commands, _regions} = Modeline.render(0, 80, data)
        assert commands != [], "Expected commands for mode #{mode}"
      end
    end

    test "renders with dirty marker" do
      data = Map.put(@base_data, :dirty_marker, " ● ")
      {commands, _} = Modeline.render(0, 80, data)
      assert commands != []
    end

    test "renders with multiple buffers" do
      data = Map.merge(@base_data, %{buf_index: 2, buf_count: 3})
      {commands, _} = Modeline.render(0, 80, data)
      assert commands != []
    end

    test "renders with single buffer (no indicator)" do
      data = Map.merge(@base_data, %{buf_index: 1, buf_count: 1})
      {commands, _} = Modeline.render(0, 80, data)
      assert commands != []
    end

    test "renders at top of file (line 0)" do
      data = Map.merge(@base_data, %{cursor_line: 0, line_count: 1})
      {commands, _} = Modeline.render(0, 80, data)
      assert commands != []
    end

    test "click regions include buffer_list for file segment" do
      {_commands, regions} = Modeline.render(0, 80, @base_data)
      assert Enum.any?(regions, fn {_start, _end, cmd} -> cmd == :buffer_list end)
    end

    test "buffer_list click region has correct column range" do
      {_commands, regions} = Modeline.render(0, 80, @base_data)

      {start_col, end_col, :buffer_list} =
        Enum.find(regions, fn {_, _, cmd} -> cmd == :buffer_list end)

      # Mode badge " NORMAL " = 8 display width, powerline separator "" = 0 width
      assert start_col == 8
      # File segment " test.ex " = 9 display width
      assert end_col == 17
    end
  end

  describe "cursor_shape/1" do
    test "insert mode returns beam" do
      assert Modeline.cursor_shape(:insert) == :beam
    end

    test "replace mode returns underline" do
      assert Modeline.cursor_shape(:replace) == :underline
    end

    test "normal mode returns block" do
      assert Modeline.cursor_shape(:normal) == :block
    end

    test "visual mode returns block" do
      assert Modeline.cursor_shape(:visual) == :block
    end

    test "command mode returns block" do
      assert Modeline.cursor_shape(:command) == :block
    end

    test "operator_pending mode returns block" do
      assert Modeline.cursor_shape(:operator_pending) == :block
    end
  end
end
