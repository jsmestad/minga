defmodule MingaEditor.Renderer.BufferChangesTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.Renderer.BufferChanges
  alias MingaEditor.Renderer.State
  alias MingaEditor.Shell.Traditional.ClickRegions
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

    calls = trace_buffer_calls(buffer, fn -> BufferChanges.prepare(state, changed) end)
    {state, _input} = calls.result

    assert Enum.count(calls.messages, &match?({:renderer_consume, _}, &1)) == 1
    refute Enum.any?(calls.messages, &match?(:version, &1))

    first_pending = state.resident_windows[1].render_cache.pending_edit_deltas
    second_pending = state.resident_windows[2].render_cache.pending_edit_deltas
    first_snapshot = state.resident_windows[1].render_cache.changed_snapshot
    second_snapshot = state.resident_windows[2].render_cache.changed_snapshot

    assert first_pending != []
    assert first_pending == second_pending
    assert first_snapshot == second_snapshot
    assert first_snapshot.lines == ["changed two"]
    refute Map.has_key?(Map.from_struct(first_snapshot), :document)
    assert {:ok, []} = Minga.Buffer.consume_edit_deltas(buffer, :renderer)
  end

  test "a third uncommitted consume preserves a pending range shifted by structural edits" do
    buffer = start_supervised!({Minga.Buffer, content: "zero\none\ntwo\nthree\nfour"})
    intent = intent(buffer, 0)
    {state, _input} = BufferChanges.prepare(State.new([]), intent)

    :ok = Minga.Buffer.move_to(buffer, {3, 0})
    :ok = Minga.Buffer.insert_text(buffer, "X")
    {state, _input} = BufferChanges.prepare(state, intent)

    :ok = Minga.Buffer.move_to(buffer, {0, 0})
    :ok = Minga.Buffer.insert_text(buffer, "new\n")
    {state, _input} = BufferChanges.prepare(state, intent)

    :ok = Minga.Buffer.move_to(buffer, {0, 0})
    :ok = Minga.Buffer.insert_text(buffer, "Y")
    {state, _input} = BufferChanges.prepare(state, intent)

    first_snapshot = state.resident_windows[1].render_cache.changed_snapshot
    second_snapshot = state.resident_windows[2].render_cache.changed_snapshot

    assert first_snapshot == second_snapshot
    assert first_snapshot.first_line == 0
    assert first_snapshot.lines == ["Ynew", "zero", "one", "two", "Xthree"]
  end

  test "intent derives typed observed versions without calling the buffer" do
    buffer = start_supervised!({Minga.Buffer, content: "one"})
    one = Window.new(1, buffer, 24, 80)
    windows = %Windows{map: %{1 => one}, active: 1, tree: {:leaf, 1}, next_id: 2}

    input = %Input{
      port_manager: nil,
      theme: Fallback.theme(),
      capabilities: %Capabilities{},
      shell_id: :traditional,
      shell: MingaEditor.Shell.Traditional,
      message_store: %MingaEditor.UI.Panel.MessageStore{},
      workspace: %{windows: windows}
    }

    calls = trace_buffer_calls(buffer, fn -> Intent.from_input(input) end)
    assert calls.result.buffer_versions == %{buffer => 0}
    assert calls.messages == []
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
      click_regions: %ClickRegions{},
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
               :git_syncing,
               :gui_config_state,
               :highlighting,
               :last_input_seq,
               :layout,
               :line_spacing,
               :message_store,
               :notifications,
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
               :keymap_scope,
               :launchpad,
               :mouse,
               :search
             ]

    assert :erlang.external_size(bounded) < 100_000
    refute binary =~ "Minga.Buffer.Document"
    refute binary =~ "Minga.RenderModel.Window.Row"
    refute binary =~ "MingaEditor.Renderer.WindowCache"
    refute binary =~ "ResidentWindowState"
    refute binary =~ "ResidentStore"
    refute binary =~ "MingaEditor.RenderPipeline.Input"

    fields =
      ~w(authoritative_scroll_seq content cursor fold_map fold_ranges popup_meta scroll_detach_cursor scroll_echo_top scroll_velocity viewport)a

    assert Enum.all?(bounded.windows, fn {_id, carrier} ->
             Map.keys(Map.from_struct(carrier)) |> Enum.sort() == fields
           end)
  end

  defp trace_buffer_calls(buffer, fun) do
    :erlang.trace(buffer, true, [:receive, {:tracer, self()}])

    try do
      result = fun.()
      delivery_ref = :erlang.trace_delivered(buffer)
      assert_receive {:trace_delivered, ^buffer, ^delivery_ref}
      %{result: result, messages: drain_buffer_calls(buffer, [])}
    after
      :erlang.trace(buffer, false, [:receive])
    end
  end

  defp drain_buffer_calls(buffer, acc) do
    receive do
      {:trace, ^buffer, :receive, {:"$gen_call", _from, message}} ->
        drain_buffer_calls(buffer, [message | acc])

      {:trace, ^buffer, :receive, _message} ->
        drain_buffer_calls(buffer, acc)
    after
      0 -> Enum.reverse(acc)
    end
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
