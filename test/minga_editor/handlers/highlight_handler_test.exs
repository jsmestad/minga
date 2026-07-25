defmodule MingaEditor.Handlers.HighlightHandlerTest do
  alias Minga.Buffer
  alias Minga.Language.Highlight.Span
  use ExUnit.Case, async: true

  alias Minga.Parser.EventCorrelation
  alias Minga.Parser.Manager
  alias MingaEditor.Handlers.HighlightHandler
  alias MingaEditor.HighlightSync
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Parser, as: ParserState
  alias MingaEditor.UI.Highlight
  alias MingaEditor.Window

  @spec base_state(keyword()) :: EditorState.t()
  defp base_state(opts \\ []) do
    manager = Module.concat(__MODULE__, "Parser#{System.unique_integer([:positive])}")

    start_supervised!(
      {Manager, name: manager, parser_path: "/missing/minga-parser"},
      id: {:parser_manager, manager}
    )

    state = TestHelpers.base_state(opts)
    %{state | parser: ParserState.new(manager)}
  end

  @spec with_highlight(EditorState.t(), pid()) :: EditorState.t()
  defp with_highlight(state, pid) do
    hl = state.parser.highlighting
    theme = state.appearance.theme

    buf_hl = %Highlight{
      version: 0,
      spans: {},
      capture_names: {},
      theme: theme.syntax,
      face_registry: MingaEditor.UI.Face.Registry.from_theme(theme)
    }

    updated_hl = %{hl | highlights: Map.put(hl.highlights, pid, buf_hl)}
    %{state | parser: ParserState.accept_highlighting(state.parser, updated_hl)}
  end

  describe "setup and parser lifecycle" do
    test "setup, parser status, eviction, and catch-all messages return the expected effects" do
      state = base_state()
      {_, setup_effects} = HighlightHandler.handle(state, :setup_highlight)
      assert setup_effects == [{:request_semantic_tokens, active_buffer(state)}]

      {crashed, effects} =
        HighlightHandler.handle(base_state(), {:minga_highlight, :parser_crashed})

      assert crashed.parser.parser_status == :restarting
      assert effects == []

      restart_base = base_state()

      restarted_state =
        restart_base |> with_highlight(active_buffer(restart_base)) |> mark_parser_restarting()

      {restarted, effects} =
        HighlightHandler.handle(restarted_state, {:minga_highlight, :parser_restarted})

      assert restarted.parser.parser_status == :available

      assert Enum.all?(Map.values(restarted.workspace.windows.map), fn %Window{} = window ->
               match?(%MingaEditor.Window.RenderCache{}, window.render_cache)
             end)

      assert Enum.all?(restarted.parser.highlighting.highlights, fn {_pid, hl} ->
               hl.version == 0
             end)

      assert {:log_message, "Parser restarted, syntax highlighting recovered"} in effects

      {unavailable, effects} =
        HighlightHandler.handle(base_state(), {:minga_highlight, :parser_gave_up})

      assert unavailable.parser.parser_status == :unavailable

      assert Enum.any?(effects, fn
               {:log_message, msg} -> String.contains?(msg, "syntax highlighting disabled")
               _ -> false
             end)

      {_, headless_effects} = HighlightHandler.handle(base_state(), :evict_parser_trees)
      refute {:evict_parser_trees_timer} in headless_effects

      tui_state = base_state(backend: :tui)
      {_, tui_effects} = HighlightHandler.handle(tui_state, :evict_parser_trees)
      assert {:evict_parser_trees_timer} in tui_effects

      catch_all_state = base_state()

      assert {^catch_all_state, []} =
               HighlightHandler.handle(catch_all_state, {:minga_highlight, :unknown_event})
    end

    test "grammar and port log messages are translated to log effects" do
      success_state = base_state()

      assert {^success_state, [{:log, :editor, :info, "Grammar loaded: elixir"}]} =
               HighlightHandler.handle(
                 success_state,
                 {:minga_highlight, {:grammar_loaded, true, "elixir"}}
               )

      failure_state = base_state()

      assert {^failure_state, [{:log, :editor, :warning, "Grammar failed to load: unknown"}]} =
               HighlightHandler.handle(
                 failure_state,
                 {:minga_highlight, {:grammar_loaded, false, "unknown"}}
               )

      {_, parser_effects} =
        HighlightHandler.handle(
          base_state(),
          {:minga_highlight, {:log_message, :info, "test msg"}}
        )

      assert {:log_message, "[PARSER/info] test msg"} in parser_effects

      {_, input_effects} =
        HighlightHandler.handle(base_state(), {:minga_input, {:log_message, :info, "test msg"}})

      assert Enum.any?(input_effects, fn
               {:log_message, msg} -> String.contains?(msg, "test msg")
               _ -> false
             end)
    end
  end

  describe "highlight metadata" do
    test "highlight names support active and non-active buffers" do
      state = base_state()
      buf = active_buffer(state)
      state = with_highlight(state, buf)

      {new_state, []} =
        HighlightHandler.handle(
          state,
          {:minga_highlight, {:highlight_names, buf, ["keyword"]}}
        )

      assert HighlightSync.get_highlight(new_state, buf).capture_names == {"keyword"}

      {state, other_buf} = state_with_other_buffer(base_state())
      state = with_highlight(state, other_buf)

      {new_state, []} =
        HighlightHandler.handle(
          state,
          {:minga_highlight, {:highlight_names, other_buf, ["string"]}}
        )

      assert HighlightSync.get_highlight(new_state, other_buf).capture_names == {"string"}
    end

    test "an old queued event is rejected after registration presentation replacement" do
      state = base_state()
      buffer = active_buffer(state)
      old_correlation = EventCorrelation.new(make_ref(), 4)
      current_correlation = EventCorrelation.new(make_ref(), 0)

      state =
        state
        |> with_highlight(buffer)
        |> then(fn state ->
          current = HighlightSync.get_highlight(state, buffer)

          HighlightSync.put_highlight(
            state,
            buffer,
            Highlight.correlate(current, current_correlation)
          )
        end)

      old_event =
        {:minga_highlight,
         {:buffer_event, buffer, old_correlation, {:highlight_spans, [%{start_byte: 0}]}}}

      assert {^state, []} = HighlightHandler.handle(state, old_event)

      current_event =
        {:minga_highlight,
         {:buffer_event, buffer, %{current_correlation | version: 1}, {:highlight_spans, []}}}

      {accepted, effects} = HighlightHandler.handle(state, current_event)
      assert effects == [{:request_semantic_tokens, buffer}, {:prettify_symbols, buffer}, :render]
      assert HighlightSync.get_highlight(accepted, buffer).parser_correlation.version == 1
    end

    test "queued parser events cannot recreate removed presentation state" do
      state = base_state()
      buffer = active_buffer(state)
      spans = [Span.new(0, 1, 0)]

      assert {^state, []} =
               HighlightHandler.handle(
                 state,
                 {:minga_highlight, {:highlight_names, buffer, ["keyword"]}}
               )

      assert {^state, []} =
               HighlightHandler.handle(
                 state,
                 {:minga_highlight, {:highlight_spans, buffer, spans}}
               )

      assert {^state, []} =
               HighlightHandler.handle(
                 state,
                 {:minga_highlight, {:injection_ranges, buffer, []}}
               )

      assert {^state, []} =
               HighlightHandler.handle(
                 state,
                 {:minga_highlight, {:conceal_spans, buffer, spans}}
               )
    end

    test "injection ranges update only the public highlight state" do
      state = base_state()
      buf = active_buffer(state)
      state = with_highlight(state, buf)
      ranges = [%{start: 0, end: 10, language: "elixir"}]

      {new_state, []} =
        HighlightHandler.handle(state, {:minga_highlight, {:injection_ranges, buf, ranges}})

      assert new_state.parser.injection_ranges[buf] == ranges
    end

    test "highlight and conceal spans produce visible-buffer effects and skip invisible buffers" do
      state = base_state()
      buf = active_buffer(state)
      state = with_highlight(state, buf)

      spans = [Span.new(0, 9, 0), Span.new(10, 15, 1)]

      {new_state, effects} =
        HighlightHandler.handle(state, {:minga_highlight, {:highlight_spans, buf, spans}})

      assert HighlightSync.get_highlight(new_state, buf).version == 1
      assert HighlightSync.get_highlight(new_state, buf).spans == List.to_tuple(spans)
      assert effects == [{:request_semantic_tokens, buf}, {:prettify_symbols, buf}, :render]

      spans = [%{start_byte: 0, end_byte: 5, replacement: ""}]

      {_, effects} =
        HighlightHandler.handle(state, {:minga_highlight, {:conceal_spans, buf, spans}})

      assert {:conceal_spans, buf, spans} in effects

      dispatch_state =
        HighlightHandler.dispatch(state, {:minga_highlight, {:conceal_spans, buf, spans}})

      [conceal] = Buffer.decorations(buf).conceal_ranges

      assert dispatch_state == state
      assert conceal.start_pos == {0, 0}
      assert conceal.end_pos == {0, 5}
      assert conceal.replacement == nil
      assert conceal.group == :ts_conceal

      {visible_state, visible_buf} = state_with_visible_other_buffer(base_state())
      visible_state = with_highlight(visible_state, visible_buf)

      assert {_, [{:request_semantic_tokens, ^visible_buf}, :render]} =
               HighlightHandler.handle(
                 visible_state,
                 {:minga_highlight, {:highlight_spans, visible_buf, []}}
               )

      {state, other_buf} = state_with_other_buffer(base_state())
      state = with_highlight(state, other_buf)

      assert {_, []} =
               HighlightHandler.handle(
                 state,
                 {:minga_highlight, {:highlight_spans, other_buf, []}}
               )
    end
  end

  describe "window metadata" do
    test "fold ranges and textobject positions update the active window and ignore invisible buffers" do
      state = base_state()
      buf = active_buffer(state)

      {new_state, _effects} =
        HighlightHandler.handle(
          state,
          {:minga_highlight, {:fold_ranges, buf, [{0, 5}, {10, 15}]}}
        )

      assert Enum.count(active_window(new_state).fold_ranges) == 2

      positions = %{function: [{0, 5}]}

      {new_state, []} =
        HighlightHandler.handle(
          new_state,
          {:minga_highlight, {:textobject_positions, buf, positions}}
        )

      assert active_window(new_state).textobject_positions == positions

      {other_state, other_buf} = state_with_other_buffer(base_state())

      assert {^other_state, []} =
               HighlightHandler.handle(
                 other_state,
                 {:minga_highlight, {:fold_ranges, other_buf, [{0, 5}]}}
               )

      assert {^other_state, []} =
               HighlightHandler.handle(
                 other_state,
                 {:minga_highlight, {:textobject_positions, other_buf, %{}}}
               )
    end

    test "document symbols update active and visible matching windows" do
      state = base_state()
      buf = active_buffer(state)
      symbols = [%Minga.Language.Symbol{kind: :function, name: "run", range: {0, 0, 3, 3}}]

      {new_state, []} =
        HighlightHandler.handle(state, {:minga_highlight, {:document_symbols, buf, symbols}})

      assert active_window(new_state).document_symbols == symbols

      visible_state = state_with_visible_inactive_buffer_symbols(state)
      fresh_symbols = [%Minga.Language.Symbol{kind: :function, name: "new", range: {0, 0, 0, 3}}]

      {updated, []} =
        HighlightHandler.handle(
          visible_state,
          {:minga_highlight, {:document_symbols, buf, fresh_symbols}}
        )

      assert Map.fetch!(updated.workspace.windows.map, 1).document_symbols == fresh_symbols
      assert Map.fetch!(updated.workspace.windows.map, 2).document_symbols == []
    end
  end

  defp active_buffer(state), do: state.workspace.buffers.active

  defp active_window(state),
    do: Map.fetch!(state.workspace.windows.map, state.workspace.windows.active)

  defp state_with_other_buffer(state) do
    {:ok, other_buf} = Minga.Buffer.Process.start_link(content: "other")
    {state, other_buf}
  end

  defp state_with_visible_other_buffer(state) do
    {:ok, other_buf} = Minga.Buffer.Process.start_link(content: "other")
    window = Window.new(2, other_buf, 24, 80)

    windows = %{
      state.workspace.windows
      | map: Map.put(state.workspace.windows.map, 2, window),
        next_id: 3
    }

    {%{state | workspace: %{state.workspace | windows: windows}}, other_buf}
  end

  defp mark_parser_restarting(state) do
    buf = active_buffer(state)
    hl = state.parser.highlighting
    buf_hl = Map.fetch!(hl.highlights, buf)

    updated_hl = %{hl | highlights: Map.put(hl.highlights, buf, %{buf_hl | version: 3})}

    parser =
      state.parser
      |> ParserState.accept_highlighting(updated_hl)
      |> ParserState.report_status(:restarting)

    %{state | parser: parser}
  end

  defp state_with_visible_inactive_buffer_symbols(state) do
    {:ok, other_buf} = Minga.Buffer.Process.start_link(content: "other")
    stale_symbols = [%Minga.Language.Symbol{kind: :function, name: "old", range: {0, 0, 0, 3}}]

    state =
      then(state, fn state ->
        %{
          state
          | workspace:
              then(
                state.workspace,
                &MingaEditor.Session.State.set_windows(
                  &1,
                  MingaEditor.State.Windows.set_document_symbols_for_buffer(
                    state.workspace.windows,
                    state.workspace.buffers.active,
                    stale_symbols
                  )
                )
              )
        }
      end)

    second_window = Window.new(2, other_buf, 24, 80)

    workspace =
      %{state.workspace | buffers: %{state.workspace.buffers | active: other_buf}}
      |> then(fn ws ->
        %{
          ws
          | windows: %{
              ws.windows
              | map: Map.put(ws.windows.map, 2, second_window),
                active: 2,
                next_id: 3
            }
        }
      end)

    %{state | workspace: workspace}
  end
end
