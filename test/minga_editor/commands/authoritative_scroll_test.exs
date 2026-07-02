defmodule MingaEditor.Commands.AuthoritativeScrollTest do
  @moduledoc """
  Dispatch-level coverage for the authoritative-scroll marker (#2652).

  The marker's unit mechanics (settle, writeback, no-latch) are covered in
  `window_test.exs` and `scroll_seq_writeback_test.exs`; these tests pin the
  wiring those suites bypass: dispatching a real command through
  `MingaEditor.Commands.execute/2` must set the marker for a representative of
  each always-authoritative family, must NOT set it for pure cursor motion, and
  failable jumps must mark only when they actually land.
  """

  # base_state seeds the shell registry and the LSP isolation helper stops
  # global clients, so run serially.
  use ExUnit.Case, async: false

  alias Minga.Test.LspIsolation
  alias MingaEditor.Commands
  alias MingaEditor.LspActions
  alias MingaEditor.Window

  import MingaEditor.RenderPipeline.TestHelpers

  setup do
    LspIsolation.stop_lsp_clients()
    on_exit(&LspIsolation.stop_lsp_clients/0)
    :ok
  end

  describe "always-authoritative commands mark at dispatch" do
    test "one representative per family sets the marker exactly once" do
      for cmd <- [:scroll_center, :scroll_down_line, :half_page_down, :move_to_document_end] do
        state = base_state(content: long_content(50))
        assert marker(state) == 0

        updated = Commands.execute(state, cmd)
        assert marker(updated) == 1, "#{inspect(cmd)} should mark the active window"
      end
    end

    test "goto_line marks in its own dispatch clause" do
      state = base_state(content: long_content(50))

      updated = Commands.execute(state, {:goto_line, 10})
      assert marker(updated) == 1
    end
  end

  describe "non-authoritative commands do not mark" do
    test "pure cursor motion leaves the marker untouched" do
      for cmd <- [:word_forward, :move_to_line_start] do
        state = base_state(content: long_content(50))

        updated = Commands.execute(state, cmd)
        assert marker(updated) == 0, "#{inspect(cmd)} must not mark the active window"
      end
    end

    test "set_mark records a mark without marking the window" do
      state = base_state(content: long_content(50))

      updated = Commands.execute(state, {:set_mark, "a"})
      assert marker(updated) == 0
    end
  end

  describe "failable jumps mark only on success" do
    test "search_next marks when a match is found" do
      state = base_state(content: long_content(50)) |> with_pattern("line 30")

      updated = Commands.execute(state, :search_next)
      assert marker(updated) == 1
    end

    test "search_next with no match does not mark" do
      state = base_state(content: long_content(50)) |> with_pattern("no such needle qq")

      updated = Commands.execute(state, :search_next)
      assert marker(updated) == 0
    end

    test "search_next with no previous pattern does not mark" do
      state = base_state(content: long_content(50))

      updated = Commands.execute(state, :search_next)
      assert marker(updated) == 0
    end

    test "jump_to_mark_exact marks for a set mark and not for an unset one" do
      state =
        base_state(content: long_content(50))
        |> Commands.execute({:set_mark, "a"})

      assert marker(Commands.execute(state, {:jump_to_mark_exact, "a"})) == 1
      assert marker(Commands.execute(state, {:jump_to_mark_exact, "z"})) == 0
    end

    test "goto_definition does not mark at dispatch (async LSP request seam)" do
      state = base_state(content: long_content(50))

      updated = Commands.execute(state, :goto_definition)
      assert marker(updated) == 0
    end

    test "an LSP jump marks at the landing seam (open_location)" do
      path =
        Path.join(
          System.tmp_dir!(),
          "authoritative_scroll_#{System.unique_integer([:positive])}.txt"
        )

      File.write!(path, long_content(20))
      on_exit(fn -> File.rm(path) end)

      {:ok, buf} = Minga.Buffer.Process.start_link(file_path: path)
      state = base_state(content: long_content(50))

      state = %{
        state
        | workspace: %{
            state.workspace
            | buffers: %{state.workspace.buffers | active: buf, list: [buf]}
          }
      }

      updated = LspActions.open_location(state, "file://" <> path, 5, 0)
      assert marker(updated) == 1
    end
  end

  defp marker(state) do
    win_id = state.workspace.windows.active
    Window.authoritative_scroll_seq(state.workspace.windows.map[win_id])
  end

  defp with_pattern(state, pattern) do
    %{
      state
      | workspace: %{
          state.workspace
          | search: %{state.workspace.search | last_pattern: pattern, last_direction: :forward}
        }
    }
  end
end
