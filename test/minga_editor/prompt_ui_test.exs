defmodule MingaEditor.PromptUITest do
  use ExUnit.Case, async: true

  alias MingaEditor.PromptUI
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Shell.Traditional.ModalWorkflow
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.Prompt, as: PromptState

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
  end

  defmodule SuccessorSubmitHandler do
    @behaviour MingaEditor.UI.Prompt.Handler

    @impl true
    def label, do: "Original: "

    @impl true
    def on_submit(text, state) do
      Process.put(:successor_submit_legacy_called, text)
      PromptUI.open(state, RenameHandler, label: "Next: ", default: text)
    end

    @impl true
    def on_submit(text, state, context) do
      Process.put(:successor_submit_context, context)

      Process.put(
        :successor_submit_modal_before_open,
        MingaEditor.Shell.Runtime.state(state.shell_runtime).modal
      )

      PromptUI.open(state, RenameHandler, label: "Next: ", default: "#{context.prefix}:#{text}")
    end
  end

  defmodule SuccessorCancelHandler do
    @behaviour MingaEditor.UI.Prompt.Handler

    @impl true
    def label, do: "Cancel: "

    @impl true
    def on_submit(_text, state), do: state

    @impl true
    def on_cancel(state) do
      Process.put(:successor_cancel_legacy_called, true)
      state
    end

    @impl true
    def on_cancel(state, context) do
      Process.put(:successor_cancel_context, context)

      Process.put(
        :successor_cancel_modal_before_open,
        MingaEditor.Shell.Runtime.state(state.shell_runtime).modal
      )

      PromptUI.open(state, RenameHandler, label: "Next: ", default: context.reason)
    end
  end

  defmodule TabHandler do
    @behaviour MingaEditor.UI.Prompt.Handler

    @impl true
    def label, do: "Complete: "

    @impl true
    def on_submit(_text, state), do: state

    @impl true
    def on_tab("query"), do: "a\u0301界"
    def on_tab(text), do: text
  end

  @escape 27
  @enter 13
  @backspace 127
  @tab 9
  @delete 57_348
  @arrow_left 57_350
  @arrow_right 57_351

  defp base_state do
    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: nil},
      workspace: %MingaEditor.Session.State{}
    }
  end

  defp prompt_state(state) do
    case MingaEditor.Shell.Runtime.state(state.shell_runtime).modal do
      {:prompt, %{prompt_ui: pui}} -> pui
      _ -> %PromptState{}
    end
  end

  defp move_left(state, count) do
    Enum.reduce(1..count//1, state, fn _, state ->
      {state, nil} = PromptUI.handle_key(state, @arrow_left, 0)
      state
    end)
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
        |> ModalWorkflow.open({:picker, PickerPayload.new(picker_struct)})
        |> PromptUI.open(TestHandler)

      assert prompt_state(state).handler == TestHandler

      refute ModalOverlay.match(
               MingaEditor.Shell.Runtime.state(state.shell_runtime).modal,
               :picker
             )
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
      {state, nil} = PromptUI.handle_key(state, @arrow_left, 0)
      # Insert 'b' at position 1
      {state, nil} = PromptUI.handle_key(state, ?b, 0)

      pui = prompt_state(state)
      assert pui.text == "abc"
      assert pui.cursor == 2
    end

    test "a key held with Control, Alt or Command types no letter" do
      state = base_state() |> PromptUI.open(TestHandler, default: "a")

      # Without enhanced key reporting a terminal sends Esc then f as Alt+f when both arrive together.
      for mods <- [0x02, 0x04, 0x08] do
        {kept, nil} = PromptUI.handle_key(state, ?f, mods)
        assert prompt_state(kept).text == "a"
      end

      {typed, nil} = PromptUI.handle_key(state, ?F, 0x01)
      assert prompt_state(typed).text == "aF"
    end

    test "handles unicode characters" do
      state = base_state() |> PromptUI.open(TestHandler)
      {state, nil} = PromptUI.handle_key(state, 0x1F600, 0)

      pui = prompt_state(state)
      assert pui.text == "😀"
      assert pui.cursor == 1
    end

    test "typing a combining mark advances the cursor even when it joins the preceding grapheme" do
      state = PromptUI.open(base_state(), TestHandler, default: "e")
      {joined, nil} = PromptUI.handle_key(state, 0x0301, 0)

      assert {"Test prompt: ", "e\u0301", 2} = PromptUI.render_data(joined)
      assert {^joined, nil} = PromptUI.handle_key(joined, @delete, 0)

      {moved, nil} = PromptUI.handle_key(joined, @arrow_right, 0)
      assert {"Test prompt: ", "e\u0301", 1} = PromptUI.render_data(moved)

      # An overshot cursor still appends, and backspace still removes the last grapheme.
      {appended, nil} = PromptUI.handle_key(joined, ?x, 0)
      assert {"Test prompt: ", "e\u0301x", 3} = PromptUI.render_data(appended)

      {joined_again, nil} = PromptUI.handle_key(appended, @backspace, 0)
      assert {"Test prompt: ", "e\u0301", 2} = PromptUI.render_data(joined_again)

      {empty, nil} = PromptUI.handle_key(joined_again, @backspace, 0)
      assert {"Test prompt: ", "", 1} = PromptUI.render_data(empty)

      {reset, nil} = PromptUI.handle_key(empty, @backspace, 0)
      assert {"Test prompt: ", "", 0} = PromptUI.render_data(reset)
    end
  end

  describe "handle_key/3 — a yes or no prompt" do
    defp confirm_prompt do
      prompt = PromptState.new(:confirm, TestHandler, "Delete? ", context: nil)

      ModalWorkflow.open(
        base_state(),
        {:prompt, MingaEditor.State.ModalOverlay.Prompt.new(prompt)}
      )
    end

    test "y answers yes and n answers no" do
      for key <- [?y, ?Y, ?n, ?N, @escape] do
        {answered, nil} = PromptUI.handle_key(confirm_prompt(), key, 0)
        refute PromptUI.open?(answered)
      end
    end

    test "a letter held with Control, Alt or Command is not an answer, and Esc still cancels" do
      for key <- [?y, ?n], mods <- [0x02, 0x04, 0x08] do
        {kept, nil} = PromptUI.handle_key(confirm_prompt(), key, mods)
        assert PromptUI.open?(kept)
      end

      {canceled, nil} = PromptUI.handle_key(confirm_prompt(), @escape, 0x04)
      refute PromptUI.open?(canceled)
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
        |> move_left(3)

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

      {state, nil} = PromptUI.handle_key(state, @arrow_left, 0)
      assert prompt_state(state).cursor == 2
    end

    test "arrow left stops at 0" do
      state =
        base_state()
        |> PromptUI.open(TestHandler, default: "a")
        |> move_left(1)

      {state, nil} = PromptUI.handle_key(state, @arrow_left, 0)
      assert prompt_state(state).cursor == 0
    end

    test "arrow right moves cursor right" do
      state =
        base_state()
        |> PromptUI.open(TestHandler, default: "abc")
        |> move_left(2)

      {state, nil} = PromptUI.handle_key(state, @arrow_right, 0)
      assert prompt_state(state).cursor == 2
    end

    test "arrow right stops at end of text" do
      state = base_state() |> PromptUI.open(TestHandler, default: "abc")
      {state, nil} = PromptUI.handle_key(state, @arrow_right, 0)
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

    test "Enter closes before context-aware submit and preserves successor prompt" do
      state =
        base_state()
        |> PromptUI.open(SuccessorSubmitHandler, default: "value", context: %{prefix: "ctx"})

      {state, nil} = PromptUI.handle_key(state, @enter, 0)
      pui = prompt_state(state)

      assert Process.get(:successor_submit_context) == %{prefix: "ctx"}
      assert Process.get(:successor_submit_modal_before_open) == :none
      refute Process.get(:successor_submit_legacy_called)
      assert pui.handler == RenameHandler
      assert pui.label == "Next: "
      assert pui.text == "ctx:value"
    end

    test "ProjectRemoveConfirm uses captured context after prompt is closed" do
      state =
        MingaEditor.UI.Prompt.ProjectRemoveConfirm.on_submit("yes", base_state(), %{
          path: "/tmp/project"
        })

      assert state.shell_runtime.state.notice.message == "Removed project: /tmp/project"
    end
  end

  describe "handle_key/3 — cancel" do
    test "Escape calls on_cancel and closes prompt" do
      state = base_state() |> PromptUI.open(TestHandler, default: "draft")
      {state, nil} = PromptUI.handle_key(state, @escape, 0)

      assert Process.get(:cancelled) == true
      refute PromptUI.open?(state)
    end

    test "Escape without on_cancel closes as identity fallback" do
      opened = base_state() |> PromptUI.open(RenameHandler, default: "draft")
      {actual, nil} = PromptUI.handle_key(opened, @escape, 0)

      assert actual == PromptUI.close(opened)
      refute PromptUI.open?(actual)
    end

    test "Escape dismisses before context-aware cancel and preserves successor prompt" do
      state =
        base_state()
        |> PromptUI.open(SuccessorCancelHandler, default: "draft", context: %{reason: "retry"})

      {state, nil} = PromptUI.handle_key(state, @escape, 0)
      pui = prompt_state(state)

      assert Process.get(:successor_cancel_context) == %{reason: "retry"}
      assert Process.get(:successor_cancel_modal_before_open) == :none
      refute Process.get(:successor_cancel_legacy_called)
      assert pui.handler == RenameHandler
      assert pui.label == "Next: "
      assert pui.text == "retry"
    end
  end

  describe "handle_key/3 — tab completion" do
    test "Tab installs the replacement at its grapheme end without reopening the prompt" do
      state =
        base_state()
        |> PromptUI.open(TabHandler, default: "query")
        |> move_left(4)

      generation = prompt_state(state).generation
      {completed, nil} = PromptUI.handle_key(state, @tab, 0)

      assert {"Complete: ", "a\u0301界", 2} = PromptUI.render_data(completed)
      assert prompt_state(completed).generation == generation
    end

    test "Tab is a no-op with no callback or an unchanged result" do
      for handler <- [TestHandler, TabHandler] do
        state =
          base_state()
          |> PromptUI.open(handler, default: "same")
          |> move_left(2)

        assert {^state, nil} = PromptUI.handle_key(state, @tab, 0)
      end
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

  describe "sensitive prompt input" do
    test "retained render frames and diagnostics exclude private input and callback context" do
      secret = "synthetic-private-key-3450"
      private_context = "synthetic-private-context-3450"

      state =
        PromptUI.open(base_state(), TestHandler,
          label: "Private key: ",
          sensitive: true,
          default: secret,
          context: %{private: private_context}
        )

      frame = MingaEditor.RenderPipeline.FrameIntent.from_editor_state(state)
      encoded = :erlang.term_to_binary(frame)
      diagnostic = inspect(state.shell_runtime, limit: :infinity)

      for private <- [secret, private_context] do
        assert :binary.match(encoded, private) == :nomatch
        refute diagnostic =~ private
      end

      {:prompt, payload} = frame.shell_state.modal

      assert MingaEditor.State.Prompt.render_data(payload.prompt_ui) ==
               {"Private key: ", String.duplicate("•", String.length(secret)),
                String.length(secret)}

      {_state, nil} = PromptUI.handle_key(state, @enter, 0)
      assert Process.get(:submitted) == secret
    end

    test "masked presentation preserves editable Unicode and submits the original value" do
      state =
        base_state()
        |> PromptUI.open(TestHandler, sensitive: true, default: "á界")

      assert {"Test prompt: ", "••", 2} = PromptUI.render_data(state)
      {state, nil} = PromptUI.handle_key(state, @arrow_left, 0)
      state = PromptUI.insert_text(state, "x")
      assert {"Test prompt: ", "•••", 2} = PromptUI.render_data(state)

      {state, nil} = PromptUI.handle_key(state, @enter, 0)
      assert Process.get(:submitted) == "áx界"
      refute PromptUI.open?(state)
      refute PromptUI.sensitive_input?(state)
      assert {"", "", 0} = PromptUI.render_data(state)
    end

    test "secret keys and the closing key stay out of lossage while ordinary keys remain visible" do
      for closing_key <- [@enter, @escape] do
        Process.delete(:submitted)
        Process.delete(:cancelled)

        state =
          base_state()
          |> PromptUI.open(TestHandler, sensitive: true)
          |> MingaEditor.Input.Router.route_key(?k, 0)
          |> MingaEditor.Input.Router.route_key(?e, 0)
          |> MingaEditor.Input.Router.route_key(?y, 0)

        assert {"Test prompt: ", "•••", 3} = PromptUI.render_data(state)
        state = MingaEditor.Input.Router.route_key(state, closing_key, 0)
        refute PromptUI.open?(state)
        assert MingaEditor.KeystrokeHistory.entries(state.interaction.keystroke_history) == []

        case closing_key do
          @enter ->
            assert Process.get(:submitted) == "key"

          @escape ->
            assert Process.get(:cancelled)
            refute Process.get(:submitted)
        end

        state = MingaEditor.Input.Router.route_key(state, @escape, 0)

        assert [%{key: {@escape, 0}}] =
                 MingaEditor.KeystrokeHistory.entries(state.interaction.keystroke_history)
      end
    end
  end

  describe "close/1" do
    test "clears prompt state" do
      state =
        base_state()
        |> PromptUI.open(TestHandler, default: "hello")
        |> PromptUI.close()

      refute PromptUI.open?(state)
      assert MingaEditor.Shell.Runtime.state(state.shell_runtime).modal == :none
    end
  end

  describe "handle_key/3 — delete (forward)" do
    test "removes character after cursor" do
      state =
        base_state()
        |> PromptUI.open(TestHandler, default: "abc")
        |> move_left(3)

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
        |> move_left(2)

      {state, nil} = PromptUI.handle_key(state, @delete, 0)

      pui = prompt_state(state)
      assert pui.text == "ac"
      assert pui.cursor == 1
    end
  end

  describe "handle_key/3 — edge cases" do
    test "control keys and non-scalar codepoints outside the special keys are ignored" do
      state = PromptUI.open(base_state(), TestHandler)

      for key <- [0x01, 0xD800, 0xDFFF, 0x110000] do
        assert {^state, nil} = PromptUI.handle_key(state, key, 0)
      end
    end

    test "accepts both ends of the printable scalar range" do
      state = PromptUI.open(base_state(), TestHandler)
      {state, nil} = PromptUI.handle_key(state, 32, 0)
      {state, nil} = PromptUI.handle_key(state, 0x10FFFF, 0)

      assert {"Test prompt: ", <<32, 0x10FFFF::utf8>>, 2} = PromptUI.render_data(state)
    end

    test "backspace on multi-byte unicode deletes one grapheme" do
      state =
        base_state()
        |> PromptUI.open(TestHandler, default: "a👩\u200D👩b")
        |> move_left(1)

      {state, nil} = PromptUI.handle_key(state, @backspace, 0)

      pui = prompt_state(state)
      assert pui.text == "ab"
      assert pui.cursor == 1
    end

    test "inserting at position 0 prepends to text" do
      state =
        base_state()
        |> PromptUI.open(TestHandler, default: "bc")
        |> move_left(2)

      {state, nil} = PromptUI.handle_key(state, ?a, 0)

      pui = prompt_state(state)
      assert pui.text == "abc"
      assert pui.cursor == 1
    end
  end

  describe "composability — picker then prompt" do
    test "on_select can open a prompt for multi-step flow" do
      # Simulate: picker selects a template, then prompt opens for title input
      state = base_state() |> PromptUI.open(RenameHandler)

      state =
        Enum.reduce(String.to_charlist("NewName"), state, fn char, acc ->
          {new_state, nil} = PromptUI.handle_key(acc, char, 0)
          new_state
        end)

      {state, nil} = PromptUI.handle_key(state, @enter, 0)

      assert Process.get(:new_name) == "NewName"
      refute PromptUI.open?(state)
    end
  end

  describe "handle_key/3: readline keys keep their text-editing meaning" do
    @ctrl 0x02

    defp keys(state, keys) do
      Enum.reduce(keys, state, fn {cp, mods}, state ->
        {state, nil} = PromptUI.handle_key(state, cp, mods)
        state
      end)
    end

    test "each readline key edits the line instead of inserting its letter" do
      cases = [
        {{?a, @ctrl}, "foo bar", 0},
        {{?e, @ctrl}, "foo bar", 7},
        {{?h, @ctrl}, "foo ba", 6},
        {{?w, @ctrl}, "foo ", 4},
        {{?u, @ctrl}, "", 0},
        {{?k, @ctrl}, "foo bar", 7}
      ]

      for {key, text, cursor} <- cases do
        state = base_state() |> PromptUI.open(TestHandler, default: "foo bar") |> keys([key])

        assert {prompt_state(state).text, prompt_state(state).cursor} == {text, cursor},
               inspect(key)
      end
    end

    test "⌃K deletes to the end of the line in a prompt without a list" do
      state =
        base_state()
        |> PromptUI.open(TestHandler, default: "foo bar")
        |> keys([{?a, @ctrl}, {@arrow_right, 0}, {?k, @ctrl}])

      assert prompt_state(state).text == "f"
    end

    test "⌃U deletes from the start of the line to the cursor" do
      state =
        base_state()
        |> PromptUI.open(TestHandler, default: "foo bar")
        |> move_left(3)
        |> keys([{?u, @ctrl}])

      assert {prompt_state(state).text, prompt_state(state).cursor} == {"bar", 0}
    end

    test "↩ submits and esc cancels through the prompt keymap scope" do
      state = base_state() |> PromptUI.open(TestHandler, default: "hello") |> keys([{@enter, 0}])
      assert Process.get(:submitted) == "hello"
      refute PromptUI.open?(state)

      state = base_state() |> PromptUI.open(TestHandler) |> keys([{@escape, 0}])
      assert Process.get(:cancelled)
      refute PromptUI.open?(state)
    end
  end
end
