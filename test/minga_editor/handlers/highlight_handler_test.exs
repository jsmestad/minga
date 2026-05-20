defmodule MingaEditor.Handlers.HighlightHandlerTest do
  @moduledoc """
  Pure-function tests for `MingaEditor.Handlers.HighlightHandler`.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.Handlers.HighlightHandler
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Highlight
  alias MingaEditor.Window
  alias MingaEditor.Workspace.State, as: WorkspaceState

  import MingaEditor.RenderPipeline.TestHelpers

  @spec with_buffer_id(EditorState.t(), pid(), non_neg_integer()) :: EditorState.t()
  defp with_buffer_id(state, pid, buffer_id) do
    hl = state.workspace.highlight

    updated_hl = %{
      hl
      | buffer_ids: Map.put(hl.buffer_ids, pid, buffer_id),
        reverse_buffer_ids: Map.put(hl.reverse_buffer_ids, buffer_id, pid),
        next_buffer_id: max(hl.next_buffer_id, buffer_id + 1)
    }

    %{state | workspace: %{state.workspace | highlight: updated_hl}}
  end

  @spec with_highlight(EditorState.t(), pid()) :: EditorState.t()
  defp with_highlight(state, pid) do
    hl = state.workspace.highlight
    theme = state.theme

    buf_hl = %Highlight{
      version: 0,
      spans: {},
      capture_names: {},
      theme: theme.syntax,
      face_registry: MingaEditor.UI.Face.Registry.from_theme(theme)
    }

    updated_hl = %{hl | highlights: Map.put(hl.highlights, pid, buf_hl)}
    %{state | workspace: %{state.workspace | highlight: updated_hl}}
  end

  describe "setup and parser lifecycle" do
    test "setup, parser status, eviction, and catch-all messages return the expected effects" do
      {_, setup_effects} = HighlightHandler.handle(base_state(), :setup_highlight)
      assert {:request_semantic_tokens} in setup_effects

      {crashed, effects} =
        HighlightHandler.handle(base_state(), {:minga_highlight, :parser_crashed})

      assert crashed.parser_status == :restarting
      assert effects == []

      restart_base = base_state()

      restarted_state =
        restart_base |> with_highlight(active_buffer(restart_base)) |> mark_parser_restarting()

      {restarted, effects} =
        HighlightHandler.handle(restarted_state, {:minga_highlight, :parser_restarted})

      assert restarted.parser_status == :available
      assert restarted.workspace.highlight.version == 0

      assert Enum.all?(restarted.workspace.highlight.highlights, fn {_pid, hl} ->
               hl.version == 0
             end)

      assert {:log_message, "Parser restarted, syntax highlighting recovered"} in effects

      {unavailable, effects} =
        HighlightHandler.handle(base_state(), {:minga_highlight, :parser_gave_up})

      assert unavailable.parser_status == :unavailable

      assert Enum.any?(effects, fn
               {:log_message, msg} -> String.contains?(msg, "syntax highlighting disabled")
               _ -> false
             end)

      {_, headless_effects} = HighlightHandler.handle(base_state(), :evict_parser_trees)
      refute {:evict_parser_trees_timer} in headless_effects

      tui_state = %{base_state() | backend: :tui}
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

  describe "unknown buffer ids" do
    test "highlight messages for missing buffer ids log warnings without changing state" do
      state = base_state()

      messages = [
        {:minga_highlight, {:highlight_names, 999, ["keyword"]}},
        {:minga_highlight, {:injection_ranges, 999, []}},
        {:minga_highlight, {:highlight_spans, 999, 1, []}},
        {:minga_highlight, {:conceal_spans, 999, 1, []}},
        {:minga_highlight, {:fold_ranges, 999, 1, []}},
        {:minga_highlight, {:textobject_positions, 999, 1, %{}}},
        {:minga_highlight, {:document_symbols, 999, 1, []}}
      ]

      for message <- messages do
        {new_state, effects} = HighlightHandler.handle(state, message)
        assert new_state == state
        assert warning_effect?(effects)
      end
    end
  end

  describe "highlight metadata" do
    test "highlight names support active, non-active, and input-tagged buffers" do
      state = base_state()
      buf = active_buffer(state)
      state = state |> with_buffer_id(buf, 1) |> with_highlight(buf)

      assert {_, []} =
               HighlightHandler.handle(
                 state,
                 {:minga_highlight, {:highlight_names, 1, ["keyword"]}}
               )

      assert {_, []} =
               HighlightHandler.handle(state, {:minga_input, {:highlight_names, 1, ["keyword"]}})

      {state, other_buf} = state_with_other_buffer(base_state(), 2)
      state = with_highlight(state, other_buf)

      {new_state, []} =
        HighlightHandler.handle(state, {:minga_highlight, {:highlight_names, 2, ["string"]}})

      assert new_state.workspace.highlight.highlights[other_buf] != nil
    end

    test "injection ranges and language responses update only the public highlight state" do
      state = base_state()
      buf = active_buffer(state)
      state = with_buffer_id(state, buf, 1)
      ranges = [%{start: 0, end: 10, language: "elixir"}]

      {new_state, []} =
        HighlightHandler.handle(state, {:minga_highlight, {:injection_ranges, 1, ranges}})

      assert new_state.workspace.injection_ranges[buf] == ranges

      assert {^new_state, []} =
               HighlightHandler.handle(
                 new_state,
                 {:minga_highlight, {:language_at_response, 1, "elixir"}}
               )
    end

    test "highlight and conceal spans produce visible-buffer effects and skip invisible buffers" do
      state = base_state()
      buf = active_buffer(state)
      state = state |> with_buffer_id(buf, 1) |> with_highlight(buf)

      {_, effects} =
        HighlightHandler.handle(state, {:minga_highlight, {:highlight_spans, 1, 1, []}})

      assert :render in effects
      assert Enum.any?(effects, &match?({:prettify_symbols, _}, &1))

      spans = [%{start_byte: 0, end_byte: 5, replacement: ""}]

      {_, effects} =
        HighlightHandler.handle(state, {:minga_highlight, {:conceal_spans, 1, 1, spans}})

      assert {:conceal_spans, buf, spans} in effects

      {state, other_buf} = state_with_other_buffer(base_state(), 2)
      state = with_highlight(state, other_buf)

      assert {_, []} =
               HighlightHandler.handle(state, {:minga_highlight, {:highlight_spans, 2, 1, []}})
    end
  end

  describe "window metadata" do
    test "fold ranges and textobject positions update the active window and ignore invisible buffers" do
      state = base_state()
      buf = active_buffer(state)
      state = with_buffer_id(state, buf, 1)

      {new_state, _effects} =
        HighlightHandler.handle(
          state,
          {:minga_highlight, {:fold_ranges, 1, 1, [{0, 5}, {10, 15}]}}
        )

      assert length(active_window(new_state).fold_ranges) == 2

      positions = %{function: [{0, 5}]}

      {new_state, []} =
        HighlightHandler.handle(
          new_state,
          {:minga_highlight, {:textobject_positions, 1, 1, positions}}
        )

      assert active_window(new_state).textobject_positions == positions

      {other_state, _other_buf} = state_with_other_buffer(base_state(), 2)

      assert {^other_state, []} =
               HighlightHandler.handle(
                 other_state,
                 {:minga_highlight, {:fold_ranges, 2, 1, [{0, 5}]}}
               )

      assert {^other_state, []} =
               HighlightHandler.handle(
                 other_state,
                 {:minga_highlight, {:textobject_positions, 2, 1, %{}}}
               )
    end

    test "document symbols update active and visible matching windows" do
      state = base_state()
      buf = active_buffer(state)
      state = with_buffer_id(state, buf, 1)
      symbols = [%Minga.Language.Symbol{kind: :function, name: "run", range: {0, 0, 3, 3}}]

      {new_state, []} =
        HighlightHandler.handle(state, {:minga_highlight, {:document_symbols, 1, 1, symbols}})

      assert active_window(new_state).document_symbols == symbols

      visible_state = state_with_visible_inactive_buffer_symbols(state)
      fresh_symbols = [%Minga.Language.Symbol{kind: :function, name: "new", range: {0, 0, 0, 3}}]

      {updated, []} =
        HighlightHandler.handle(
          visible_state,
          {:minga_highlight, {:document_symbols, 1, 1, fresh_symbols}}
        )

      assert Map.fetch!(updated.workspace.windows.map, 1).document_symbols == fresh_symbols
      assert Map.fetch!(updated.workspace.windows.map, 2).document_symbols == []
    end
  end

  defp active_buffer(state), do: state.workspace.buffers.active

  defp active_window(state),
    do: Map.fetch!(state.workspace.windows.map, state.workspace.windows.active)

  defp state_with_other_buffer(state, buffer_id) do
    {:ok, other_buf} = Minga.Buffer.Process.start_link(content: "other")
    {with_buffer_id(state, other_buf, buffer_id), other_buf}
  end

  defp warning_effect?(effects) do
    Enum.any?(effects, fn
      {:log, :editor, :warning, _message} -> true
      _ -> false
    end)
  end

  defp mark_parser_restarting(state) do
    buf = active_buffer(state)
    hl = state.workspace.highlight
    buf_hl = Map.fetch!(hl.highlights, buf)

    updated_hl = %{
      hl
      | version: 5,
        highlights: Map.put(hl.highlights, buf, %{buf_hl | version: 3})
    }

    %{state | workspace: %{state.workspace | highlight: updated_hl}, parser_status: :restarting}
  end

  defp state_with_visible_inactive_buffer_symbols(state) do
    first_buf = active_buffer(state)
    {:ok, other_buf} = Minga.Buffer.Process.start_link(content: "other")
    stale_symbols = [%Minga.Language.Symbol{kind: :function, name: "old", range: {0, 0, 0, 3}}]

    state = with_buffer_id(state, first_buf, 1)
    win_id = state.workspace.windows.active

    state =
      EditorState.update_workspace(state, fn ws ->
        WorkspaceState.update_window(ws, win_id, fn window ->
          Window.set_document_symbols(window, stale_symbols)
        end)
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
