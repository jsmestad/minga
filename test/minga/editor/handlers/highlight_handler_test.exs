defmodule Minga.Editor.Handlers.HighlightHandlerTest do
  @moduledoc """
  Pure-function tests for `Minga.Editor.Handlers.HighlightHandler`.

  Uses `RenderPipeline.TestHelpers.base_state/1` to construct state
  without starting a GenServer. Each test calls `handle/2` directly
  and asserts on the returned `{state, effects}` tuple.
  """

  use ExUnit.Case, async: true

  alias Minga.Editor.Handlers.HighlightHandler
  alias Minga.Editor.State, as: EditorState
  alias Minga.UI.Highlight

  import Minga.Editor.RenderPipeline.TestHelpers

  # Helper to register a buffer_id mapping in the highlight state.
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

  # Helper to put a highlight entry for a buffer.
  @spec with_highlight(EditorState.t(), pid()) :: EditorState.t()
  defp with_highlight(state, pid) do
    hl = state.workspace.highlight
    theme = state.theme
    syntax = theme.syntax

    buf_hl = %Highlight{
      version: 0,
      spans: {},
      capture_names: {},
      theme: syntax,
      face_registry: Minga.UI.Face.Registry.from_theme(theme)
    }

    updated_hl = %{hl | highlights: Map.put(hl.highlights, pid, buf_hl)}
    %{state | workspace: %{state.workspace | highlight: updated_hl}}
  end

  describe "setup_highlight" do
    test "returns request_semantic_tokens effect" do
      state = base_state()
      {_state, effects} = HighlightHandler.handle(state, :setup_highlight)
      assert {:request_semantic_tokens} in effects
    end
  end

  describe "highlight_names" do
    test "unknown buffer_id returns log warning effect" do
      state = base_state()

      {new_state, effects} =
        HighlightHandler.handle(state, {:minga_highlight, {:highlight_names, 999, ["keyword"]}})

      assert new_state == state

      assert Enum.any?(effects, fn
               {:log, :editor, :warning, msg} -> String.contains?(msg, "999")
               _ -> false
             end)
    end

    test "active buffer delegates to HighlightEvents" do
      state = base_state()
      buf = state.workspace.buffers.active
      state = with_buffer_id(state, buf, 1)
      state = with_highlight(state, buf)

      {_new_state, effects} =
        HighlightHandler.handle(state, {:minga_highlight, {:highlight_names, 1, ["keyword"]}})

      # Should succeed without errors; no render effect for names
      assert effects == []
    end

    test "non-active buffer stores names in highlights map" do
      state = base_state()
      # Create a secondary buffer
      {:ok, other_buf} = Minga.Buffer.Server.start_link(content: "other")
      state = with_buffer_id(state, other_buf, 2)
      state = with_highlight(state, other_buf)

      {new_state, effects} =
        HighlightHandler.handle(state, {:minga_highlight, {:highlight_names, 2, ["string"]}})

      assert effects == []
      # Verify names were stored
      other_hl = new_state.workspace.highlight.highlights[other_buf]
      assert other_hl != nil
    end

    test "works with :minga_input tag" do
      state = base_state()
      buf = state.workspace.buffers.active
      state = with_buffer_id(state, buf, 1)
      state = with_highlight(state, buf)

      {_state, _effects} =
        HighlightHandler.handle(state, {:minga_input, {:highlight_names, 1, ["keyword"]}})
    end
  end

  describe "injection_ranges" do
    test "unknown buffer_id returns log warning" do
      state = base_state()

      {new_state, effects} =
        HighlightHandler.handle(state, {:minga_highlight, {:injection_ranges, 999, []}})

      assert new_state == state

      assert Enum.any?(effects, fn
               {:log, :editor, :warning, _} -> true
               _ -> false
             end)
    end

    test "valid buffer stores ranges" do
      state = base_state()
      buf = state.workspace.buffers.active
      state = with_buffer_id(state, buf, 1)
      ranges = [%{start: 0, end: 10, language: "elixir"}]

      {new_state, effects} =
        HighlightHandler.handle(state, {:minga_highlight, {:injection_ranges, 1, ranges}})

      assert effects == []
      assert new_state.workspace.injection_ranges[buf] == ranges
    end
  end

  describe "language_at_response" do
    test "is a no-op" do
      state = base_state()

      {new_state, effects} =
        HighlightHandler.handle(state, {:minga_highlight, {:language_at_response, 1, "elixir"}})

      assert new_state == state
      assert effects == []
    end
  end

  describe "highlight_spans" do
    test "unknown buffer_id returns log warning" do
      state = base_state()

      {new_state, effects} =
        HighlightHandler.handle(state, {:minga_highlight, {:highlight_spans, 999, 1, []}})

      assert new_state == state

      assert Enum.any?(effects, fn
               {:log, :editor, :warning, _} -> true
               _ -> false
             end)
    end

    test "active buffer returns render and prettify effects" do
      state = base_state()
      buf = state.workspace.buffers.active
      state = with_buffer_id(state, buf, 1)
      state = with_highlight(state, buf)

      {_new_state, effects} =
        HighlightHandler.handle(state, {:minga_highlight, {:highlight_spans, 1, 1, []}})

      assert :render in effects

      assert Enum.any?(effects, fn
               {:prettify_symbols, _} -> true
               _ -> false
             end)
    end

    test "non-active buffer stores spans" do
      state = base_state()
      {:ok, other_buf} = Minga.Buffer.Server.start_link(content: "other")
      state = with_buffer_id(state, other_buf, 2)
      state = with_highlight(state, other_buf)

      {_new_state, effects} =
        HighlightHandler.handle(state, {:minga_highlight, {:highlight_spans, 2, 1, []}})

      # Not visible in any window, so no render
      assert effects == []
    end
  end

  describe "conceal_spans" do
    test "unknown buffer_id returns log warning" do
      state = base_state()

      {_state, effects} =
        HighlightHandler.handle(state, {:minga_highlight, {:conceal_spans, 999, 1, []}})

      assert Enum.any?(effects, fn
               {:log, :editor, :warning, _} -> true
               _ -> false
             end)
    end

    test "valid buffer returns conceal_spans effect" do
      state = base_state()
      buf = state.workspace.buffers.active
      state = with_buffer_id(state, buf, 1)
      spans = [%{start_byte: 0, end_byte: 5, replacement: ""}]

      {_state, effects} =
        HighlightHandler.handle(state, {:minga_highlight, {:conceal_spans, 1, 1, spans}})

      assert {:conceal_spans, ^buf, ^spans} =
               Enum.find(effects, &match?({:conceal_spans, _, _}, &1))
    end
  end

  describe "fold_ranges" do
    test "unknown buffer_id returns log warning" do
      state = base_state()

      {_state, effects} =
        HighlightHandler.handle(state, {:minga_highlight, {:fold_ranges, 999, 1, []}})

      assert Enum.any?(effects, fn
               {:log, :editor, :warning, _} -> true
               _ -> false
             end)
    end

    test "active buffer sets fold ranges on the window" do
      state = base_state()
      buf = state.workspace.buffers.active
      state = with_buffer_id(state, buf, 1)

      ranges = [{0, 5}, {10, 15}]

      {new_state, _effects} =
        HighlightHandler.handle(state, {:minga_highlight, {:fold_ranges, 1, 1, ranges}})

      win_id = new_state.workspace.windows.active
      window = Map.get(new_state.workspace.windows.map, win_id)
      assert length(window.fold_ranges) == 2
    end

    test "non-active buffer is a no-op" do
      state = base_state()
      {:ok, other_buf} = Minga.Buffer.Server.start_link(content: "other")
      state = with_buffer_id(state, other_buf, 2)

      {new_state, effects} =
        HighlightHandler.handle(state, {:minga_highlight, {:fold_ranges, 2, 1, [{0, 5}]}})

      assert new_state == state
      assert effects == []
    end
  end

  describe "textobject_positions" do
    test "unknown buffer_id returns log warning" do
      state = base_state()

      {_state, effects} =
        HighlightHandler.handle(state, {:minga_highlight, {:textobject_positions, 999, 1, %{}}})

      assert Enum.any?(effects, fn
               {:log, :editor, :warning, _} -> true
               _ -> false
             end)
    end

    test "active buffer sets positions on the window" do
      state = base_state()
      buf = state.workspace.buffers.active
      state = with_buffer_id(state, buf, 1)

      positions = %{function: [{0, 5}]}

      {new_state, effects} =
        HighlightHandler.handle(
          state,
          {:minga_highlight, {:textobject_positions, 1, 1, positions}}
        )

      assert effects == []
      win_id = new_state.workspace.windows.active
      window = Map.get(new_state.workspace.windows.map, win_id)
      assert window.textobject_positions == positions
    end

    test "non-active buffer is a no-op" do
      state = base_state()
      {:ok, other_buf} = Minga.Buffer.Server.start_link(content: "other")
      state = with_buffer_id(state, other_buf, 2)

      {new_state, effects} =
        HighlightHandler.handle(state, {:minga_highlight, {:textobject_positions, 2, 1, %{}}})

      assert new_state == state
      assert effects == []
    end
  end

  describe "grammar_loaded" do
    test "success returns info log effect" do
      state = base_state()

      {new_state, effects} =
        HighlightHandler.handle(state, {:minga_highlight, {:grammar_loaded, true, "elixir"}})

      assert new_state == state
      assert {:log, :editor, :info, "Grammar loaded: elixir"} in effects
    end

    test "failure returns warning log effect" do
      state = base_state()

      {new_state, effects} =
        HighlightHandler.handle(state, {:minga_highlight, {:grammar_loaded, false, "unknown"}})

      assert new_state == state
      assert {:log, :editor, :warning, "Grammar failed to load: unknown"} in effects
    end
  end

  describe "log_message" do
    test "from parser port prefixes with PARSER" do
      state = base_state()

      {_state, effects} =
        HighlightHandler.handle(state, {:minga_highlight, {:log_message, :info, "test msg"}})

      assert {:log_message, "[PARSER/info] test msg"} in effects
    end

    test "from renderer port prefixes with frontend type" do
      state = base_state()

      {_state, effects} =
        HighlightHandler.handle(state, {:minga_input, {:log_message, :info, "test msg"}})

      assert Enum.any?(effects, fn
               {:log_message, msg} -> String.contains?(msg, "test msg")
               _ -> false
             end)
    end
  end

  describe "parser_crashed" do
    test "sets parser_status to :restarting" do
      state = base_state()
      {new_state, effects} = HighlightHandler.handle(state, {:minga_highlight, :parser_crashed})
      assert new_state.parser_status == :restarting
      assert effects == []
    end
  end

  describe "parser_restarted" do
    test "resets highlight versions and sets parser_status to :available" do
      state = base_state()
      buf = state.workspace.buffers.active
      state = with_highlight(state, buf)

      # Set a non-zero version
      hl = state.workspace.highlight
      buf_hl = Map.get(hl.highlights, buf)

      updated_hl = %{
        hl
        | version: 5,
          highlights: Map.put(hl.highlights, buf, %{buf_hl | version: 3})
      }

      state = %{
        state
        | workspace: %{state.workspace | highlight: updated_hl},
          parser_status: :restarting
      }

      {new_state, effects} = HighlightHandler.handle(state, {:minga_highlight, :parser_restarted})
      assert new_state.parser_status == :available
      assert new_state.workspace.highlight.version == 0
      # All per-buffer highlights should have version 0
      Enum.each(new_state.workspace.highlight.highlights, fn {_pid, bhl} ->
        assert bhl.version == 0
      end)

      assert {:log_message, "Parser restarted, syntax highlighting recovered"} in effects
    end
  end

  describe "parser_gave_up" do
    test "sets parser_status to :unavailable with log message" do
      state = base_state()
      {new_state, effects} = HighlightHandler.handle(state, {:minga_highlight, :parser_gave_up})
      assert new_state.parser_status == :unavailable

      assert Enum.any?(effects, fn
               {:log_message, msg} -> String.contains?(msg, "syntax highlighting disabled")
               _ -> false
             end)
    end
  end

  describe "evict_parser_trees" do
    test "returns timer effect in non-headless mode" do
      state = base_state()
      state = %{state | backend: :tui}
      {_new_state, effects} = HighlightHandler.handle(state, :evict_parser_trees)
      assert {:evict_parser_trees_timer} in effects
    end

    test "returns no timer effect in headless mode" do
      state = base_state()
      # base_state defaults to headless
      {_new_state, effects} = HighlightHandler.handle(state, :evict_parser_trees)
      refute {:evict_parser_trees_timer} in effects
    end
  end

  describe "catch-all" do
    test "unknown messages return no-op" do
      state = base_state()
      {new_state, effects} = HighlightHandler.handle(state, {:minga_highlight, :unknown_event})
      assert new_state == state
      assert effects == []
    end
  end
end
