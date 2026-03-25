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
    buf_count: 1,
    macro_recording: false
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

    test "operator_pending mode shows NORMAL badge, not OPERATOR" do
      data = Map.put(@base_data, :mode, :operator_pending)
      {commands, _regions} = Modeline.render(0, 80, data)

      texts =
        Enum.map(commands, fn {_row, _col, text, _opts} -> text end)

      assert Enum.any?(texts, &String.contains?(&1, "NORMAL")),
             "Expected NORMAL badge in operator_pending mode, got: #{inspect(texts)}"

      refute Enum.any?(texts, &String.contains?(&1, "OPERATOR")),
             "Should not show OPERATOR badge in operator_pending mode"
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

    test "filetype segment includes devicon for known filetype" do
      {commands, _regions} = Modeline.render(0, 120, @base_data)

      texts = Enum.map(commands, fn {_row, _col, text, _opts} -> text end)
      combined = Enum.join(texts)

      # Elixir devicon should appear somewhere in the modeline
      {icon, _color} = Minga.UI.Devicon.icon_and_color(:elixir)
      assert String.contains?(combined, icon)
    end

    test "filetype segment is clickable with filetype_menu target" do
      {_commands, regions} = Modeline.render(0, 120, @base_data)
      assert Enum.any?(regions, fn {_start, _end, cmd} -> cmd == :filetype_menu end)
    end

    test "LSP indicator shows green dot when ready" do
      data = Map.put(@base_data, :lsp_status, :ready)
      {commands, _regions} = Modeline.render(0, 120, data)

      texts = Enum.map(commands, fn {_row, _col, text, _opts} -> text end)
      combined = Enum.join(texts)
      assert String.contains?(combined, "●")
    end

    test "LSP indicator shows spinner when initializing" do
      data = Map.put(@base_data, :lsp_status, :initializing)
      {commands, _regions} = Modeline.render(0, 120, data)

      texts = Enum.map(commands, fn {_row, _col, text, _opts} -> text end)
      combined = Enum.join(texts)
      assert String.contains?(combined, "⟳")
    end

    test "LSP indicator shows dimmed circle when starting" do
      data = Map.put(@base_data, :lsp_status, :starting)
      {commands, _regions} = Modeline.render(0, 120, data)

      texts = Enum.map(commands, fn {_row, _col, text, _opts} -> text end)
      combined = Enum.join(texts)
      assert String.contains?(combined, "◯")
    end

    test "LSP indicator shows error mark when errored" do
      data = Map.put(@base_data, :lsp_status, :error)
      {commands, _regions} = Modeline.render(0, 120, data)

      texts = Enum.map(commands, fn {_row, _col, text, _opts} -> text end)
      combined = Enum.join(texts)
      assert String.contains?(combined, "✗")
    end

    test "no LSP indicator when status is none" do
      data = Map.put(@base_data, :lsp_status, :none)
      {commands, _regions} = Modeline.render(0, 120, data)

      texts = Enum.map(commands, fn {_row, _col, text, _opts} -> text end)
      combined = Enum.join(texts)
      refute String.contains?(combined, "●")
      refute String.contains?(combined, "⟳")
      refute String.contains?(combined, "✗")
    end

    test "no LSP indicator when lsp_status key is absent" do
      {commands, _regions} = Modeline.render(0, 120, @base_data)

      texts = Enum.map(commands, fn {_row, _col, text, _opts} -> text end)
      combined = Enum.join(texts)
      refute String.contains?(combined, "●")
      refute String.contains?(combined, "⟳")
      refute String.contains?(combined, "✗")
    end

    test "LSP indicator is clickable with lsp_info target" do
      data = Map.put(@base_data, :lsp_status, :ready)
      {_commands, regions} = Modeline.render(0, 120, data)
      assert Enum.any?(regions, fn {_start, _end, cmd} -> cmd == :lsp_info end)
    end
  end

  describe "git branch and diff summary" do
    test "shows branch name with icon when git_branch is set" do
      data = Map.put(@base_data, :git_branch, "main")
      {commands, _regions} = Modeline.render(0, 120, data)

      texts = Enum.map(commands, fn {_row, _col, text, _opts} -> text end)
      combined = Enum.join(texts)
      assert String.contains?(combined, "main")
      assert String.contains?(combined, "\uE0A0")
    end

    test "shows diff stats with colors when git_diff_summary is set" do
      data = Map.merge(@base_data, %{git_branch: "feat/x", git_diff_summary: {3, 2, 1}})
      {commands, _regions} = Modeline.render(0, 120, data)

      texts = Enum.map(commands, fn {_row, _col, text, _opts} -> text end)
      combined = Enum.join(texts)
      assert String.contains?(combined, "+3")
      assert String.contains?(combined, "~2")
      assert String.contains?(combined, "-1")
    end

    test "shows only non-zero diff stats" do
      data = Map.merge(@base_data, %{git_branch: "main", git_diff_summary: {5, 0, 0}})
      {commands, _regions} = Modeline.render(0, 120, data)

      texts = Enum.map(commands, fn {_row, _col, text, _opts} -> text end)
      combined = Enum.join(texts)
      assert String.contains?(combined, "+5")
      refute String.contains?(combined, "~0")
      refute String.contains?(combined, "-0")
    end

    test "no diff stats when summary is {0, 0, 0}" do
      data = Map.merge(@base_data, %{git_branch: "main", git_diff_summary: {0, 0, 0}})
      {commands, _regions} = Modeline.render(0, 120, data)

      texts = Enum.map(commands, fn {_row, _col, text, _opts} -> text end)
      combined = Enum.join(texts)
      assert String.contains?(combined, "main")
      refute String.contains?(combined, "+")
      refute String.contains?(combined, "~")
    end

    test "no git segment when git_branch is nil" do
      {commands, _regions} = Modeline.render(0, 120, @base_data)

      texts = Enum.map(commands, fn {_row, _col, text, _opts} -> text end)
      combined = Enum.join(texts)
      # The branch icon  (U+E0A0) should not appear in the modeline
      refute String.contains?(combined, "\uE0A0")
    end

    test "no git segment when git_branch is empty string" do
      data = Map.put(@base_data, :git_branch, "")
      {commands, _regions} = Modeline.render(0, 120, data)

      texts = Enum.map(commands, fn {_row, _col, text, _opts} -> text end)
      combined = Enum.join(texts)
      refute String.contains?(combined, "\uE0A0")
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

    test "command mode returns beam (text input mode)" do
      assert Modeline.cursor_shape(:command) == :beam
    end

    test "eval mode returns beam (text input mode)" do
      assert Modeline.cursor_shape(:eval) == :beam
    end

    test "search_prompt mode returns beam (text input mode)" do
      assert Modeline.cursor_shape(:search_prompt) == :beam
    end

    test "operator_pending mode returns block" do
      assert Modeline.cursor_shape(:operator_pending) == :block
    end
  end

  describe "parser status indicator" do
    test "shows nothing when parser is available" do
      data = Map.put(@base_data, :parser_status, :available)
      {commands, _regions} = Modeline.render(0, 120, data)
      texts = Enum.map(commands, fn {_row, _col, text, _opts} -> text end)
      refute Enum.any?(texts, &String.contains?(&1, "🌳"))
    end

    test "shows tree icon with ✗ when parser is unavailable" do
      data = Map.put(@base_data, :parser_status, :unavailable)
      {commands, _regions} = Modeline.render(0, 120, data)
      texts = Enum.map(commands, fn {_row, _col, text, _opts} -> text end)
      assert Enum.any?(texts, &String.contains?(&1, "🌳✗"))
    end

    test "shows tree icon with spinner when parser is restarting" do
      data = Map.put(@base_data, :parser_status, :restarting)
      {commands, _regions} = Modeline.render(0, 120, data)
      texts = Enum.map(commands, fn {_row, _col, text, _opts} -> text end)
      assert Enum.any?(texts, &String.contains?(&1, "🌳⟳"))
    end

    test "parser unavailable indicator is clickable to parser_restart" do
      data = Map.put(@base_data, :parser_status, :unavailable)
      {_commands, regions} = Modeline.render(0, 120, data)
      assert Enum.any?(regions, fn {_start, _end, cmd} -> cmd == :parser_restart end)
    end
  end

  describe "diagnostic counts" do
    test "shows error count with icon when errors present" do
      data = Map.put(@base_data, :diagnostic_counts, {3, 0, 0, 0})
      {commands, _regions} = Modeline.render(0, 120, data)
      texts = Enum.map(commands, fn {_r, _c, text, _s} -> text end)
      assert Enum.any?(texts, &String.contains?(&1, "3"))
    end

    test "shows warning count with icon when warnings present" do
      data = Map.put(@base_data, :diagnostic_counts, {0, 5, 0, 0})
      {commands, _regions} = Modeline.render(0, 120, data)
      texts = Enum.map(commands, fn {_r, _c, text, _s} -> text end)
      assert Enum.any?(texts, &String.contains?(&1, "5"))
    end

    test "shows both error and warning counts" do
      data = Map.put(@base_data, :diagnostic_counts, {2, 3, 0, 0})
      {commands, _regions} = Modeline.render(0, 120, data)
      texts = Enum.map(commands, fn {_r, _c, text, _s} -> text end)
      assert Enum.any?(texts, &String.contains?(&1, "2"))
      assert Enum.any?(texts, &String.contains?(&1, "3"))
    end

    test "shows nothing when no diagnostics" do
      data = Map.put(@base_data, :diagnostic_counts, nil)
      {commands_with, _} = Modeline.render(0, 120, data)
      {commands_without, _} = Modeline.render(0, 120, @base_data)
      # Both should produce the same output (no diagnostic segment)
      assert length(commands_with) == length(commands_without)
    end

    test "diagnostic counts are clickable to diagnostic_list" do
      data = Map.put(@base_data, :diagnostic_counts, {1, 0, 0, 0})
      {_commands, regions} = Modeline.render(0, 120, data)
      assert Enum.any?(regions, fn {_start, _end, cmd} -> cmd == :diagnostic_list end)
    end
  end
end
