defmodule MingaEditor.UI.Picker.OptionScopeSourceTest do
  use ExUnit.Case, async: true

  alias MingaEditor.UI.Picker.Item

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Config.Options
  alias MingaEditor.State.Picker, as: PickerState
  alias MingaEditor.UI.Picker.OptionScopeSource

  describe "candidates/1" do
    test "returns two scope choices" do
      items = OptionScopeSource.candidates(nil)
      assert length(items) == 2
      assert %Item{id: :buffer} = Enum.find(items, fn %Item{id: id} -> id == :buffer end)
      assert %Item{id: :global} = Enum.find(items, fn %Item{id: id} -> id == :global end)
    end
  end

  describe "on_select/2 — buffer scope" do
    test "sets option on the active buffer" do
      {:ok, buf} = BufferServer.start_link(content: "hello")
      # Confirm the buffer starts with wrap: false (seeded default)
      assert BufferServer.get_option(buf, :wrap) == false

      state = %{
        workspace: %{buffers: %{active: buf}},
        shell_state: %MingaEditor.Shell.Traditional.State{
          status_msg: nil,
          picker_ui: %PickerState{context: %{option_name: :wrap, new_value: true}}
        }
      }

      result =
        OptionScopeSource.on_select(
          %Item{id: :buffer, label: "This Buffer", description: ""},
          state
        )

      assert BufferServer.get_option(buf, :wrap) == true
      assert result.shell_state.status_msg =~ "this buffer"
    end
  end

  describe "on_select/2 — global scope" do
    test "sets option on the global Options agent" do
      {:ok, buf} = BufferServer.start_link(content: "hello")
      original = Options.get(:wrap)

      state = %{
        workspace: %{buffers: %{active: buf}},
        shell_state: %MingaEditor.Shell.Traditional.State{
          status_msg: nil,
          picker_ui: %PickerState{context: %{option_name: :wrap, new_value: !original}}
        }
      }

      result =
        OptionScopeSource.on_select(
          %Item{id: :global, label: "All Buffers", description: ""},
          state
        )

      assert Options.get(:wrap) == !original
      assert result.shell_state.status_msg =~ "all buffers"

      # Restore
      Options.set(:wrap, original)
    end
  end

  describe "title/0" do
    test "returns a descriptive title" do
      assert is_binary(OptionScopeSource.title())
    end
  end
end
