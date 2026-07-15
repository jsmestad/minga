defmodule MingaEditor.Shell.Traditional.ModelineTest do
  use ExUnit.Case, async: true

  alias Minga.Config.ModelineSegments
  alias Minga.Config.Options
  alias Minga.Mode
  alias MingaEditor.Shell.Traditional.Modeline

  # The cell-grid `Modeline.render/5` painter was removed in #2311; the live
  # surface is `gui_segments/2,3`, which the GUI status-bar adapter (0x76)
  # consumes. These tests assert on the semantic segment text and click targets
  # the modeline produces, not on cell-grid draw geometry.

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

  describe "segments" do
    test "renders for all modes without crashing" do
      for mode <- [:normal, :insert, :visual, :operator_pending, :command, :replace] do
        data = Map.put(@base_data, :mode, mode)
        assert segments_text(data) != "", "Expected segments for mode #{mode}"
      end
    end

    test "operator_pending mode shows NORMAL badge, not OPERATOR" do
      text = segments_text(Map.put(@base_data, :mode, :operator_pending))

      assert String.contains?(text, "NORMAL"),
             "Expected NORMAL badge in operator_pending mode, got: #{inspect(text)}"

      refute String.contains?(text, "OPERATOR"),
             "Should not show OPERATOR badge in operator_pending mode"
    end

    test "safe mode prepends a visible mode badge" do
      text = segments_text(Map.put(@base_data, :safe_mode, true))
      assert String.contains?(text, "[SAFE] NORMAL")
    end

    test "renders common file state variants" do
      for data <- [
            Map.put(@base_data, :dirty_marker, " ● "),
            Map.merge(@base_data, %{buf_index: 2, buf_count: 3}),
            Map.merge(@base_data, %{buf_index: 1, buf_count: 1}),
            Map.merge(@base_data, %{cursor_line: 0, line_count: 1})
          ] do
        assert segments_text(data) != ""
      end
    end

    test "file segment is clickable with buffer_list target" do
      assert :buffer_list in segment_targets(@base_data)
    end

    test "shows running background subagent count and active label" do
      data =
        Map.merge(@base_data, %{
          background_subagent_count: 2,
          active_background_subagent_label: "session-3: tests"
        })

      assert String.contains?(segments_text(data), "bg:2")
      assert String.contains?(segments_text(data), "session-3: tests")
      assert :agent_session_switcher in segment_targets(data)
      refute :agent_session_picker in segment_targets(data)
    end

    test "omits background subagent segment when none are running" do
      data =
        Map.merge(@base_data, %{
          background_subagent_count: 0,
          active_background_subagent_label: "unique-bg-label"
        })

      refute String.contains?(segments_text(data), "unique-bg-label")
    end

    test "renders active file merge conflict count when configured" do
      with_options(fn options ->
        Options.set(options, :modeline_right_segments, [:merge_conflict])

        data = Map.put(@base_data, :merge_conflict_count, 2)

        assert String.contains?(segments_text(data), "X2")
        assert :next_merge_conflict in segment_targets(data)
      end)
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

        text = segments_text(data)
        assert String.contains?(text, "W:Agent: tests")
        assert String.contains?(text, "D2")
        assert String.contains?(text, "C1")
        assert :workspace_list in segment_targets(data)
      end)
    end

    test "filetype segment includes devicon for known filetype" do
      {icon, _color} = Minga.Language.Devicon.icon_and_color(:elixir)
      assert String.contains?(segments_text(@base_data), icon)
    end

    test "filetype segment is clickable with filetype_menu target" do
      assert :filetype_menu in segment_targets(@base_data)
    end

    test "agent status command replaces built-in agent label" do
      theme = MingaEditor.UI.Theme.get!(:doom_one)
      agent_colors = MingaEditor.UI.Theme.agent_theme(theme)

      data =
        Map.merge(@base_data, %{
          agent_status: :thinking,
          agent_status_command: "sonnet | thinking",
          agent_theme_colors: agent_colors
        })

      text = segments_text(data, theme)

      assert String.contains?(text, "sonnet | thinking")
      refute String.contains?(text, "Thinking")
    end

    test "agent status indicators show text labels" do
      theme = MingaEditor.UI.Theme.get!(:doom_one)
      agent_colors = MingaEditor.UI.Theme.agent_theme(theme)

      cases = [
        {%{agent_status: :idle}, "Idle", []},
        {%{agent_status: :plan}, "PLAN", []},
        {%{agent_status: :thinking}, "Thinking", []},
        {%{agent_status: :tool_executing, active_tool_name: "read_file"}, "Running read_file",
         []},
        {%{agent_status: :tool_executing}, "Running", ["Running read_file"]},
        {%{agent_status: :error}, "Error", []}
      ]

      for {overrides, expected, unexpected} <- cases do
        data = Map.merge(@base_data, Map.put(overrides, :agent_theme_colors, agent_colors))
        combined = segments_text(data, theme)

        assert String.contains?(combined, "NORMAL")
        assert String.contains?(combined, expected)

        for absent <- unexpected do
          refute String.contains?(combined, absent)
        end
      end
    end

    test "LSP indicator reflects status and click target" do
      for {status, marker} <- [ready: "●", initializing: "⟳", starting: "◯", error: "✗"] do
        data = Map.put(@base_data, :lsp_status, status)

        assert String.contains?(segments_text(data), marker)
        assert :lsp_info in segment_targets(data)
      end
    end

    test "LSP indicator is omitted when status is absent or none" do
      for data <- [@base_data, Map.put(@base_data, :lsp_status, :none)] do
        text = segments_text(data)

        refute String.contains?(text, "●")
        refute String.contains?(text, "⟳")
        refute String.contains?(text, "✗")
      end
    end
  end

  describe "git branch and diff summary" do
    test "renders branch and diff variants" do
      cases = [
        {%{git_branch: "main"}, ["main", ""], []},
        {%{git_branch: "feat/x", git_diff_summary: {3, 2, 1}}, ["+3", "~2", "-1"], []},
        {%{git_branch: "main", git_diff_summary: {5, 0, 0}}, ["+5"], ["~0", "-0"]},
        {%{git_branch: "main", git_diff_summary: {0, 0, 0}}, ["main"], ["+", "~"]},
        {%{}, [], [""]},
        {%{git_branch: ""}, [], [""]}
      ]

      for {overrides, includes, excludes} <- cases do
        data = Map.merge(@base_data, overrides)
        text = segments_text(data)

        for expected <- includes, do: assert(String.contains?(text, expected))
        for unexpected <- excludes, do: refute(String.contains?(text, unexpected))
      end
    end

    test "renders a degraded warning indicator when git status is degraded" do
      degraded_icon = "\u{F071}"

      degraded = segments_text(Map.merge(@base_data, %{git_branch: "main", git_degraded: true}))
      assert String.contains?(degraded, degraded_icon)

      healthy = segments_text(Map.merge(@base_data, %{git_branch: "main", git_degraded: false}))
      refute String.contains?(healthy, degraded_icon)
    end
  end

  describe "configurable segments" do
    test "omitting a segment hides it" do
      with_options(fn options ->
        Options.set(options, :modeline_left_segments, [:mode, :filename])
        data = Map.put(@base_data, :git_branch, "main")

        text = segments_text(data)
        refute String.contains?(text, "main")
        refute String.contains?(text, "")
      end)
    end

    test "segment order controls left/right ordering" do
      with_options(fn options ->
        Options.set(options, :modeline_left_segments, [:filename, :mode])
        Options.set(options, :modeline_right_segments, [])

        text = segments_text(@base_data)
        assert text_index(text, "test.ex") < text_index(text, "NORMAL")
      end)
    end

    test "custom segment renders from registry on declared side" do
      segment_name = :word_count_modeline_test
      ModelineSegments.unregister(segment_name)

      try do
        ModelineSegments.register(segment_name, [side: :right, priority: 50], fn ctx ->
          {" #{ctx.data.filetype}W ", ctx.info_fg, ctx.bar_bg, [], nil}
        end)

        assert String.contains?(segments_text(@base_data), "elixirW")
      after
        ModelineSegments.unregister(segment_name)
      end
    end

    test "unknown segment names are ignored" do
      with_options(fn options ->
        Options.set(options, :modeline_left_segments, [:mode, :missing_segment, :filename])
        Options.set(options, :modeline_right_segments, [])

        text = segments_text(@base_data)
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
          assert right_text |> String.split("MOVED") |> Enum.count() == 2
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

        Modeline.gui_segments(@base_data)
        Modeline.gui_segments(@base_data)

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

    test "extension callback failures are observable fallbacks" do
      segment_name = :failed_extension_modeline_test
      source = {:extension, :failed_modeline}
      failure = {:callback_failed, source, __MODULE__, :render, :throw, :failed}
      ModelineSegments.unregister(segment_name)

      try do
        assert :ok =
                 ModelineSegments.register(
                   segment_name,
                   [side: :left],
                   fn _ctx ->
                     {:extension_callback, source, __MODULE__, :render, {:error, failure}}
                   end,
                   source
                 )

        segments = Modeline.gui_segments(@base_data)
        refute String.contains?(segment_text(segments.left ++ segments.right), "failed")
      after
        ModelineSegments.unregister(segment_name)
      end
    end

    test "core custom segment raise, throw, and exit failures propagate" do
      failures = [
        {:raise, fn -> raise "boom" end},
        {:throw, fn -> throw(:boom) end},
        {:exit, fn -> exit(:boom) end}
      ]

      Enum.each(failures, fn {kind, callback} ->
        segment_name = String.to_atom("#{kind}_modeline_test")
        ModelineSegments.unregister(segment_name)

        try do
          assert :ok =
                   ModelineSegments.register(segment_name, [side: :left], fn _ctx ->
                     callback.()
                   end)

          case kind do
            :raise ->
              assert_raise RuntimeError, "boom", fn -> Modeline.gui_segments(@base_data) end

            :throw ->
              assert catch_throw(Modeline.gui_segments(@base_data)) == :boom

            :exit ->
              assert catch_exit(Modeline.gui_segments(@base_data)) == :boom
          end
        after
          ModelineSegments.unregister(segment_name)
        end
      end)
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

  describe "parser status indicator" do
    test "reflects parser status and restart click target" do
      data = Map.put(@base_data, :parser_status, :available)
      refute String.contains?(segments_text(data), "🌳")

      for {status, marker} <- [unavailable: "🌳✗", restarting: "🌳⟳"] do
        data = Map.put(@base_data, :parser_status, status)

        assert String.contains?(segments_text(data), marker)
        assert :parser_restart in segment_targets(data)
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
        text = segments_text(data)

        for expected <- expected_counts, do: assert(String.contains?(text, expected))
        assert :diagnostic_picker in segment_targets(data)
      end
    end

    test "shows nothing when no diagnostics" do
      with_diag = segment_targets(Map.put(@base_data, :diagnostic_counts, nil))
      without = segment_targets(@base_data)
      refute :diagnostic_picker in with_diag
      refute :diagnostic_picker in without
    end
  end

  describe "indent and selection segments" do
    test "shows indentation and exposes indent picker click target" do
      for {type, size, label} <- [{:spaces, 2, "Spaces:2"}, {:tabs, 4, "Tabs:4"}] do
        data = Map.merge(@base_data, %{indent_type: type, indent_size: size})

        assert String.contains?(segments_text(data), label)
        assert :indent_picker in segment_targets(data)
      end
    end

    test "selection info replaces cursor position" do
      data = Map.merge(@base_data, %{selection_info: {:chars, 42}})
      text = segments_text(data)

      assert String.contains?(text, "42 chars")
      refute String.contains?(text, "1:1")
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

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

  defp gui_segments(data, nil), do: Modeline.gui_segments(data)
  defp gui_segments(data, theme), do: Modeline.gui_segments(data, theme)

  defp segments_text(data, theme \\ nil) do
    %{left: left, right: right} = gui_segments(data, theme)
    segment_text(left ++ right)
  end

  defp segment_targets(data, theme \\ nil) do
    %{left: left, right: right} = gui_segments(data, theme)

    (left ++ right)
    |> Enum.map(fn {_name, _text, _fg, _bg, _opts, target} -> target end)
    |> Enum.reject(&is_nil/1)
  end

  defp segment_text(segments) do
    Enum.map_join(segments, fn {_name, text, _fg, _bg, _opts, _target} -> text end)
  end

  defp text_index(text, needle) do
    case :binary.match(text, needle) do
      {start, _len} -> start
      :nomatch -> nil
    end
  end
end
