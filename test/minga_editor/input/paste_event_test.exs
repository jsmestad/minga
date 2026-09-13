defmodule MingaEditor.Input.PasteEventTest do
  use Minga.Test.EditorCase, async: true, rendering: :disabled

  alias Minga.Buffer
  alias MingaEditor.BottomPanel
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Agent.PromptBuffer
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.PickerUI
  alias MingaEditor.PromptUI
  alias MingaEditor.Shell.Traditional.Workflow
  alias MingaEditor.UI.Picker.Item

  defmodule PromptHandler do
    @behaviour MingaEditor.UI.Prompt.Handler

    @impl true
    def label, do: "Input: "

    @impl true
    def on_submit(_text, state), do: state
  end

  defmodule PickerSource do
    @behaviour MingaEditor.UI.Picker.Source

    @impl true
    def title, do: "Test"

    @impl true
    def candidates(_context),
      do: [%Item{id: "alpha", label: "alpha"}, %Item{id: "beta", label: "beta"}]

    @impl true
    def on_select(_item, state), do: state
  end

  defmodule SidebarWithoutPaste do
    @behaviour MingaEditor.Input.Handler

    @impl true
    def handle_key(state, _codepoint, _modifiers), do: {:handled, state}
  end

  describe "document insertion" do
    test "inserts at line start, middle, and EOF without deleting adjacent text" do
      for {position, expected} <- [{{0, 0}, "Zabc"}, {{0, 1}, "aZbc"}, {{0, 3}, "abcZ"}] do
        ctx = start_editor("abc")
        Buffer.move_to(ctx.buffer, position)

        paste(ctx, "Z")

        assert Buffer.content(ctx.buffer) == expected
      end
    end

    test "inserts into an empty buffer and preserves a trailing newline" do
      empty = start_editor("")
      paste(empty, "Z")
      assert Buffer.content(empty.buffer) == "Z"

      trailing = start_editor("abc\n")
      Buffer.move_to(trailing.buffer, {1, 0})
      paste(trailing, "Z\n")
      assert Buffer.content(trailing.buffer) == "abc\nZ\n"
    end

    test "uses byte-positioned Unicode grapheme boundaries" do
      ctx = start_editor("a😀b")
      Buffer.move_to(ctx.buffer, {0, 1})

      paste(ctx, "é")

      assert Buffer.content(ctx.buffer) == "aé😀b"
      assert Buffer.cursor(ctx.buffer) == {0, 3}
    end

    test "empty input is an exact no-op" do
      ctx = start_editor("abc")
      Buffer.move_to(ctx.buffer, {0, 1})
      version = Buffer.version(ctx.buffer)

      paste(ctx, "")

      assert Buffer.content(ctx.buffer) == "abc"
      assert Buffer.cursor(ctx.buffer) == {0, 1}
      assert Buffer.version(ctx.buffer) == version
    end

    test "keeps Normal and Insert model transitions consistent" do
      normal = start_editor("abc")
      Buffer.move_to(normal.buffer, {0, 1})
      paste(normal, "Z")
      assert editor_mode(normal) == :normal

      insert = start_editor("abc")
      Buffer.move_to(insert.buffer, {0, 1})
      send_key_sync(insert, ?i)
      paste(insert, "Z")
      assert editor_mode(insert) == :insert
      send_key_sync(insert, ?Q)
      assert Buffer.content(insert.buffer) == "aZQbc"
      send_key_sync(insert, 27)
      assert editor_mode(insert) == :normal
      assert Buffer.cursor(insert.buffer) == {0, 2}
    end

    test "uses the shared decoded route for the terminal frontend" do
      ctx = start_editor("abc", backend: :tui)
      Buffer.move_to(ctx.buffer, {0, 1})

      paste(ctx, "Z")

      assert Buffer.content(ctx.buffer) == "aZbc"
    end
  end

  describe "selection replacement" do
    test "replaces a partial character selection and exits Visual mode" do
      ctx = start_editor("abcd")
      select(ctx, {0, 1}, {0, 2}, :char)

      paste(ctx, "Z")

      assert Buffer.content(ctx.buffer) == "aZd"
      assert editor_mode(ctx) == :normal
      assert Buffer.cursor(ctx.buffer) == {0, 2}
    end

    test "replaces a multiline character selection exactly" do
      ctx = start_editor("one\ntwo\nthree")
      select(ctx, {0, 1}, {1, 1}, :char)

      paste(ctx, "Z")

      assert Buffer.content(ctx.buffer) == "oZo\nthree"
      assert editor_mode(ctx) == :normal
    end

    test "replaces a reversed selection with multiline Unicode text" do
      ctx = start_editor("abcd")
      select(ctx, {0, 3}, {0, 1}, :char)

      paste(ctx, "😀\nβ")

      assert Buffer.content(ctx.buffer) == "a😀\nβ"
      assert editor_mode(ctx) == :normal
      assert Buffer.cursor(ctx.buffer) == {1, 2}
    end

    test "replaces a linewise selection without deleting surrounding lines" do
      ctx = start_editor("zero\none\ntwo\nthree")
      select(ctx, {1, 0}, {2, 0}, :line)

      paste(ctx, "Z")

      assert Buffer.content(ctx.buffer) == "zero\nZ\nthree"
      assert editor_mode(ctx) == :normal
      assert Buffer.cursor(ctx.buffer) == {1, 1}

      send_key_sync(ctx, ?i)
      send_key_sync(ctx, ?Q)

      assert Buffer.content(ctx.buffer) == "zero\nZQ\nthree"
    end

    test "does not duplicate the separator after a linewise replacement ending in newline" do
      ctx = start_editor("zero\none\nthree")
      select(ctx, {1, 0}, {1, 0}, :line)

      paste(ctx, "Z\n")

      assert Buffer.content(ctx.buffer) == "zero\nZ\nthree"
      assert editor_mode(ctx) == :normal
    end

    test "replaces a selected empty middle line without joining the following line" do
      ctx = start_editor("zero\n\nthree")
      select(ctx, {1, 0}, {1, 0}, :line)

      paste(ctx, "Z")

      assert Buffer.content(ctx.buffer) == "zero\nZ\nthree"
      assert editor_mode(ctx) == :normal
    end

    test "preserves the following line when the last selected line is empty" do
      ctx = start_editor("zero\none\n\nthree")
      select(ctx, {1, 0}, {2, 0}, :line)

      paste(ctx, "Z")

      assert Buffer.content(ctx.buffer) == "zero\nZ\nthree"
      assert editor_mode(ctx) == :normal
    end

    test "replaces reversed linewise selections with multiline Unicode text" do
      ctx = start_editor("zero\none\ntwo\nthree")
      select(ctx, {2, 0}, {1, 0}, :line)

      paste(ctx, "λ\nβ")

      assert Buffer.content(ctx.buffer) == "zero\nλ\nβ\nthree"
      assert editor_mode(ctx) == :normal
    end

    test "replaces a linewise selection at EOF without adding a separator" do
      without_newline = start_editor("zero\none")
      select(without_newline, {1, 0}, {1, 0}, :line)
      paste(without_newline, "Z")
      assert Buffer.content(without_newline.buffer) == "zero\nZ"

      with_newline = start_editor("zero\none")
      select(with_newline, {1, 0}, {1, 0}, :line)
      paste(with_newline, "Z\n")
      assert Buffer.content(with_newline.buffer) == "zero\nZ\n"
    end

    test "replaces an empty final line without changing the preceding separator" do
      ctx = start_editor("zero\n")
      select(ctx, {1, 0}, {1, 0}, :line)

      paste(ctx, "é")

      assert Buffer.content(ctx.buffer) == "zero\né"
      assert editor_mode(ctx) == :normal
    end

    test "select all replaces the whole document, including a trailing newline and Unicode" do
      ctx = start_editor("a😀b\n")
      :sys.replace_state(ctx.editor, &MingaEditor.Commands.execute(&1, :select_all))
      assert editor_mode(ctx) == :visual

      paste(ctx, "Z")

      assert Buffer.content(ctx.buffer) == "Z"
      assert editor_mode(ctx) == :normal
    end

    test "linewise selection in an empty buffer accepts replacement text" do
      ctx = start_editor("")
      select(ctx, {0, 0}, {0, 0}, :line)

      paste(ctx, "Z")

      assert Buffer.content(ctx.buffer) == "Z"
      assert editor_mode(ctx) == :normal
    end

    test "empty paste preserves the active selection" do
      ctx = start_editor("abc")
      select(ctx, {0, 0}, {0, 2}, :char)

      paste(ctx, "")

      assert Buffer.content(ctx.buffer) == "abc"
      assert Buffer.cursor(ctx.buffer) == {0, 2}
      assert editor_mode(ctx) == :visual
    end

    test "CUA select all uses the active selection and leaves a typing caret" do
      ctx = start_editor("abc", editing_model: :cua)
      send_key_sync(ctx, ?a, 0x08)
      assert editor_mode(ctx) == :visual

      paste(ctx, "Z")
      send_key_sync(ctx, ?Q)

      assert Buffer.content(ctx.buffer) == "ZQ"
      assert editor_mode(ctx) == :normal
    end

    test "read-only failure preserves content, cursor, and selection with no undo entry" do
      ctx = start_editor("abc")
      select(ctx, {0, 0}, {0, 2}, :char)
      Buffer.set_read_only(ctx.buffer, true)
      version = Buffer.version(ctx.buffer)

      paste(ctx, "Z")

      assert Buffer.content(ctx.buffer) == "abc"
      assert Buffer.cursor(ctx.buffer) == {0, 2}
      assert editor_mode(ctx) == :visual
      assert Buffer.version(ctx.buffer) == version
    end

    test "read-only failure preserves a linewise selection with no undo entry" do
      ctx = start_editor("zero\none\nthree")
      select(ctx, {1, 0}, {1, 0}, :line)
      Buffer.set_read_only(ctx.buffer, true)
      version = Buffer.version(ctx.buffer)

      paste(ctx, "Z\n")

      assert Buffer.content(ctx.buffer) == "zero\none\nthree"
      assert Buffer.cursor(ctx.buffer) == {1, 0}
      assert editor_mode(ctx) == :visual
      assert Buffer.version(ctx.buffer) == version
    end

    test "paste is one isolated Undo and Redo step" do
      ctx = start_editor("abcd")
      select(ctx, {0, 1}, {0, 2}, :char)

      paste(ctx, "XYZ")
      assert Buffer.content(ctx.buffer) == "aXYZd"

      assert Buffer.undo(ctx.buffer) == :ok
      assert Buffer.content(ctx.buffer) == "abcd"
      assert Buffer.cursor(ctx.buffer) == {0, 2}

      assert Buffer.redo(ctx.buffer) == :ok
      assert Buffer.content(ctx.buffer) == "aXYZd"
      assert Buffer.cursor(ctx.buffer) == {0, 4}
    end

    test "linewise paste is one isolated Undo and Redo step" do
      ctx = start_editor("zero\none\nthree")
      select(ctx, {1, 0}, {1, 0}, :line)

      paste(ctx, "Z\n")
      assert Buffer.content(ctx.buffer) == "zero\nZ\nthree"

      assert Buffer.undo(ctx.buffer) == :ok
      assert Buffer.content(ctx.buffer) == "zero\none\nthree"
      assert Buffer.cursor(ctx.buffer) == {1, 0}

      assert Buffer.redo(ctx.buffer) == :ok
      assert Buffer.content(ctx.buffer) == "zero\nZ\nthree"
      assert Buffer.cursor(ctx.buffer) == {2, 0}
    end
  end

  describe "focused input ownership" do
    test "command and search minibuffers receive paste without mutating the document" do
      command = start_editor("abc")
      send_key_sync(command, ?:)
      command_state = paste(command, "write")
      assert command_state.workspace.editing.mode_state.input == "write"
      assert Buffer.content(command.buffer) == "abc"

      search = start_editor("abc abc")
      send_key_sync(search, ?/)
      search_state = paste(search, "bc")
      assert search_state.workspace.editing.mode_state.input == "bc"
      assert Buffer.cursor(search.buffer) == {0, 1}
      assert Buffer.content(search.buffer) == "abc abc"
    end

    test "prompt and picker overlays receive paste without mutating the document" do
      prompt = start_editor("document")

      :sys.replace_state(prompt.editor, fn state ->
        PromptUI.open(state, PromptHandler, default: "ab")
      end)

      prompt_state = paste(prompt, "😀")
      {:prompt, %{prompt_ui: prompt_ui}} = prompt_state.shell_runtime.state.modal
      assert prompt_ui.text == "ab😀"
      assert prompt_ui.cursor == 3
      assert Buffer.content(prompt.buffer) == "document"

      picker = start_editor("document")
      :sys.replace_state(picker.editor, &PickerUI.open(&1, PickerSource))

      picker_state = paste(picker, "alp")
      {:picker, %{picker_ui: %{picker: picker_ui}}} = picker_state.shell_runtime.state.modal
      assert picker_ui.query == "alp"
      assert Buffer.content(picker.buffer) == "document"
    end

    test "agent prompt receives paste without mutating the document" do
      ctx = start_editor("document")

      :sys.replace_state(ctx.editor, fn state ->
        agent_ui =
          state.workspace.agent_ui |> PromptBuffer.set_input_focused(true) |> UIState.toggle()

        Workflow.install_agent_ui(state, agent_ui)
      end)

      state = paste(ctx, "hello")

      assert PromptBuffer.input_text(state.workspace.agent_ui) == "hello"
      assert Buffer.content(ctx.buffer) == "document"
    end

    test "focused bottom panel claims paste without mutating the background document" do
      ctx = start_editor("document")

      :sys.replace_state(ctx.editor, fn state ->
        panel =
          state.shell_runtime.state.bottom_panel |> BottomPanel.show() |> BottomPanel.focus()

        shell_state =
          MingaEditor.Shell.Traditional.State.install_bottom_panel(
            state.shell_runtime.state,
            panel
          )

        %{
          state
          | shell_runtime:
              MingaEditor.Shell.Runtime.install_traditional_state(
                state.shell_runtime,
                shell_state
              )
        }
      end)

      state = paste(ctx, "ignored")

      assert state.shell_runtime.state.bottom_panel.focused
      assert Buffer.content(ctx.buffer) == "document"
    end

    test "focused extension sidebar without paste support protects the background document" do
      ctx = start_editor("document")
      state = editor_state(ctx)
      table = state.extension_surfaces.sidebar_registry

      assert :ok =
               Sidebar.register(table, {:extension, :paste_test}, %{
                 id: "paste_test",
                 display_name: "Paste Test",
                 visible?: true,
                 focused?: true,
                 input_handler: SidebarWithoutPaste
               })

      paste(ctx, "ignored")

      assert Sidebar.get(table, "paste_test").focused?
      assert Buffer.content(ctx.buffer) == "document"
    end
  end

  defp paste(ctx, text) do
    payload = <<0x06, byte_size(text)::16, text::binary>>
    assert {:ok, event} = Protocol.decode_event(payload)
    send(ctx.editor, {:minga_input, event})
    editor_state(ctx)
  end

  defp select(ctx, anchor, cursor, :char) do
    Buffer.move_to(ctx.buffer, anchor)
    send_key_sync(ctx, ?v)
    Buffer.move_to(ctx.buffer, cursor)
  end

  defp select(ctx, anchor, cursor, :line) do
    Buffer.move_to(ctx.buffer, anchor)
    send_key_sync(ctx, ?V)
    Buffer.move_to(ctx.buffer, cursor)
  end
end
