defmodule Minga.Editor.PromptUITest do
  use ExUnit.Case, async: true

  alias Minga.Editor.PromptUI
  alias Minga.Editor.State.Prompt, as: PromptState

  # Test handler that records what happened
  defmodule TestHandler do
    @behaviour Minga.UI.Prompt.Handler

    @impl true
    def label, do: "Test prompt: "

    @impl true
    def on_submit(text, state) do
      put_in(state[:submitted], text)
    end

    @impl true
    def on_cancel(state) do
      put_in(state[:cancelled], true)
    end
  end

  defmodule RenameHandler do
    @behaviour Minga.UI.Prompt.Handler

    @impl true
    def label, do: "Rename to: "

    @impl true
    def on_submit(text, state) do
      put_in(state[:new_name], text)
    end

    @impl true
    def on_cancel(state), do: state
  end

  @escape 27
  @enter 13
  @backspace 127
  @delete 57_348

  defp make_state(overrides \\ %{}) do
    shell_overrides = Map.take(overrides, [:prompt_ui, :picker_ui])
    other_overrides = Map.drop(overrides, [:prompt_ui, :picker_ui])

    shell = %Minga.Shell.Traditional.State{
      prompt_ui: Map.get(shell_overrides, :prompt_ui, %PromptState{}),
      picker_ui: Map.get(shell_overrides, :picker_ui, %Minga.Editor.State.Picker{})
    }

    base = %{
      shell_state: shell,
      submitted: nil,
      cancelled: nil,
      new_name: nil
    }

    Map.merge(base, other_overrides)
  end

  describe "open/3" do
    test "sets handler, label, and empty text" do
      state = make_state()
      state = PromptUI.open(state, TestHandler)

      assert state.shell_state.prompt_ui.handler == TestHandler
      assert state.shell_state.prompt_ui.label == "Test prompt: "
      assert state.shell_state.prompt_ui.text == ""
      assert state.shell_state.prompt_ui.cursor == 0
    end

    test "sets default text when provided" do
      state = make_state()
      state = PromptUI.open(state, RenameHandler, default: "old_name")

      assert state.shell_state.prompt_ui.text == "old_name"
      assert state.shell_state.prompt_ui.cursor == 8
    end

    test "stores context when provided" do
      state = make_state()
      state = PromptUI.open(state, TestHandler, context: %{template: "todo"})

      assert state.shell_state.prompt_ui.context == %{template: "todo"}
    end

    test "closes active picker when opening prompt" do
      picker_state = %Minga.Editor.State.Picker{
        picker: %Minga.UI.Picker{items: [], filtered: [], selected: 0, query: "", title: "Test"},
        source: SomeSource
      }

      state = make_state(%{picker_ui: picker_state})
      state = PromptUI.open(state, TestHandler)

      assert state.shell_state.prompt_ui.handler == TestHandler
      assert state.shell_state.picker_ui.picker == nil
    end
  end

  describe "open?/1" do
    test "returns false when no prompt is active" do
      state = make_state()
      refute PromptUI.open?(state)
    end

    test "returns true when prompt is active" do
      state = make_state() |> PromptUI.open(TestHandler)
      assert PromptUI.open?(state)
    end
  end

  describe "handle_key/3 — text insertion" do
    test "inserts a character" do
      state = make_state() |> PromptUI.open(TestHandler)
      {state, nil} = PromptUI.handle_key(state, ?h, 0)
      {state, nil} = PromptUI.handle_key(state, ?i, 0)

      assert state.shell_state.prompt_ui.text == "hi"
      assert state.shell_state.prompt_ui.cursor == 2
    end

    test "inserts at cursor position" do
      state = make_state() |> PromptUI.open(TestHandler, default: "ac")
      # Move cursor left once (between a and c)
      {state, nil} = PromptUI.handle_key(state, 57_350, 0)
      # Insert 'b' at position 1
      {state, nil} = PromptUI.handle_key(state, ?b, 0)

      assert state.shell_state.prompt_ui.text == "abc"
      assert state.shell_state.prompt_ui.cursor == 2
    end

    test "handles unicode characters" do
      state = make_state() |> PromptUI.open(TestHandler)
      {state, nil} = PromptUI.handle_key(state, 0x1F600, 0)

      assert state.shell_state.prompt_ui.text == "😀"
      assert state.shell_state.prompt_ui.cursor == 1
    end
  end

  describe "handle_key/3 — backspace" do
    test "deletes character before cursor" do
      state = make_state() |> PromptUI.open(TestHandler, default: "abc")
      {state, nil} = PromptUI.handle_key(state, @backspace, 0)

      assert state.shell_state.prompt_ui.text == "ab"
      assert state.shell_state.prompt_ui.cursor == 2
    end

    test "does nothing at start of text" do
      state = make_state() |> PromptUI.open(TestHandler, default: "abc")
      # Move to start
      state = Minga.Editor.State.set_prompt_ui(state, %{state.shell_state.prompt_ui | cursor: 0})
      {state, nil} = PromptUI.handle_key(state, @backspace, 0)

      assert state.shell_state.prompt_ui.text == "abc"
      assert state.shell_state.prompt_ui.cursor == 0
    end
  end

  describe "handle_key/3 — cursor movement" do
    test "arrow left moves cursor left" do
      state = make_state() |> PromptUI.open(TestHandler, default: "abc")
      assert state.shell_state.prompt_ui.cursor == 3

      {state, nil} = PromptUI.handle_key(state, 57_350, 0)
      assert state.shell_state.prompt_ui.cursor == 2
    end

    test "arrow left stops at 0" do
      state = make_state() |> PromptUI.open(TestHandler, default: "a")
      state = Minga.Editor.State.set_prompt_ui(state, %{state.shell_state.prompt_ui | cursor: 0})
      {state, nil} = PromptUI.handle_key(state, 57_350, 0)
      assert state.shell_state.prompt_ui.cursor == 0
    end

    test "arrow right moves cursor right" do
      state = make_state() |> PromptUI.open(TestHandler, default: "abc")
      state = Minga.Editor.State.set_prompt_ui(state, %{state.shell_state.prompt_ui | cursor: 1})
      {state, nil} = PromptUI.handle_key(state, 57_351, 0)
      assert state.shell_state.prompt_ui.cursor == 2
    end

    test "arrow right stops at end of text" do
      state = make_state() |> PromptUI.open(TestHandler, default: "abc")
      {state, nil} = PromptUI.handle_key(state, 57_351, 0)
      assert state.shell_state.prompt_ui.cursor == 3
    end
  end

  describe "handle_key/3 — submit" do
    test "Enter calls on_submit with the text and closes prompt" do
      state = make_state() |> PromptUI.open(TestHandler, default: "hello world")
      {state, nil} = PromptUI.handle_key(state, @enter, 0)

      assert state.submitted == "hello world"
      refute PromptUI.open?(state)
    end

    test "Enter submits empty text when no input given" do
      state = make_state() |> PromptUI.open(TestHandler)
      {state, nil} = PromptUI.handle_key(state, @enter, 0)

      assert state.submitted == ""
      refute PromptUI.open?(state)
    end
  end

  describe "handle_key/3 — cancel" do
    test "Escape calls on_cancel and closes prompt" do
      state = make_state() |> PromptUI.open(TestHandler, default: "draft")
      {state, nil} = PromptUI.handle_key(state, @escape, 0)

      assert state.cancelled == true
      refute PromptUI.open?(state)
    end
  end

  describe "render_data/1" do
    test "returns label, text, and cursor position" do
      state = make_state() |> PromptUI.open(TestHandler, default: "hello")
      {label, text, cursor} = PromptUI.render_data(state)

      assert label == "Test prompt: "
      assert text == "hello"
      assert cursor == 5
    end
  end

  describe "close/1" do
    test "clears prompt state" do
      state = make_state() |> PromptUI.open(TestHandler, default: "hello")
      state = PromptUI.close(state)

      refute PromptUI.open?(state)
      assert state.shell_state.prompt_ui.handler == nil
      assert state.shell_state.prompt_ui.text == ""
    end
  end

  describe "handle_key/3 — delete (forward)" do
    test "removes character after cursor" do
      state = make_state() |> PromptUI.open(TestHandler, default: "abc")
      state = Minga.Editor.State.set_prompt_ui(state, %{state.shell_state.prompt_ui | cursor: 0})
      {state, nil} = PromptUI.handle_key(state, @delete, 0)

      assert state.shell_state.prompt_ui.text == "bc"
      assert state.shell_state.prompt_ui.cursor == 0
    end

    test "does nothing at end of text" do
      state = make_state() |> PromptUI.open(TestHandler, default: "abc")
      # cursor is at 3 (end)
      {state, nil} = PromptUI.handle_key(state, @delete, 0)

      assert state.shell_state.prompt_ui.text == "abc"
      assert state.shell_state.prompt_ui.cursor == 3
    end

    test "deletes in middle of text" do
      state = make_state() |> PromptUI.open(TestHandler, default: "abc")
      state = Minga.Editor.State.set_prompt_ui(state, %{state.shell_state.prompt_ui | cursor: 1})
      {state, nil} = PromptUI.handle_key(state, @delete, 0)

      assert state.shell_state.prompt_ui.text == "ac"
      assert state.shell_state.prompt_ui.cursor == 1
    end
  end

  describe "handle_key/3 — edge cases" do
    test "control characters are ignored" do
      state = make_state() |> PromptUI.open(TestHandler)
      {state, nil} = PromptUI.handle_key(state, 0x01, 0)

      assert state.shell_state.prompt_ui.text == ""
    end

    test "surrogate codepoints are ignored" do
      state = make_state() |> PromptUI.open(TestHandler)
      {state, nil} = PromptUI.handle_key(state, 0xD800, 0)

      assert state.shell_state.prompt_ui.text == ""
    end

    test "backspace on multi-byte unicode deletes one grapheme" do
      state = make_state() |> PromptUI.open(TestHandler, default: "a😀b")
      # cursor at 3 (end), move back once to position 2 (after 😀)
      state = Minga.Editor.State.set_prompt_ui(state, %{state.shell_state.prompt_ui | cursor: 2})
      {state, nil} = PromptUI.handle_key(state, @backspace, 0)

      assert state.shell_state.prompt_ui.text == "ab"
      assert state.shell_state.prompt_ui.cursor == 1
    end

    test "inserting at position 0 prepends to text" do
      state = make_state() |> PromptUI.open(TestHandler, default: "bc")
      state = Minga.Editor.State.set_prompt_ui(state, %{state.shell_state.prompt_ui | cursor: 0})
      {state, nil} = PromptUI.handle_key(state, ?a, 0)

      assert state.shell_state.prompt_ui.text == "abc"
      assert state.shell_state.prompt_ui.cursor == 1
    end
  end

  describe "composability — picker then prompt" do
    test "on_select can open a prompt for multi-step flow" do
      # Simulate: picker selects a template, then prompt opens for title input
      state = make_state()

      # Step 1: open prompt with empty default (simulating a picker's on_select)
      state = PromptUI.open(state, RenameHandler)

      # Step 2: type new name
      state =
        Enum.reduce(String.to_charlist("NewName"), state, fn char, acc ->
          {new_state, nil} = PromptUI.handle_key(acc, char, 0)
          new_state
        end)

      # Step 3: submit
      {state, nil} = PromptUI.handle_key(state, @enter, 0)

      assert state.new_name == "NewName"
      refute PromptUI.open?(state)
    end
  end
end
