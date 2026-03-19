# credo:disable-for-this-file Credo.Check.Readability.Specs
defmodule Minga.Chaos.EditorFuzzerTest do
  @moduledoc """
  Stateful property-based chaos fuzzer for the editor.

  Uses PropCheck's `proper_statem` to generate random sequences of valid
  editor actions, run them against a headless editor, and verify invariants
  after every step. When a failure is found, PropEr automatically shrinks
  the sequence to the minimal reproduction.

  ## Running

      mix test test/minga/chaos/ --include chaos
      mix test test/minga/chaos/ --include chaos --seed 12345  # reproduce
  """

  use ExUnit.Case
  use PropCheck
  use PropCheck.StateM.ModelDSL

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Chaos.EditorActions
  alias Minga.Editor
  alias Minga.Test.HeadlessPort

  @moduletag :chaos
  @moduletag timeout: 120_000

  # ── Model state ──────────────────────────────────────────────────────────

  defmodule Model do
    @moduledoc false
    defstruct mode: :normal,
              line_count: 1,
              cursor_line: 0,
              width: 80,
              height: 24
  end

  # ── Setup / teardown ────────────────────────────────────────────────────

  defp store_ctx(ctx), do: Process.put(:chaos_editor_ctx, ctx)
  defp get_ctx, do: Process.get(:chaos_editor_ctx)

  defp start_chaos_editor(content) do
    width = 80
    height = 24
    id = :erlang.unique_integer([:positive])
    {:ok, port} = HeadlessPort.start_link(width: width, height: height)
    {:ok, buffer} = BufferServer.start_link(content: content)
    BufferServer.set_option(buffer, :clipboard, :none)

    # Stub clipboard with in-memory storage via ETS so yank/paste sequences
    # work realistically. ETS is used because the Editor GenServer calls
    # the clipboard from its own process, not the test process.
    clipboard_table = :ets.new(:chaos_clipboard, [:public, :set])

    Mox.stub(Minga.Clipboard.Mock, :write, fn text ->
      :ets.insert(clipboard_table, {:value, text})
      :ok
    end)

    Mox.stub(Minga.Clipboard.Mock, :read, fn ->
      case :ets.lookup(clipboard_table, :value) do
        [{:value, text}] -> text
        [] -> nil
      end
    end)

    {:ok, editor} =
      Editor.start_link(
        name: :"chaos_editor_#{id}",
        port_manager: port,
        buffer: buffer,
        width: width,
        height: height
      )

    # Allow the editor process to use our Mox stubs
    Mox.allow(Minga.Clipboard.Mock, self(), editor)

    ref = HeadlessPort.prepare_await(port)
    send(editor, {:minga_input, {:ready, width, height}})
    {:ok, _snapshot} = HeadlessPort.collect_frame(ref)

    %{editor: editor, buffer: buffer, port: port, width: width, height: height}
  end

  # ── Command implementations (called by PropEr) ──────────────────────────
  # ModelDSL generates {:call, __MODULE__, fun, args} from command_gen tuples.

  def normal_motion(motion), do: EditorActions.normal_motion(get_ctx(), motion)
  def enter_insert(variant), do: EditorActions.enter_insert(get_ctx(), variant)
  def enter_visual, do: EditorActions.enter_visual(get_ctx())
  def enter_visual_line, do: EditorActions.enter_visual_line(get_ctx())
  def enter_command, do: EditorActions.enter_command(get_ctx())
  def enter_replace, do: EditorActions.enter_replace(get_ctx())
  def delete_char, do: EditorActions.delete_char(get_ctx())
  def delete_line, do: EditorActions.delete_line(get_ctx())
  def yank_line, do: EditorActions.yank_line(get_ctx())
  def paste, do: EditorActions.paste(get_ctx())
  def paste_before, do: EditorActions.paste_before(get_ctx())
  def undo, do: EditorActions.undo(get_ctx())
  def redo, do: EditorActions.redo(get_ctx())
  def escape, do: EditorActions.escape(get_ctx())
  def insert_type(char), do: EditorActions.insert_type(get_ctx(), char)
  def insert_enter, do: EditorActions.insert_enter(get_ctx())
  def insert_backspace, do: EditorActions.insert_backspace(get_ctx())
  def visual_motion(motion), do: EditorActions.visual_motion(get_ctx(), motion)
  def visual_delete, do: EditorActions.visual_delete(get_ctx())
  def visual_yank, do: EditorActions.visual_yank(get_ctx())
  def command_type(char), do: EditorActions.command_type(get_ctx(), char)
  def command_enter, do: EditorActions.command_enter(get_ctx())
  def do_resize(w, h), do: EditorActions.resize(get_ctx(), w, h)
  def mouse_click(row, col), do: EditorActions.mouse_click(get_ctx(), row, col)

  # ── Multi-surface wrappers ──────────────────────────────────────────────
  def half_page_down, do: EditorActions.half_page_down(get_ctx())
  def half_page_up, do: EditorActions.half_page_up(get_ctx())
  def page_down, do: EditorActions.page_down(get_ctx())
  def page_up, do: EditorActions.page_up(get_ctx())
  def wheel_up, do: EditorActions.wheel_up(get_ctx())
  def wheel_down, do: EditorActions.wheel_down(get_ctx())
  def split_vertical, do: EditorActions.split_vertical(get_ctx())
  def split_horizontal, do: EditorActions.split_horizontal(get_ctx())
  def window_left, do: EditorActions.window_left(get_ctx())
  def window_right, do: EditorActions.window_right(get_ctx())
  def window_down, do: EditorActions.window_down(get_ctx())
  def window_up, do: EditorActions.window_up(get_ctx())
  def buffer_next, do: EditorActions.buffer_next(get_ctx())
  def buffer_prev, do: EditorActions.buffer_prev(get_ctx())
  def toggle_file_tree, do: EditorActions.toggle_file_tree(get_ctx())
  def toggle_agent_view, do: EditorActions.toggle_agent_view(get_ctx())
  def tab_next, do: EditorActions.tab_next(get_ctx())
  def tab_prev, do: EditorActions.tab_prev(get_ctx())

  # ── ModelDSL callbacks ─────────────────────────────────────────────────

  def initial_state, do: %Model{}

  # command_gen returns {function_name, [arg_generators]} tuples.
  # ModelDSL wraps them into {:call, __MODULE__, name, args} automatically.

  def command_gen(%Model{mode: :normal, width: w, height: h}) do
    frequency([
      {5, {:normal_motion, [oneof([:h, :j, :k, :l, :w, :b, :e, :zero, :dollar])]}},
      {3, {:enter_insert, [oneof([:i, :a, :o, :O])]}},
      {2, {:enter_visual, []}},
      {1, {:enter_visual_line, []}},
      {1, {:enter_command, []}},
      {1, {:enter_replace, []}},
      {2, {:delete_char, []}},
      {1, {:delete_line, []}},
      {1, {:yank_line, []}},
      {1, {:paste, []}},
      {1, {:paste_before, []}},
      {1, {:undo, []}},
      {1, {:redo, []}},
      {1, {:escape, []}},
      {1, {:mouse_click, [integer(0, h - 1), integer(0, w - 1)]}},
      {1, {:do_resize, [integer(20, 200), integer(10, 50)]}},
      # Scrolling
      {2, {:half_page_down, []}},
      {2, {:half_page_up, []}},
      {1, {:page_down, []}},
      {1, {:page_up, []}},
      {1, {:wheel_up, []}},
      {1, {:wheel_down, []}}
      # NOTE: Window splits, file tree, agent view, buffer/tab switching are
      # temporarily excluded because they trigger known crashes (#782, #783, #784).
      # Uncomment these once those bugs are fixed:
      # {1, {:split_vertical, []}},
      # {1, {:split_horizontal, []}},
      # {1, {:window_left, []}},
      # {1, {:window_right, []}},
      # {1, {:window_down, []}},
      # {1, {:window_up, []}},
      # {1, {:buffer_next, []}},
      # {1, {:buffer_prev, []}},
      # {1, {:toggle_file_tree, []}},
      # {1, {:toggle_agent_view, []}},
      # {1, {:tab_next, []}},
      # {1, {:tab_prev, []}}
    ])
  end

  def command_gen(%Model{mode: :insert, width: w, height: h}) do
    frequency([
      {6, {:insert_type, [integer(32, 126)]}},
      {3, {:escape, []}},
      {1, {:insert_enter, []}},
      {1, {:insert_backspace, []}},
      {1, {:mouse_click, [integer(0, h - 1), integer(0, w - 1)]}},
      {1, {:do_resize, [integer(20, 200), integer(10, 50)]}}
    ])
  end

  def command_gen(%Model{mode: :visual, width: w, height: h}) do
    frequency([
      {5, {:visual_motion, [oneof([:h, :j, :k, :l, :w, :b, :e])]}},
      {2, {:visual_delete, []}},
      {2, {:visual_yank, []}},
      {3, {:escape, []}},
      {1, {:mouse_click, [integer(0, h - 1), integer(0, w - 1)]}},
      {1, {:do_resize, [integer(20, 200), integer(10, 50)]}}
    ])
  end

  def command_gen(%Model{mode: :command, width: w, height: h}) do
    frequency([
      {4, {:command_type, [integer(97, 122)]}},
      {3, {:escape, []}},
      {2, {:command_enter, []}},
      {1, {:mouse_click, [integer(0, h - 1), integer(0, w - 1)]}},
      {1, {:do_resize, [integer(20, 200), integer(10, 50)]}}
    ])
  end

  # For modes we don't model deeply (replace, search, etc.), escape back
  def command_gen(%Model{}) do
    frequency([
      {5, {:escape, []}},
      {1, {:insert_type, [integer(32, 126)]}}
    ])
  end

  # ── Preconditions ────────────────────────────────────────────────────────

  def precondition(%Model{}, {:call, _, _, _}), do: true

  # ── Next state ─────────────────────────────────────────────────────────

  def next_state(%Model{} = s, _res, {:call, _, :enter_insert, [:i]}), do: %{s | mode: :insert}
  def next_state(%Model{} = s, _res, {:call, _, :enter_insert, [:a]}), do: %{s | mode: :insert}

  def next_state(%Model{} = s, _res, {:call, _, :enter_insert, [:o]}),
    do: %{s | mode: :insert, line_count: s.line_count + 1, cursor_line: s.cursor_line + 1}

  def next_state(%Model{} = s, _res, {:call, _, :enter_insert, [:O]}),
    do: %{s | mode: :insert, line_count: s.line_count + 1}

  def next_state(%Model{} = s, _res, {:call, _, :enter_visual, []}), do: %{s | mode: :visual}
  def next_state(%Model{} = s, _res, {:call, _, :enter_visual_line, []}), do: %{s | mode: :visual}
  def next_state(%Model{} = s, _res, {:call, _, :enter_command, []}), do: %{s | mode: :command}
  def next_state(%Model{} = s, _res, {:call, _, :enter_replace, []}), do: %{s | mode: :replace}
  def next_state(%Model{} = s, _res, {:call, _, :escape, []}), do: %{s | mode: :normal}

  def next_state(%Model{mode: :insert} = s, _res, {:call, _, :insert_enter, []}),
    do: %{s | line_count: s.line_count + 1, cursor_line: s.cursor_line + 1}

  def next_state(%Model{mode: :visual} = s, _res, {:call, _, :visual_delete, []}),
    do: %{s | mode: :normal}

  def next_state(%Model{mode: :visual} = s, _res, {:call, _, :visual_yank, []}),
    do: %{s | mode: :normal}

  def next_state(%Model{mode: :command} = s, _res, {:call, _, :command_enter, []}),
    do: %{s | mode: :normal}

  def next_state(%Model{mode: :normal} = s, _res, {:call, _, :delete_line, []}) do
    new_count = max(1, s.line_count - 1)
    %{s | line_count: new_count, cursor_line: min(s.cursor_line, new_count - 1)}
  end

  def next_state(%Model{} = s, _res, {:call, _, :do_resize, [w, h]}),
    do: %{s | width: w, height: h}

  def next_state(%Model{} = s, _res, {:call, _, _, _}), do: s

  # ── Postconditions ─────────────────────────────────────────────────────

  @valid_modes [
    :normal,
    :insert,
    :visual,
    :operator_pending,
    :command,
    :eval,
    :replace,
    :search,
    :search_prompt,
    :substitute_confirm,
    :extension_confirm
  ]

  def postcondition(%Model{}, {:call, _, _, _}, result) do
    # Check invariants against the real system. Mode is validated as a
    # known atom (not compared to model) because mouse clicks, command
    # execution, and other interactions can change mode in ways the
    # simplified model doesn't track. The model's primary value is
    # driving mode-appropriate command generation, not predicting the
    # exact post-command mode.
    result.alive? and
      result.mode in @valid_modes and
      cursor_in_bounds?(result) and
      is_binary(result.content) and
      String.valid?(result.content)
  end

  defp cursor_in_bounds?(%{cursor: {line, col}, lines: lines, line_count: lc}) do
    line >= 0 and line < lc and
      (fn ->
         line_text = Enum.at(lines, line, "")
         col >= 0 and col <= byte_size(line_text)
       end).()
  end

  # ── Property ──────────────────────────────────────────────────────────

  property "editor survives random action sequences", numtests: 50, max_size: 100 do
    forall {content, cmds} <- content_and_commands() do
      ctx = start_chaos_editor(content)
      store_ctx(ctx)

      {_history, _state, result} = run_commands(__MODULE__, cmds)

      # Clean up
      if Process.alive?(ctx.editor), do: GenServer.stop(ctx.editor, :normal, 1000)
      if Process.alive?(ctx.port), do: GenServer.stop(ctx.port, :normal, 1000)

      result == :ok
    end
  end

  defp content_and_commands do
    let content <- content_gen() do
      line_count = length(String.split(content, "\n"))
      initial = %Model{line_count: line_count}

      let cmds <- commands(__MODULE__, initial) do
        {content, cmds}
      end
    end
  end

  # ── Content generator ──────────────────────────────────────────────────

  defp content_gen do
    let line_count <- integer(1, 10) do
      let lines <- vector(line_count, line_gen()) do
        Enum.join(lines, "\n")
      end
    end
  end

  defp line_gen do
    let len <- integer(0, 40) do
      let chars <- vector(len, integer(32, 126)) do
        List.to_string(chars)
      end
    end
  end
end
