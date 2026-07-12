defmodule MingaEditor.Renderer.BufferChangesTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.Renderer.BufferChanges
  alias MingaEditor.Renderer.State
  alias MingaEditor.State.Windows
  alias MingaEditor.UI.Theme.Fallback
  alias MingaEditor.Window

  test "one changed buffer is consumed once and ordered deltas fan out to both resident windows" do
    buffer = start_supervised!({Minga.Buffer, content: "one\ntwo\nthree"})
    intent = intent(buffer, 0)

    {state, _input} = BufferChanges.prepare(State.new([]), intent)
    assert map_size(state.resident_windows) == 2
    assert state.resident_windows[1].hydration == :renderer_restart
    assert state.resident_windows[1].render_cache.hydration_reason == :renderer_restart

    :ok = Minga.Buffer.move_to(buffer, {1, 0})
    :ok = Minga.Buffer.insert_text(buffer, "changed ")
    changed = %{intent | buffer_versions: %{buffer => Minga.Buffer.version(buffer)}}

    {state, _input} = BufferChanges.prepare(state, changed)

    first_pending = state.resident_windows[1].render_cache.pending_edit_deltas
    second_pending = state.resident_windows[2].render_cache.pending_edit_deltas
    assert first_pending != []
    assert first_pending == second_pending
    assert {:ok, []} = Minga.Buffer.consume_edit_deltas(buffer, :renderer)
  end

  test "window close, buffer replacement, and exact buffer DOWN share centralized cleanup" do
    first = start_supervised!({Minga.Buffer.Process, content: "first"}, id: :first_buffer)
    second = start_supervised!({Minga.Buffer.Process, content: "second"}, id: :second_buffer)
    {state, _} = BufferChanges.prepare(State.new([]), intent(first, 0))
    first_ref = state.buffer_monitors[first]

    {state, _} = BufferChanges.prepare(state, intent(second, 0))
    refute Map.has_key?(state.buffer_monitors, first)
    assert Map.has_key?(state.buffer_monitors, second)

    assert Enum.all?(state.resident_windows, fn {_id, resident} ->
             resident.buffer == second and resident.hydration == :buffer_replacement and
               resident.render_cache.hydration_reason == :buffer_replacement
           end)

    # A stale DOWN for the replaced buffer cannot remove the new resident state.
    assert BufferChanges.handle_down(state, first_ref, first) == state

    second_ref = state.buffer_monitors[second]
    dropped = BufferChanges.handle_down(state, second_ref, second)
    assert dropped.resident_windows == %{}
    assert dropped.buffer_monitors == %{}
  end

  test "focused receipt excludes resident/cache stores and stays within a fixed small bound" do
    receipt = %MingaEditor.Renderer.RenderReceipt{
      layout: nil,
      focus_tree: nil,
      shell_id: :traditional,
      shell_identity: nil,
      modeline_click_regions: [],
      tab_bar_click_regions: [],
      frame_seq: 1,
      keyframe?: false,
      render_sent_at: 0
    }

    fields = Map.keys(Map.from_struct(receipt))
    refute :windows in fields
    refute :caches in fields
    refute :message_store in fields
    assert :erlang.external_size(receipt) < 2_000
  end

  test "intent boundary structs expose only explicitly reviewed fields" do
    buffer = start_supervised!({Minga.Buffer, content: "one"})
    bounded = intent(buffer, 0)
    binary = :erlang.term_to_binary(bounded)

    assert Map.keys(Map.from_struct(bounded.frame)) |> Enum.sort() ==
             [
               :backend,
               :capabilities,
               :cursor_animate,
               :diff_views,
               :editing_model,
               :face_override_registries,
               :focus_tree,
               :force_keyframe?,
               :gui_config_state,
               :last_input_seq,
               :layout,
               :line_spacing,
               :lsp,
               :message_store,
               :notifications,
               :parser_status,
               :port_manager,
               :shell,
               :shell_id,
               :shell_identity,
               :shell_state,
               :sidebar_registry,
               :status_bar_data,
               :terminal_viewport,
               :theme
             ]

    assert Map.keys(Map.from_struct(bounded.workspace)) |> Enum.sort() ==
             [
               :agent_ui,
               :buffers,
               :cmd_hover_link,
               :document_highlights,
               :editing,
               :file_tree,
               :highlight,
               :keymap_scope,
               :launchpad,
               :mouse,
               :search,
               :viewport
             ]

    assert :erlang.external_size(bounded) < 100_000
    refute binary =~ "Minga.Buffer.Document"
    refute binary =~ "Minga.RenderModel.Window.Row"
    refute binary =~ "MingaEditor.Renderer.WindowCache"
    refute binary =~ "ResidentWindowState"
    refute binary =~ "ResidentStore"
    refute binary =~ "MingaEditor.RenderPipeline.Input"

    assert Enum.all?(bounded.windows, fn {_id, carrier} ->
             carrier.__struct__ == MingaEditor.RenderPipeline.WindowIntent
           end)
  end

  defp intent(buffer, version) do
    one = Window.new(1, buffer, 24, 80)
    two = Window.new(2, buffer, 24, 80)
    windows = %Windows{map: %{1 => one, 2 => two}, active: 1, tree: {:leaf, 1}, next_id: 3}

    input = %Input{
      port_manager: nil,
      theme: Fallback.theme(),
      capabilities: %Capabilities{},
      shell_id: :traditional,
      shell: MingaEditor.Shell.Traditional,
      message_store: %MingaEditor.UI.Panel.MessageStore{},
      workspace: %{windows: windows}
    }

    input
    |> Intent.from_input()
    |> Map.put(:buffer_versions, %{buffer => version})
  end
end
