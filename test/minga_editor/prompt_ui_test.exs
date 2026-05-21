defmodule MingaEditor.PromptUITest do
  use ExUnit.Case, async: true

  alias MingaEditor.PromptUI
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.Prompt, as: PromptState
  alias MingaEditor.Viewport

  # Test handlers record their callbacks via the test process dictionary.
  # The state passed in/out is the editor state; the side channel keeps
  # the assertions simple while letting the modal flow stay realistic.
  defmodule TestHandler do
    @behaviour MingaEditor.UI.Prompt.Handler

    @impl true
    def label, do: "Test prompt: "

    @impl true
    def on_submit(text, state) do
      Process.put(:submitted, text)
      state
    end

    @impl true
    def on_cancel(state) do
      Process.put(:cancelled, true)
      state
    end
  end

  defmodule RenameHandler do
    @behaviour MingaEditor.UI.Prompt.Handler

    @impl true
    def label, do: "Rename to: "

    @impl true
    def on_submit(text, state) do
      Process.put(:new_name, text)
      state
    end

    @impl true
    def on_cancel(state), do: state
  end

  @escape 27
  @enter 13
  @backspace 127
  @delete 57_348

  defp base_state do
    %EditorState{
      port_manager: nil,
      workspace: %MingaEditor.Session.State{viewport: Viewport.new(24, 80)}
    }
  end

  defp prompt_state(state) do
    case state.shell_state.modal do
      {:prompt, %{prompt_ui: pui}} -> pui
      _ -> %PromptState{}
    end
  end

  defp set_cursor(state, cursor) do
    pui = %{prompt_state(state) | cursor: cursor}
    PromptUI.update_prompt(state, fn _ -> pui end)
  end

  describe "open/3" do
    test "sets handler, label, and empty text" do
      state = base_state() |> PromptUI.open(TestHandler)
      pui = prompt_state(state)

      assert pui.handler == TestHandler
      assert pui.label == "Test prompt: "
      assert pui.text == ""
      assert pui.cursor == 0
    end

    test "sets default text when provided" do
      state = base_state() |> PromptUI.open(RenameHandler, default: "old_name")
      pui = prompt_state(state)

      assert pui.text == "old_name"
      assert pui.cursor == 8
    end

    test "stores context when provided" do
      state = base_state() |> PromptUI.open(TestHandler, context: %{template: "todo"})
      assert prompt_state(state).context == %{template: "todo"}
    end

    test "replaces an active picker via the gate's replacement policy" do
      alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload

      picker_struct = %MingaEditor.State.Picker{
        picker: %MingaEditor.UI.Picker{
          items: [],
          filtered: [],
          selected: 0,
          query: "",
          title: "Test"
        },
        source: SomeSource
      }

      state =
        base_state()
        |> ModalOverlay.open(:picker, PickerPayload.new(picker_struct))
        |> PromptUI.open(TestHandler)

      assert prompt_state(state).handler == TestHandler
      refute ModalOverlay.match(state.shell_state.modal, :picker)
    end
  end

  describe "open?/1" do
    test "returns false when no prompt is active" do
      refute PromptUI.open?(base_state())
    end

    test "returns true when prompt is active" do
      assert base_state() |> PromptUI.open(TestHandler) |> PromptUI.open?()
    end
  end

  describe "handle_key/3 — text insertion" do
    test "inserts a character" do
      state = base_state() |> PromptUI.open(TestHandler)
      {state, nil} = PromptUI.handle_key(state, ?h, 0)
      {state, nil} = PromptUI.handle_key(state, ?i, 0)

      pui = prompt_state(state)
      assert pui.text == "hi"
      assert pui.cursor == 2
    end

    test "inserts at cursor position" do
      state = base_state() |> PromptUI.open(TestHandler, default: "ac")
      # Move cursor left once (between a and c)
      {state, nil} = PromptUI.handle_key(state, 57_350, 0)
      # Insert 'b' at position 1
      {state, nil} = PromptUI.handle_key(state, ?b, 0)

      pui = prompt_state(state)
      assert pui.text == "abc"
      assert pui.cursor == 2
    end

    test "handles unicode characters" do
      state = base_state() |> PromptUI.open(TestHandler)
      {state, nil} = PromptUI.handle_key(state, 0x1F600, 0)

      pui = prompt_state(state)
      assert pui.text == "😀"
      assert pui.cursor == 1
    end
  end

  describe "handle_key/3 — backspace" do
    test "deletes character before cursor" do
      state = base_state() |> PromptUI.open(TestHandler, default: "abc")
      {state, nil} = PromptUI.handle_key(state, @backspace, 0)

      pui = prompt_state(state)
      assert pui.text == "ab"
      assert pui.cursor == 2
    end

    test "does nothing at start of text" do
      state =
        base_state()
        |> PromptUI.open(TestHandler, default: "abc")
        |> set_cursor(0)

      {state, nil} = PromptUI.handle_key(state, @backspace, 0)

      pui = prompt_state(state)
      assert pui.text == "abc"
      assert pui.cursor == 0
    end
  end

  describe "handle_key/3 — cursor movement" do
    test "arrow left moves cursor left" do
      state = base_state() |> PromptUI.open(TestHandler, default: "abc")
      assert prompt_state(state).cursor == 3

      {state, nil} = PromptUI.handle_key(state, 57_350, 0)
      assert prompt_state(state).cursor == 2
    end

    test "arrow left stops at 0" do
      state =
        base_state()
        |> PromptUI.open(TestHandler, default: "a")
        |> set_cursor(0)

      {state, nil} = PromptUI.handle_key(state, 57_350, 0)
      assert prompt_state(state).cursor == 0
    end

    test "arrow right moves cursor right" do
      state =
        base_state()
        |> PromptUI.open(TestHandler, default: "abc")
        |> set_cursor(1)

      {state, nil} = PromptUI.handle_key(state, 57_351, 0)
      assert prompt_state(state).cursor == 2
    end

    test "arrow right stops at end of text" do
      state = base_state() |> PromptUI.open(TestHandler, default: "abc")
      {state, nil} = PromptUI.handle_key(state, 57_351, 0)
      assert prompt_state(state).cursor == 3
    end
  end

  describe "handle_key/3 — submit" do
    test "Enter calls on_submit with the text and closes prompt" do
      state = base_state() |> PromptUI.open(TestHandler, default: "hello world")
      {state, nil} = PromptUI.handle_key(state, @enter, 0)

      assert Process.get(:submitted) == "hello world"
      refute PromptUI.open?(state)
    end

    test "Enter submits empty text when no input given" do
      state = base_state() |> PromptUI.open(TestHandler)
      {state, nil} = PromptUI.handle_key(state, @enter, 0)

      assert Process.get(:submitted) == ""
      refute PromptUI.open?(state)
    end
  end

  describe "handle_key/3 — cancel" do
    test "Escape calls on_cancel and closes prompt" do
      state = base_state() |> PromptUI.open(TestHandler, default: "draft")
      {state, nil} = PromptUI.handle_key(state, @escape, 0)

      assert Process.get(:cancelled) == true
      refute PromptUI.open?(state)
    end
  end

  describe "render_data/1" do
    test "returns label, text, and cursor position" do
      state = base_state() |> PromptUI.open(TestHandler, default: "hello")
      {label, text, cursor} = PromptUI.render_data(state)

      assert label == "Test prompt: "
      assert text == "hello"
      assert cursor == 5
    end
  end

  describe "close/1" do
    test "clears prompt state" do
      state =
        base_state()
        |> PromptUI.open(TestHandler, default: "hello")
        |> PromptUI.close()

      refute PromptUI.open?(state)
      assert state.shell_state.modal == :none
    end
  end

  describe "handle_key/3 — delete (forward)" do
    test "removes character after cursor" do
      state =
        base_state()
        |> PromptUI.open(TestHandler, default: "abc")
        |> set_cursor(0)

      {state, nil} = PromptUI.handle_key(state, @delete, 0)

      pui = prompt_state(state)
      assert pui.text == "bc"
      assert pui.cursor == 0
    end

    test "does nothing at end of text" do
      state = base_state() |> PromptUI.open(TestHandler, default: "abc")
      # cursor is at 3 (end)
      {state, nil} = PromptUI.handle_key(state, @delete, 0)

      pui = prompt_state(state)
      assert pui.text == "abc"
      assert pui.cursor == 3
    end

    test "deletes in middle of text" do
      state =
        base_state()
        |> PromptUI.open(TestHandler, default: "abc")
        |> set_cursor(1)

      {state, nil} = PromptUI.handle_key(state, @delete, 0)

      pui = prompt_state(state)
      assert pui.text == "ac"
      assert pui.cursor == 1
    end
  end

  describe "handle_key/3 — edge cases" do
    test "control characters are ignored" do
      state = base_state() |> PromptUI.open(TestHandler)
      {state, nil} = PromptUI.handle_key(state, 0x01, 0)

      assert prompt_state(state).text == ""
    end

    test "surrogate codepoints are ignored" do
      state = base_state() |> PromptUI.open(TestHandler)
      {state, nil} = PromptUI.handle_key(state, 0xD800, 0)

      assert prompt_state(state).text == ""
    end

    test "backspace on multi-byte unicode deletes one grapheme" do
      state =
        base_state()
        |> PromptUI.open(TestHandler, default: "a😀b")
        # cursor at 3 (end), move back once to position 2 (after 😀)
        |> set_cursor(2)

      {state, nil} = PromptUI.handle_key(state, @backspace, 0)

      pui = prompt_state(state)
      assert pui.text == "ab"
      assert pui.cursor == 1
    end

    test "inserting at position 0 prepends to text" do
      state =
        base_state()
        |> PromptUI.open(TestHandler, default: "bc")
        |> set_cursor(0)

      {state, nil} = PromptUI.handle_key(state, ?a, 0)

      pui = prompt_state(state)
      assert pui.text == "abc"
      assert pui.cursor == 1
    end
  end

  describe "composability — picker then prompt" do
    test "on_select can open a prompt for multi-step flow" do
      # Simulate: picker selects a template, then prompt opens for title input
      # Step 1: open prompt with empty default (simulating a picker's on_select)
      state = base_state() |> PromptUI.open(RenameHandler)

      # Step 2: type new name
      state =
        Enum.reduce(String.to_charlist("NewName"), state, fn char, acc ->
          {new_state, nil} = PromptUI.handle_key(acc, char, 0)
          new_state
        end)

      # Step 3: submit
      {state, nil} = PromptUI.handle_key(state, @enter, 0)

      assert Process.get(:new_name) == "NewName"
      refute PromptUI.open?(state)
    end
  end
end
