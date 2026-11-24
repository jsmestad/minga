defmodule MingaEditor.Shell.Traditional.ModelineTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Minga.Keymap.Sigil

  alias Minga.Config.ModelineSegments
  alias Minga.Config.Options
  alias Minga.Design.Tokens
  alias Minga.Keymap.Bindings
  alias Minga.Mode
  alias Minga.RenderModel.UI.StatusBar.Segment
  alias MingaEditor.Shell.Traditional.Modeline
  alias MingaEditor.StatusBar.PlanLimit
  alias MingaEditor.UI.Theme

  # `gui_segments/2,3` is the live surface: the semantic status bar (0x76) carries its segments to both frontends.
  # These tests assert on segment ids, words, drop ranks, states and click targets.

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

  # A modeline with everything to say: the board's "editing while Minga works" frame.
  @full_data Map.merge(@base_data, %{
               file_name: "retry.ex",
               dirty_marker: " ● ",
               cursor_line: 239,
               cursor_col: 30,
               needs_you_count: 1,
               change_position: {1, 2},
               git_branch: "main",
               git_diff_summary: {5, 3, 3},
               agent_status: :thinking,
               minga_progress: {2, 3},
               diagnostic_counts: {1, 2, 0, 0}
             })

  @theme Theme.get!(Theme.default())

  describe "order" do
    test "segments follow the design: mode, needs-you, file, change, git, Minga, diagnostics, filetype, position" do
      %{left: left, right: right} = Modeline.gui_segments(@full_data, @theme)

      assert Enum.map(left, & &1.id) ==
               [:mode, :needs_you, :filename, :change, :git, :minga, :errors, :warnings]

      assert Enum.map(right, & &1.id) == [:filetype, :position]
    end

    test "a resting file shows only mode, file, filetype and position" do
      assert ids(@base_data) == [:mode, :filename, :filetype, :position]
    end

    test "segments carry words without padding; the frontends own the gaps" do
      assert segment_text(segments(@full_data)) ==
               "NORMAL Needs you retry.ex ● change 1/2 main +11 Minga working 2/3 1 2 Elixir 240:31"
    end

    test "the zero-buffers launchpad shows no file segment" do
      refute :filename in ids(%{@base_data | file_name: ""})
    end
  end

  describe "truncation ranks" do
    test "filetype, position and git drop in that order, then Minga shrinks, then warnings" do
      ranks = Map.new(segments(@full_data), &{&1.id, &1.drop})

      assert ranks.filetype > 0
      assert ranks.filetype < ranks.position
      assert ranks.position < ranks.git
      assert ranks.git < ranks.minga
      assert ranks.minga < ranks.warnings
    end

    test "mode, needs-you, the file name, change position, errors and problems never drop" do
      data = Map.merge(@full_data, %{lsp_status: :error, parser_status: :unavailable})
      never = for s <- segments(data), s.drop == 0, do: s.id

      assert never == [:mode, :needs_you, :filename, :change, :errors, :problem, :problem]
    end

    test "Minga's words shrink to its state mark and step count instead of dropping" do
      assert segment(@full_data, :minga).compact == "2/3"
      assert segment(Map.delete(@full_data, :minga_progress), :minga).compact == ""
    end

    test "optional and custom segments give way first" do
      data = Map.merge(@full_data, %{background_subagent_count: 2, merge_conflict_count: 1})
      ranks = Map.new(segments(data), &{&1.id, &1.drop})

      assert ranks.background_agent < ranks.filetype
      assert ranks.merge_conflict < ranks.filetype
    end
  end

  describe "mode" do
    test "names every mode, operator-pending as NORMAL" do
      for {mode, badge} <- [
            normal: "NORMAL",
            insert: "INSERT",
            visual: "VISUAL",
            operator_pending: "NORMAL",
            command: "COMMAND",
            replace: "REPLACE"
          ] do
        assert segment(%{@base_data | mode: mode}, :mode).text == badge
      end
    end

    test "the eval prompt names itself in the mode pill (#4092)" do
      data = %{@base_data | mode: :eval, mode_state: %Minga.Mode.EvalState{}}
      assert segment(data, :mode).text == "EVAL"
    end

    test "safe mode prepends a visible mode badge and the label reads as words" do
      assert segment(Map.put(@base_data, :safe_mode, true), :mode).text == "[SAFE] NORMAL"
      assert segment(@base_data, :mode).label == "Normal mode"
    end
  end

  describe "Minga's state" do
    test "every Agent status speaks as its token state, in the state's colour role" do
      for status <- Tokens.agent_statuses() do
        data = Map.put(@base_data, :agent_status, status)

        case Tokens.agent_status_state(status) do
          nil ->
            refute :minga in ids(data)

          state ->
            minga = segment(data, :minga)
            assert minga.state == state
            assert minga.text == "Minga " <> String.downcase(Tokens.state_word(state))
            assert minga.fg == Theme.state_color(@theme, state)
            assert minga.label == Tokens.state(state).accessibility_label
        end
      end
    end

    test "the step through Minga's plan follows the words and the label" do
      minga = segment(@full_data, :minga)
      assert minga.text == "Minga working 2/3"
      assert minga.label == "Minga is working, step 2 of 3"
    end

    test "the user's status command text follows the state, or stands alone without one" do
      data = Map.merge(@base_data, %{agent_status: :thinking, agent_status_command: " 42 tok "})
      assert segment(data, :minga).text == "Minga working 42 tok"

      alone = Map.merge(@base_data, %{agent_status: :idle, agent_status_command: "42 tok"})
      assert %Segment{text: "42 tok", state: nil, compact: nil} = segment(alone, :minga)
    end

    test "configs that still list :agent get the Minga segment" do
      with_options(fn options ->
        Options.set(options, :modeline_left_segments, [:mode, :agent])
        Options.set(options, :modeline_right_segments, [])
        assert ids(Map.put(@base_data, :agent_status, :error)) == [:mode, :minga]
      end)
    end
  end

  describe "needs-you" do
    test "shows only when non-zero, once, in the needs-you role" do
      refute :needs_you in ids(@base_data)

      one = segment(@full_data, :needs_you)
      assert %Segment{text: "Needs you", state: :needs_you, label: "1 task needs you"} = one
      assert one.fg == Theme.state_color(@theme, :needs_you)

      two = segment(%{@full_data | needs_you_count: 2}, :needs_you)
      assert %Segment{text: "Needs you 2", label: "2 tasks need you"} = two
    end
  end

  describe "file, change, git, diagnostics, filetype and position" do
    test "the file name carries a dot while unsaved" do
      assert segment(@full_data, :filename).text == "retry.ex ●"
      assert segment(@full_data, :filename).label == "retry.ex, unsaved"
      assert segment(@base_data, :filename).text == "test.ex"
    end

    test "change position reads change n/m in the minga role" do
      change = segment(@full_data, :change)
      assert change.text == "change 1/2"
      assert change.fg == Theme.role_color(@theme, :minga)
      refute :change in ids(@base_data)
    end

    test "git reads branch and changed-line count, and says when status is partial" do
      assert segment(@full_data, :git).text == "main +11"
      assert segment(%{@full_data | git_diff_summary: {0, 0, 0}}, :git).text == "main"

      degraded = segment(Map.put(@full_data, :git_degraded, true), :git)
      assert degraded.text == "main +11 (partial)"
      assert degraded.label =~ "status incomplete"
      refute :git in ids(Map.put(@base_data, :git_branch, ""))
    end

    test "errors and warnings are separate counts in the failure and warning roles" do
      errors = segment(@full_data, :errors)
      warnings = segment(@full_data, :warnings)

      assert {errors.text, errors.label, errors.fg} ==
               {"1", "1 error", Theme.role_color(@theme, :failure)}

      assert {warnings.text, warnings.label, warnings.fg} ==
               {"2", "2 warnings", Theme.role_color(@theme, :warning)}

      refute :errors in ids(Map.put(@base_data, :diagnostic_counts, {0, 0, 3, 1}))
      refute :errors in ids(Map.put(@base_data, :diagnostic_counts, nil))
    end

    test "a failed language server or parser is a persistent problem in the failure role" do
      lsp = Map.merge(@base_data, %{lsp_status: :error, failed_language_servers: ["elixir_ls"]})

      assert %Segment{id: :problem, text: "elixir_ls failed", target: :lsp_info} =
               segment(lsp, :problem)

      assert segment(Map.put(@base_data, :lsp_status, :error), :problem).text ==
               "Language server failed"

      parser = Map.put(@base_data, :parser_status, :unavailable)
      assert %Segment{text: "Parser failed", target: :parser_restart} = segment(parser, :problem)

      for status <- [:ready, :initializing, :starting, :none] do
        refute :problem in ids(Map.put(@base_data, :lsp_status, status))
      end

      restarting = segment(Map.put(@base_data, :parser_status, :restarting), :parser)
      assert restarting.text == "Parser restarting"
      assert restarting.drop > 0
    end

    test "filetype reads its language name without an icon" do
      assert segment(@base_data, :filetype).text == "Elixir"
      assert segment(@base_data, :filetype).target == :filetype_menu
    end

    test "position is always line:col, in Visual mode too" do
      data = Map.merge(@full_data, %{mode: :visual, selection_info: {:chars, 42}})
      assert segment(data, :position).text == "240:31"
      assert segment(data, :position).label == "Line 240, column 31"
    end
  end

  describe "clicks and keys" do
    test "designed segments do what their leader key does and name that key" do
      expected = [
        needs_you: {"SPC a a", :toggle_agentic_view},
        filename: {"SPC ,", :buffer_list},
        minga: {"SPC a v", :toggle_agent_split},
        errors: {"SPC c x", :diagnostics_list},
        warnings: {"SPC c x", :diagnostics_list}
      ]

      for {id, {key, target}} <- expected do
        assert {segment(@full_data, id).key, segment(@full_data, id).target} == {key, target},
               "#{id} should run #{target} and name #{key}"
      end
    end

    test "a rebinding moves the click and the hint together" do
      trie =
        Bindings.new()
        |> Bindings.bind(~k(g g), :git_status_test_command, "Git status")
        |> Bindings.bind(~k(o b), :buffer_list, "Switch buffer")

      data = Map.put(@full_data, :leader_trie, trie)

      assert {segment(data, :git).key, segment(data, :git).target} ==
               {"SPC g g", :git_status_test_command}

      # SPC , is unbound in this trie: no click and no key for the file segment.
      assert {segment(data, :filename).key, segment(data, :filename).target} == {"", nil}
    end

    test "with no reachable leader the click stays and the hint goes" do
      data = Map.put(@full_data, :key_hints?, false)
      assert segment(data, :needs_you).target == :toggle_agentic_view
      assert segment(data, :needs_you).key == ""
    end

    test "every clickable segment says what it means" do
      for segment <- segments(@full_data), segment.target != nil do
        assert segment.label != "", "#{segment.id} has a click but no label"
      end
    end
  end

  describe "optional segments" do
    test "render only when configured, in their configured order" do
      with_options(fn options ->
        Options.set(options, :modeline_left_segments, [:mode, :indent, :percent, :workspace])
        Options.set(options, :modeline_right_segments, [])

        data =
          Map.merge(@base_data, %{
            indent_type: :tabs,
            indent_size: 4,
            line_count: 1,
            workspace_label: "Review"
          })

        assert segment_text(segments(data)) == "NORMAL Tabs:4 Top W:Review"
        assert segment(data, :indent).target == :indent_picker
      end)

      refute :percent in ids(%{@base_data | cursor_line: 9})
      refute :indent in ids(Map.merge(@base_data, %{indent_type: :spaces, indent_size: 2}))
    end

    test "the scroll position reads as one percent sign" do
      with_options(fn options ->
        Options.set(options, :modeline_left_segments, [:percent])
        Options.set(options, :modeline_right_segments, [])
        assert segment(%{@base_data | cursor_line: 9}, :percent).text == "100%"
      end)
    end

    test "background subagents, plan limits and conflicts show only when present" do
      refute :background_agent in ids(@base_data)

      bg =
        Map.merge(@base_data, %{
          background_subagent_count: 2,
          active_background_subagent_label: "tests"
        })

      assert %Segment{text: "bg:2 tests", target: :agent_session_switcher} =
               segment(bg, :background_agent)

      limit = %PlanLimit{level: :rejected, text: "Plan limit reached"}
      plan = segment(Map.put(@base_data, :plan_limit, limit), :plan_limit)

      assert {plan.text, plan.fg, plan.target} ==
               {"Plan limit reached", Theme.role_color(@theme, :failure), :agent_pick_model}

      assert segment(Map.put(@base_data, :merge_conflict_count, 3), :merge_conflict).text == "X3"
      refute :merge_conflict in ids(@base_data)
    end

    test "the selection segment name renders nothing and indent stays built in" do
      table = start_segment_registry()

      register_segment(table, :indent, [side: :left], fn _ctx ->
        flunk("the custom indent callback should not run")
      end)

      with_options(fn options ->
        Options.set(options, :modeline_left_segments, [:selection, :indent])
        Options.set(options, :modeline_right_segments, [])
        data = Map.merge(@base_data, %{indent_type: :spaces, indent_size: 2})

        {segments, log} = with_log(fn -> registry_segments(table, data) end)

        assert %{
                 left: [%Segment{id: :indent, text: "Spaces:2", target: :indent_picker}],
                 right: []
               } = segments

        refute log =~ "Unknown modeline segment :selection"
      end)
    end
  end

  describe "configurable segments" do
    test "omitting a segment hides it" do
      with_options(fn options ->
        Options.set(options, :modeline_left_segments, [:mode, :filename])
        data = Map.put(@base_data, :git_branch, "main")

        refute :git in ids(data)
      end)
    end

    test "segment order controls left/right ordering" do
      with_options(fn options ->
        Options.set(options, :modeline_left_segments, [:filename, :mode])
        Options.set(options, :modeline_right_segments, [])

        assert ids(@base_data) == [:filename, :mode]
      end)
    end

    test "custom segment renders from registry on declared side" do
      segment_name = :word_count_modeline_test
      ModelineSegments.unregister(segment_name)

      try do
        ModelineSegments.register(segment_name, [side: :right, priority: 50], fn ctx ->
          {" #{ctx.data.filetype}W ", ctx.info_fg, ctx.bar_bg, [], nil}
        end)

        assert segment_text(segments(@base_data)) =~ "elixirW"
      after
        ModelineSegments.unregister(segment_name)
      end
    end

    test "unknown segment names are ignored" do
      with_options(fn options ->
        Options.set(options, :modeline_left_segments, [:mode, :missing_segment, :filename])
        Options.set(options, :modeline_right_segments, [])

        assert ids(@base_data) == [:mode, :filename]
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

        assert Enum.any?(segments.left, &(&1.id == segment_name and &1.text == " LEFTY "))
        refute Enum.any?(segments.right, &(&1.text == " LEFTY "))
      after
        ModelineSegments.unregister(segment_name)
      end
    end

    test "explicit segments retain side, order and duplicates ahead of ordered defaults" do
      table = start_segment_registry()

      for {name, side, priority} <- [
            {:beta, :left, 10},
            {:alpha, :left, 10},
            {:high_priority, :left, 20},
            {:moved, :left, 30},
            {:right_default, :right, 40}
          ] do
        register_segment(table, name, [side: side, priority: priority], fn _ctx ->
          {Atom.to_string(name), 0, 0, [], nil}
        end)
      end

      with_options(fn options ->
        Options.set(options, :modeline_left_segments, [])
        Options.set(options, :modeline_right_segments, [:moved, :filename, :moved])

        assert %{left: left, right: right} = registry_segments(table)
        assert Enum.map(left, & &1.id) == [:high_priority, :alpha, :beta]
        assert Enum.map(right, & &1.id) == [:moved, :filename, :moved, :right_default]
      end)
    end

    test "both sides keep their names while each occurrence resolves the latest callback" do
      table = start_segment_registry()

      register_segment(table, :later, [side: :right], fn _ctx ->
        flunk("the replaced callback should not run")
      end)

      register_segment(table, :changing, [side: :left], fn _ctx ->
        register_segment(table, :changing, [side: :left], fn _ctx ->
          {"second", 0, 0, [], nil}
        end)

        register_segment(table, :later, [side: :left], fn _ctx ->
          {"replacement", 0, 0, [], nil}
        end)

        {"first", 0, 0, [], nil}
      end)

      with_options(fn options ->
        Options.set(options, :modeline_left_segments, [:changing, :changing])
        Options.set(options, :modeline_right_segments, [])

        assert tuples(registry_segments(table)) == %{
                 left: [{:changing, "first", 0, 0, [], nil}, {:changing, "second", 0, 0, [], nil}],
                 right: [{:later, "replacement", 0, 0, [], nil}]
               }
      end)
    end

    test "nested output is validated depth first and preserves surviving tuples and targets" do
      table = start_segment_registry()

      register_segment(table, :nested_modeline_test, [side: :left], fn _ctx ->
        [
          {"first", 1, 2, [], :workspace_list},
          [nil, [:first_bad_leaf, {"second", 3, 4, [], nil}]],
          :later_bad_leaf,
          [],
          {"third", 5, 6, [], :indent_picker}
        ]
      end)

      register_segment(table, :after_nested, [side: :left], fn _ctx ->
        Minga.Log.warning(:config, "After nested modeline callback")
        []
      end)

      with_options(fn options ->
        Options.set(options, :modeline_left_segments, [:nested_modeline_test, :after_nested])
        Options.set(options, :modeline_right_segments, [])

        {segments, log} = with_log(fn -> registry_segments(table) end)

        assert tuples(segments) == %{
                 left: [
                   {:nested_modeline_test, "first", 1, 2, [], :workspace_list},
                   {:nested_modeline_test, "second", 3, 4, [], nil},
                   {:nested_modeline_test, "third", 5, 6, [], :indent_picker}
                 ],
                 right: []
               }

        assert {warning_offset, _} =
                 :binary.match(
                   log,
                   "Invalid modeline segment :nested_modeline_test output ignored: :first_bad_leaf"
                 )

        assert {callback_offset, _} = :binary.match(log, "After nested modeline callback")
        assert warning_offset < callback_offset
        refute log =~ ":later_bad_leaf"
      end)
    end

    test "accepted options retain order and duplicates; rejected lists warn at the first failure" do
      table = start_segment_registry()

      opts = [
        italic: false,
        underline_style: :curl,
        blend: 0,
        bold: true,
        underline_color: 0xFF_FFFF,
        blend: 100,
        font_family: "Monospace",
        font_weight: :semibold,
        font_slant: :oblique,
        font_features: %{"kern" => true, "liga" => false},
        bold: false
      ]

      register_segment(table, :compatible_opts_modeline_test, [side: :left], fn _ctx ->
        [
          {"valid", 0, 0, opts, nil},
          {"malformed", 0, 0, [{:bold, :invalid}, :not_a_pair], nil},
          {"invalid", 0, 0, [blend: 0, blend: 101, italic: :invalid], nil}
        ]
      end)

      with_options(fn options ->
        Options.set(options, :modeline_left_segments, [])
        Options.set(options, :modeline_right_segments, [])

        {segments, log} = with_log(fn -> registry_segments(table) end)

        assert tuples(segments) == %{
                 left: [{:compatible_opts_modeline_test, "valid", 0, 0, opts, nil}],
                 right: []
               }

        warning = "Invalid modeline segment :compatible_opts_modeline_test"
        assert log =~ "#{warning} options ignored: expected a keyword list"
        assert log =~ "#{warning} option ignored: :blend=101"
        refute log =~ "#{warning} option ignored: :bold="
        refute log =~ "#{warning} option ignored: :italic="
      end)
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

  defp start_segment_registry do
    table = :"modeline_segments_#{System.unique_integer([:positive])}"
    start_supervised!({ModelineSegments, name: table})
    table
  end

  defp register_segment(table, name, opts, render) do
    assert :ok = ModelineSegments.register(table, name, opts, render, :config)
  end

  defp registry_segments(table, data \\ @base_data) do
    Modeline.gui_segments(data, MingaEditor.UI.Theme.get!(:doom_one), table)
  end

  defp gui_segments(data, nil), do: Modeline.gui_segments(data, @theme)

  defp segment_text(segments), do: Enum.map_join(segments, " ", & &1.text)

  defp segments(data), do: data |> gui_segments(nil) |> then(&(&1.left ++ &1.right))

  defp segment(data, id), do: data |> segments() |> Enum.find(&(&1.id == id))

  defp ids(data), do: data |> segments() |> Enum.map(& &1.id)

  # Custom segments keep the tuple shape their render callbacks return; compare in that shape.
  defp tuples(%{left: left, right: right}),
    do: %{left: Enum.map(left, &tuple/1), right: Enum.map(right, &tuple/1)}

  defp tuple(%Segment{} = s), do: {s.id, s.text, s.fg, s.bg, s.style, s.target}
end
