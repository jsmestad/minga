defmodule MingaEditor.UI.Picker.OptionScopeSourceTest do
  use ExUnit.Case, async: true

  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.OptionScopeSource

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config.Options
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Search
  alias MingaEditor.VimState
  alias MingaEditor.Viewport
  alias MingaEditor.UI.Theme

  @ctx %{option_name: :wrap, new_value: true}

  defp picker_context(ctx) do
    %Context{
      buffers: %Buffers{},
      editing: VimState.new(),
      search: %Search{},
      viewport: Viewport.new(24, 80),
      tab_bar: %{},
      picker_ui: %{context: ctx},
      capabilities: %{},
      theme: Theme.get!(:doom_one)
    }
  end

  describe "candidates/1" do
    test "returns two scope choices when context is present" do
      items = OptionScopeSource.candidates(picker_context(@ctx))
      assert Enum.count(items) == 2
      assert Enum.any?(items, fn %Item{id: {scope, _}} -> scope == :buffer end)
      assert Enum.any?(items, fn %Item{id: {scope, _}} -> scope == :global end)
    end

    test "returns empty list when context is missing" do
      assert OptionScopeSource.candidates(nil) == []
    end
  end

  describe "on_select/2 — buffer scope" do
    test "sets option on the active buffer" do
      {:ok, buf} = BufferProcess.start_link(content: "hello", filetype: :elixir)
      assert BufferProcess.get_option(buf, :wrap) == false

      state = state_with_buffer(buf)

      result =
        OptionScopeSource.on_select(
          %Item{id: {:buffer, @ctx}, label: "This Buffer", description: ""},
          state
        )

      assert BufferProcess.get_option(buf, :wrap) == true
      assert result.shell_runtime.state.status_msg =~ "this buffer"
    end
  end

  describe "on_select/2 — global scope" do
    test "sets option on the global Options agent" do
      {:ok, buf} = BufferProcess.start_link(content: "hello")
      original = Options.get(:wrap)
      ctx = %{option_name: :wrap, new_value: !original}

      state = state_with_buffer(buf)

      result =
        OptionScopeSource.on_select(
          %Item{id: {:global, ctx}, label: "All Buffers", description: ""},
          state
        )

      assert Options.get(:wrap) == !original
      assert result.shell_runtime.state.status_msg =~ "all buffers"

      Options.set(:wrap, original)
    end
  end

  describe "title/0" do
    test "returns a descriptive title" do
      assert is_binary(OptionScopeSource.title())
    end
  end

  describe "on_select after picker close (regression for context-in-id fix)" do
    # `PickerUI.run_select_and_close/3` resets the modal to `:none` before
    # invoking `on_select`. Previously this source read the picker context
    # from the active shell runtime's picker context, which had been cleared by
    # the close, so the option was never applied. The fix carries the
    # context inside `Item.id`. This test pins that contract by passing a
    # state with `modal: :none` (matching what `on_select` actually sees in
    # production).

    test "applies buffer-scoped option when modal is already :none" do
      {:ok, buf} = BufferProcess.start_link(content: "hello", filetype: :elixir)
      assert BufferProcess.get_option(buf, :wrap) == false

      state = state_with_buffer(buf)

      result =
        OptionScopeSource.on_select(
          %Item{id: {:buffer, @ctx}, label: "This Buffer", description: ""},
          state
        )

      assert BufferProcess.get_option(buf, :wrap) == true
      assert result.shell_runtime.state.status_msg =~ "this buffer"
    end

    test "applies global-scoped option when modal is already :none" do
      {:ok, buf} = BufferProcess.start_link(content: "hello")
      original = Options.get(:wrap)
      ctx = %{option_name: :wrap, new_value: !original}

      state = state_with_buffer(buf)

      result =
        OptionScopeSource.on_select(
          %Item{id: {:global, ctx}, label: "All Buffers", description: ""},
          state
        )

      assert Options.get(:wrap) == !original
      assert result.shell_runtime.state.status_msg =~ "all buffers"

      Options.set(:wrap, original)
    end
  end

  defp state_with_buffer(buffer) do
    %EditorState{
      port_manager: self(),
      workspace: %SessionState{
        buffers: %Buffers{active: buffer, list: [buffer], active_index: 0},
        viewport: Viewport.new(24, 80)
      },
      shell_runtime: Runtime.new(Runtime.default_entry(), %TraditionalState{})
    }
  end
end
