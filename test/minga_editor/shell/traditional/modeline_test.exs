defmodule MingaEditor.Shell.Traditional.ModelineTest do
  use ExUnit.Case, async: true

  alias Minga.Config.ModelineSegments
  alias Minga.Config.Options
  alias Minga.Mode
  alias MingaEditor.Shell.Traditional.Modeline

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

    test "renders common file state variants" do
      for data <- [
            Map.put(@base_data, :dirty_marker, " ● "),
            Map.merge(@base_data, %{buf_index: 2, buf_count: 3}),
            Map.merge(@base_data, %{buf_index: 1, buf_count: 1}),
            Map.merge(@base_data, %{cursor_line: 0, line_count: 1})
          ] do
        {commands, _} = Modeline.render(0, 80, data)
        assert commands != []
      end
    end

    test "click regions include buffer_list for file segment" do
      {_commands, regions} = Modeline.render(0, 80, @base_data)
      assert Enum.any?(regions, fn {_start, _end, cmd} -> cmd == :buffer_list end)
    end

    test "shows running background subagent count and active label" do
      data =
        Map.merge(@base_data, %{
          background_subagent_count: 2,
          active_background_subagent_label: "session-3: tests"
        })

      {commands, regions} = Modeline.render(0, 140, data)
      text = Enum.map_join(commands, fn {_row, _col, segment, _opts} -> segment end)

      assert String.contains?(text, "bg:2")
      assert String.contains?(text, "session-3: tests")
      assert Enum.any?(regions, fn {_start, _end, cmd} -> cmd == :agent_session_switcher end)
      refute Enum.any?(regions, fn {_start, _end, cmd} -> cmd == :agent_session_picker end)
    end

    test "omits background subagent segment when none are running" do
      data =
        Map.merge(@base_data, %{
          background_subagent_count: 0,
          active_background_subagent_label: "unique-bg-label"
        })

      {commands, _regions} = Modeline.render(0, 140, data)
      text = Enum.map_join(commands, fn {_row, _col, segment, _opts} -> segment end)

      refute String.contains?(text, "unique-bg-label")
    end

    test "always renders workspace identity and review counters when configured" do
      with_options(fn options ->
        Options.set(options, :modeline_left_segments, [:mode, :workspace, :filename])
        Options.set(options, :modeline_right_segments, [:draft, :conflict])

        data =
          Map.merge(@base_data, %{
            workspace_label: "Agent: tests",
            workspace_draft_count: 2,
            workspace_conflict_count: 1
          })

        {commands, regions} = Modeline.render(0, 140, data)
        text = Enum.map_join(commands, fn {_row, _col, segment, _opts} -> segment end)

        assert String.contains?(text, "W:Agent: tests")
        assert String.contains?(text, "D2")
        assert String.contains?(text, "C1")
        assert Enum.any?(regions, fn {_start, _end, cmd} -> cmd == :workspace_list end)
      end)
    end

    test "filetype segment includes devicon for known filetype" do
      {commands, _regions} = Modeline.render(0, 120, @base_data)

      texts = Enum.map(commands, fn {_row, _col, text, _opts} -> text end)
      combined = Enum.join(texts)

      # Elixir devicon should appear somewhere in the modeline
      {icon, _color} = Minga.Language.Devicon.icon_and_color(:elixir)
      assert String.contains?(combined, icon)
    end

    test "filetype segment is clickable with filetype_menu target" do
      {_commands, regions} = Modeline.render(0, 120, @base_data)
      assert Enum.any?(regions, fn {_start, _end, cmd} -> cmd == :filetype_menu end)
    end

    test "agent plan mode indicator shows explicit PLAN text" do
      theme = MingaEditor.UI.Theme.get!(:doom_one)
      agent_colors = MingaEditor.UI.Theme.agent_theme(theme)
      data = Map.merge(@base_data, %{agent_status: :plan, agent_theme_colors: agent_colors})
      {commands, _regions} = Modeline.render(0, 120, data, theme)

      combined = Enum.map_join(commands, fn {_row, _col, text, _opts} -> text end)
      assert String.contains?(combined, "NORMAL")
      assert String.contains?(combined, "PLAN")
    end

    test "LSP indicator reflects status and click target" do
      for {status, marker} <- [ready: "●", initializing: "⟳", starting: "◯", error: "✗"] do
        data = Map.put(@base_data, :lsp_status, status)
        {commands, regions} = Modeline.render(0, 120, data)
        text = combined_text(commands)

        assert String.contains?(text, marker)
        assert has_region?(regions, :lsp_info)
      end
    end

    test "LSP indicator is omitted when status is absent or none" do
      for data <- [@base_data, Map.put(@base_data, :lsp_status, :none)] do
        {commands, _regions} = Modeline.render(0, 120, data)
        text = combined_text(commands)

        refute String.contains?(text, "●")
        refute String.contains?(text, "⟳")
        refute String.contains?(text, "✗")
      end
    end
  end

  describe "git branch and diff summary" do
    test "renders branch and diff variants" do
      cases = [
        {%{git_branch: "main"}, ["main", "\uE0A0"], []},
        {%{git_branch: "feat/x", git_diff_summary: {3, 2, 1}}, ["+3", "~2", "-1"], []},
        {%{git_branch: "main", git_diff_summary: {5, 0, 0}}, ["+5"], ["~0", "-0"]},
        {%{git_branch: "main", git_diff_summary: {0, 0, 0}}, ["main"], ["+", "~"]},
        {%{}, [], ["\uE0A0"]},
        {%{git_branch: ""}, [], ["\uE0A0"]}
      ]

      for {overrides, includes, excludes} <- cases do
        data = Map.merge(@base_data, overrides)
        {commands, _regions} = Modeline.render(0, 120, data)
        text = combined_text(commands)

        for expected <- includes, do: assert(String.contains?(text, expected))
        for unexpected <- excludes, do: refute(String.contains?(text, unexpected))
      end
    end
  end

  describe "configurable segments" do
    test "omitting a segment hides it" do
      with_options(fn options ->
        Options.set(options, :modeline_left_segments, [:mode, :filename])
        data = Map.put(@base_data, :git_branch, "main")

        {commands, _regions} = Modeline.render(0, 120, data)
        text = combined_text(commands)

        refute String.contains?(text, "main")
        refute String.contains?(text, "\uE0A0")
      end)
    end

    test "segment order controls render order" do
      with_options(fn options ->
        Options.set(options, :modeline_left_segments, [:filename, :mode])
        Options.set(options, :modeline_right_segments, [])

        {commands, _regions} = Modeline.render(0, 120, @base_data)

        assert text_col(commands, "test.ex") < text_col(commands, "NORMAL")
      end)
    end

    test "custom segment renders from registry on declared side" do
      segment_name = :word_count_modeline_test
      ModelineSegments.unregister(segment_name)

      try do
        ModelineSegments.register(segment_name, [side: :right, priority: 50], fn ctx ->
          {" #{ctx.data.filetype}W ", ctx.info_fg, ctx.bar_bg, [], nil}
        end)

        {commands, _regions} = Modeline.render(0, 120, @base_data)
        text = combined_text(commands)

        assert String.contains?(text, "elixirW")
      after
        ModelineSegments.unregister(segment_name)
      end
    end

    test "responsive truncation drops lower-priority segments first" do
      with_options(fn options ->
        Options.set(options, :modeline_left_segments, [:mode, :filename, :git])
        Options.set(options, :modeline_right_segments, [])

        data =
          Map.merge(@base_data, %{
            file_name: "very_long_file_name.ex",
            git_branch: "very-long-branch-name"
          })

        {commands, _regions} = Modeline.render(0, 24, data)
        text = combined_text(commands)

        assert String.contains?(text, "NORMAL")
        refute String.contains?(text, "very-long-branch-name")
      end)
    end

    test "separator styles render configured characters" do
      with_options(fn options ->
        Options.set(options, :modeline_left_segments, [:mode, :filename])
        Options.set(options, :modeline_right_segments, [])
        Options.set(options, :modeline_separator, :round)
        {round_commands, _regions} = Modeline.render(0, 120, @base_data)

        Options.set(options, :modeline_separator, :slant)
        {slant_commands, _regions} = Modeline.render(0, 120, @base_data)

        Options.set(options, :modeline_separator, :none)
        {none_commands, _regions} = Modeline.render(0, 120, @base_data)

        assert String.contains?(combined_text(round_commands), "")
        assert String.contains?(combined_text(slant_commands), "")
        refute String.contains?(combined_text(none_commands), "")
        refute String.contains?(combined_text(none_commands), "")
      end)
    end

    test "unknown segment names are ignored" do
      with_options(fn options ->
        Options.set(options, :modeline_left_segments, [:mode, :missing_segment, :filename])
        Options.set(options, :modeline_right_segments, [])

        {commands, _regions} = Modeline.render(0, 120, @base_data)
        text = combined_text(commands)

        assert String.contains?(text, "NORMAL")
        assert String.contains?(text, "test.ex")
      end)
    end

    test "gui_segments exposes configured custom segment default side" do
      segment_name = :gui_default_side_modeline_test
      ModelineSegments.unregister(segment_name)

      try do
        assert :ok =
                 ModelineSegments.register(segment_name, [side: :left, priority: 50], fn ctx ->
                   {" LEFTY ", ctx.info_fg, ctx.bar_bg, [], nil}
                 end)

        segments = Modeline.gui_segments(@base_data)

        assert Enum.any?(segments.left, fn {name, text, _fg, _bg, _opts, _target} ->
                 name == segment_name and text == " LEFTY "
               end)

        refute Enum.any?(segments.right, fn {_name, text, _fg, _bg, _opts, _target} ->
                 text == " LEFTY "
               end)
      after
        ModelineSegments.unregister(segment_name)
      end
    end

    test "explicit configured side overrides custom default side without duplication" do
      segment_name = :gui_override_side_modeline_test
      ModelineSegments.unregister(segment_name)

      try do
        assert :ok =
                 ModelineSegments.register(segment_name, [side: :left, priority: 50], fn ctx ->
                   {" MOVED ", ctx.info_fg, ctx.bar_bg, [], nil}
                 end)

        with_options(fn options ->
          Options.set(options, :modeline_left_segments, [])
          Options.set(options, :modeline_right_segments, [segment_name])

          segments = Modeline.gui_segments(@base_data)
          left_text = segment_text(segments.left)
          right_text = segment_text(segments.right)

          refute String.contains?(left_text, "MOVED")
          assert String.contains?(right_text, "MOVED")
          assert right_text |> String.split("MOVED") |> length() == 2
        end)
      after
        ModelineSegments.unregister(segment_name)
      end
    end

    test "registry rejects duplicate segment names from different sources" do
      table = :"modeline_collision_#{System.unique_integer([:positive])}"
      start_supervised!({ModelineSegments, name: table})

      assert :ok =
               ModelineSegments.register(
                 table,
                 :dup_segment,
                 [side: :right],
                 fn _ctx -> nil end,
                 :config
               )

      assert {:error, {:duplicate_name, :dup_segment, :config, {:extension, :demo}}} =
               ModelineSegments.register(
                 table,
                 :dup_segment,
                 [side: :left],
                 fn _ctx -> nil end,
                 {:extension, :demo}
               )

      assert %{source: :config, side: :right} = ModelineSegments.lookup(table, :dup_segment)
    end

    test "unregister_source only removes segments owned by that source" do
      table = :"modeline_source_#{System.unique_integer([:positive])}"
      start_supervised!({ModelineSegments, name: table})

      assert :ok =
               ModelineSegments.register(
                 table,
                 :config_segment,
                 [side: :right],
                 fn _ctx -> nil end,
                 :config
               )

      assert :ok =
               ModelineSegments.register(
                 table,
                 :extension_segment,
                 [side: :left],
                 fn _ctx -> nil end,
                 {:extension, :demo}
               )

      assert :ok = ModelineSegments.unregister_source(table, {:extension, :demo})

      assert %{source: :config} = ModelineSegments.lookup(table, :config_segment)
      assert ModelineSegments.lookup(table, :extension_segment) == nil
    end

    test "registry rejects invalid side and priority declarations" do
      table = :"modeline_invalid_#{System.unique_integer([:positive])}"
      start_supervised!({ModelineSegments, name: table})

      assert {:error, {:invalid_side, :middle}} =
               ModelineSegments.register(
                 table,
                 :bad_side,
                 [side: :middle],
                 fn _ctx -> nil end,
                 :config
               )

      assert {:error, {:invalid_priority, "high"}} =
               ModelineSegments.register(
                 table,
                 :bad_priority,
                 [priority: "high"],
                 fn _ctx -> nil end,
                 :config
               )
    end

    test "registry rejects names reserved by built-in segments" do
      table = :"modeline_reserved_#{System.unique_integer([:positive])}"
      start_supervised!({ModelineSegments, name: table})

      assert {:error, {:reserved_name, :mode}} =
               ModelineSegments.register(
                 table,
                 :mode,
                 [side: :left],
                 fn _ctx -> {" hacked ", 0xFFFFFF, 0x000000, [], nil} end,
                 :config
               )

      assert ModelineSegments.lookup(table, :mode) == nil
    end

    test "custom segments with invalid colors are dropped" do
      segment_name = :invalid_color_modeline_test
      ModelineSegments.unregister(segment_name)

      try do
        assert :ok =
                 ModelineSegments.register(segment_name, [side: :left], fn _ctx ->
                   {" BAD_COLOR ", 0x1_000000, -1, [], nil}
                 end)

        segments = Modeline.gui_segments(@base_data)

        refute String.contains?(segment_text(segments.left), "BAD_COLOR")
        refute String.contains?(segment_text(segments.right), "BAD_COLOR")
      after
        ModelineSegments.unregister(segment_name)
      end
    end

    test "custom segments with invalid UTF-8 text are dropped" do
      segment_name = :invalid_utf8_modeline_test
      ModelineSegments.unregister(segment_name)

      try do
        assert :ok =
                 ModelineSegments.register(segment_name, [side: :left], fn ctx ->
                   {<<" BAD_UTF8 ", 0xFF>>, ctx.info_fg, ctx.bar_bg, [], nil}
                 end)

        assert %{left: left, right: right} = Modeline.gui_segments(@base_data)
        refute String.contains?(segment_text(left), "BAD_UTF8")
        refute String.contains?(segment_text(right), "BAD_UTF8")

        {commands, _regions} = Modeline.render(0, 120, @base_data)
        refute String.contains?(combined_text(commands), "BAD_UTF8")
      after
        ModelineSegments.unregister(segment_name)
      end
    end

    test "custom segments with malformed opts are dropped" do
      segment_name = :invalid_opts_modeline_test
      ModelineSegments.unregister(segment_name)

      try do
        assert :ok =
                 ModelineSegments.register(segment_name, [side: :left], fn ctx ->
                   {" BAD_OPTS ", ctx.info_fg, ctx.bar_bg, [bold: :yes], nil}
                 end)

        assert %{left: left, right: right} = Modeline.gui_segments(@base_data)
        refute String.contains?(segment_text(left), "BAD_OPTS")
        refute String.contains?(segment_text(right), "BAD_OPTS")

        {commands, _regions} = Modeline.render(0, 120, @base_data)
        refute String.contains?(combined_text(commands), "BAD_OPTS")
      after
        ModelineSegments.unregister(segment_name)
      end
    end

    test "invalid custom segment warnings use stable keys for changing output" do
      segment_name = :dynamic_invalid_output_modeline_test
      counter = :counters.new(1, [])
      warnings_table = Minga.Config.ModelineSegments.Warnings
      ModelineSegments.unregister(segment_name)
      ModelineSegments.reset_warnings()

      try do
        assert :ok =
                 ModelineSegments.register(segment_name, [side: :left], fn _ctx ->
                   :counters.add(counter, 1, 1)
                   {:bad_output, :counters.get(counter, 1)}
                 end)

        Modeline.render(0, 120, @base_data)
        Modeline.render(0, 120, @base_data)

        warning_keys =
          warnings_table
          |> :ets.tab2list()
          |> Enum.map(fn {key, true} -> key end)

        assert Enum.count(warning_keys, &(&1 == {:invalid_segment_output, segment_name})) == 1
        refute Enum.any?(warning_keys, &match?({:invalid_segment_output, ^segment_name, _}, &1))
      after
        ModelineSegments.unregister(segment_name)
        ModelineSegments.reset_warnings()
      end
    end

    test "custom segment exceptions are dropped without raising" do
      segment_name = :raising_modeline_test
      ModelineSegments.unregister(segment_name)

      try do
        assert :ok =
                 ModelineSegments.register(segment_name, [side: :left], fn _ctx ->
                   raise "boom"
                 end)

        assert %{left: left, right: right} = Modeline.gui_segments(@base_data)
        refute String.contains?(segment_text(left), "boom")
        refute String.contains?(segment_text(right), "boom")
      after
        ModelineSegments.unregister(segment_name)
      end
    end
  end

  describe "cursor_shape/1" do
    test "maps modes to cursor shapes" do
      cases = %{
        insert: :beam,
        replace: :underline,
        normal: :block,
        visual: :block,
        command: :beam,
        eval: :beam,
        search_prompt: :beam,
        operator_pending: :block
      }

      for {mode, shape} <- cases do
        assert Modeline.cursor_shape(mode) == shape
      end
    end
  end

  defp with_options(fun) when is_function(fun, 1) do
    options = start_supervised!({Options, name: nil})
    previous = Process.get(:minga_config_options)
    Process.put(:minga_config_options, options)

    try do
      fun.(options)
    after
      restore_options_server(previous)
    end
  end

  defp restore_options_server(nil), do: Process.delete(:minga_config_options)
  defp restore_options_server(previous), do: Process.put(:minga_config_options, previous)

  defp combined_text(commands) do
    Enum.map_join(commands, fn {_row, _col, segment, _opts} -> segment end)
  end

  defp text_col(commands, needle) do
    commands
    |> Enum.find_value(fn {_row, col, segment, _opts} ->
      if String.contains?(segment, needle), do: col
    end)
  end

  defp segment_text(segments) do
    Enum.map_join(segments, fn {_name, text, _fg, _bg, _opts, _target} -> text end)
  end

  defp has_region?(regions, target) do
    Enum.any?(regions, fn {_start, _end, command} -> command == target end)
  end

  describe "parser status indicator" do
    test "reflects parser status and restart click target" do
      data = Map.put(@base_data, :parser_status, :available)
      {commands, _regions} = Modeline.render(0, 120, data)
      refute String.contains?(combined_text(commands), "🌳")

      for {status, marker} <- [unavailable: "🌳✗", restarting: "🌳⟳"] do
        data = Map.put(@base_data, :parser_status, status)
        {commands, regions} = Modeline.render(0, 120, data)

        assert String.contains?(combined_text(commands), marker)
        assert has_region?(regions, :parser_restart)
      end
    end
  end

  describe "diagnostic counts" do
    test "shows counts and diagnostic picker target" do
      cases = [
        {{3, 0, 0, 0}, ["3"]},
        {{0, 5, 0, 0}, ["5"]},
        {{2, 3, 0, 0}, ["2", "3"]}
      ]

      for {counts, expected_counts} <- cases do
        data = Map.put(@base_data, :diagnostic_counts, counts)
        {commands, regions} = Modeline.render(0, 120, data)
        text = combined_text(commands)

        for expected <- expected_counts, do: assert(String.contains?(text, expected))
        assert has_region?(regions, :diagnostic_picker)
      end
    end

    test "shows nothing when no diagnostics" do
      data = Map.put(@base_data, :diagnostic_counts, nil)
      {commands_with, _} = Modeline.render(0, 120, data)
      {commands_without, _} = Modeline.render(0, 120, @base_data)

      assert length(commands_with) == length(commands_without)
    end
  end

  describe "indent and selection segments" do
    test "shows indentation and exposes indent picker click target" do
      for {type, size, label} <- [{:spaces, 2, "Spaces:2"}, {:tabs, 4, "Tabs:4"}] do
        data = Map.merge(@base_data, %{indent_type: type, indent_size: size})
        {commands, regions} = Modeline.render(0, 120, data)
        text = combined_text(commands)

        assert String.contains?(text, label)
        assert has_region?(regions, :indent_picker)
      end
    end

    test "selection info replaces cursor position" do
      data = Map.merge(@base_data, %{selection_info: {:chars, 42}})
      {commands, _regions} = Modeline.render(0, 120, data)
      text = Enum.map_join(commands, fn {_r, _c, segment, _s} -> segment end)

      assert String.contains?(text, "42 chars")
      refute String.contains?(text, "1:1")
    end

    test "narrow layout drops indent before diagnostics and git" do
      data =
        Map.merge(@base_data, %{
          git_branch: "feature-branch",
          git_diff_summary: {12, 3, 4},
          diagnostic_counts: {2, 1, 0, 0},
          indent_type: :spaces,
          indent_size: 2
        })

      {commands, _regions} = Modeline.render(0, 55, data)
      text = Enum.map_join(commands, fn {_r, _c, segment, _s} -> segment end)

      refute String.contains?(text, "Spaces:2")
      assert String.contains?(text, "NORMAL")
      assert String.contains?(text, "test.ex")
    end
  end
end
