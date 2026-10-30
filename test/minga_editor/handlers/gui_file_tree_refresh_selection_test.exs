defmodule MingaEditor.Handlers.GuiFileTreeRefreshSelectionTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Project.FileTree
  alias Minga.Project.FileTree.BufferSync
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.EffectScheduler
  alias MingaEditor.FileTree.Refresh
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State.FileTree, as: FileTreeState

  @moduletag :tmp_dir
  @timeout 2_000

  for move_selection? <- [false, true] do
    @move_selection? move_selection?

    test "named duplicate preserves acceptance-time selection after the real scheduler scan (move in flight: #{move_selection?})",
         %{tmp_dir: root} do
      target_path = Path.join(root, "a-target.txt")
      selected_path = Path.join(root, "m-selected.txt")
      later_path = Path.join(root, "z-later.txt")
      File.write!(target_path, "target")
      File.write!(selected_path, "selected")
      File.write!(later_path, "later")

      {:ok, tree} =
        root |> FileTree.new() |> FileTree.ensure_entries() |> FileTree.select_path(selected_path)

      backing =
        start_supervised!(
          {Buffer,
           content: "",
           buffer_type: :nofile,
           buffer_name: "*File Tree*",
           read_only: true,
           unlisted: true}
        )

      :ok = BufferSync.sync(backing, tree)
      file_tree = FileTreeState.open(%FileTreeState{}, tree, backing)
      generation = FileTreeState.presentation_generation(file_tree)
      scheduler = start_scheduler()
      state = TestHelpers.base_state(effect_scheduler: scheduler, rendering: :disabled)
      state = %{state | workspace: SessionState.set_file_tree(state.workspace, file_tree)}
      active_buffer = state.workspace.buffers.active
      active_content = Buffer.content(active_buffer)

      mutated =
        GuiActionHandler.dispatch(
          state,
          {:semantic_item_activate, :file_tree, :duplicate, generation, target_path}
        )

      assert File.read!(Path.join(root, "a-target copy.txt")) == "target"
      assert selected_path(mutated) == selected_path
      assert mutated.workspace.buffers.active == active_buffer

      # Consume the actual mutation debounce, then submit the production scanner
      # through the real scheduler. Watcher reconciliation is orthogonal here.
      {:debounced, timer, _attempt} = mutated.workspace.file_tree.refresh.phase
      assert_receive {:file_tree_refresh_timer, ^timer}, @timeout

      {:ready, scan_tree, _attempt, file_tree} =
        FileTreeState.refresh_debounce_elapsed(mutated.workspace.file_tree, timer)

      request =
        Refresh.request(scan_tree, state.extension_surfaces.events_registry,
          synchronize_watchers?: false
        )

      assert {:ok, request_id, :running} = EffectScheduler.schedule(scheduler, request)
      file_tree = FileTreeState.track_refresh_request(file_tree, root, request_id)
      pending = %{mutated | workspace: SessionState.set_file_tree(mutated.workspace, file_tree)}

      {pending, expected_path} =
        if @move_selection? do
          {:ok, current_tree} = FileTree.select_path(FileTreeState.tree(file_tree), later_path)
          :ok = BufferSync.sync(backing, current_tree)
          file_tree = FileTreeState.set_tree(file_tree, current_tree)

          {%{pending | workspace: SessionState.set_file_tree(pending.workspace, file_tree)},
           later_path}
        else
          {pending, selected_path}
        end

      assert_receive {:effect_result, ^scheduler,
                      %Outcome{
                        request: %{id: ^request_id},
                        value: {:completed, worker_tree}
                      } = outcome},
                     @timeout

      # The worker's numeric cursor demonstrably names a different file now.
      refute FileTree.selected_entry(worker_tree).path == expected_path
      assert :ok = EffectScheduler.claim(scheduler, outcome)

      assert {accepted, %Outcome{value: {:completed, _tree}} = applied} =
               Refresh.apply(pending, outcome)

      EffectScheduler.finalize(scheduler, applied)

      accepted_tree = FileTreeState.tree(accepted.workspace.file_tree)
      assert selected_path(accepted) == expected_path
      assert Buffer.cursor(backing) == {accepted_tree.cursor, 0}
      assert Buffer.content(backing) =~ "a-target copy.txt"
      assert FileTreeState.presentation_generation(accepted.workspace.file_tree) == generation
      assert accepted.workspace.buffers.active == active_buffer
      assert Buffer.content(active_buffer) == active_content

      timer = accepted.render.render_correlation.timer
      if is_reference(timer), do: Process.cancel_timer(timer)
    end
  end

  defp selected_path(state) do
    state.workspace.file_tree
    |> FileTreeState.tree()
    |> FileTree.selected_entry()
    |> Map.fetch!(:path)
  end

  defp start_scheduler do
    task_supervisor = start_supervised!({Task.Supervisor, []})

    scheduler =
      start_supervised!({EffectScheduler, task_supervisor: task_supervisor, observer: self()})

    :ok = EffectScheduler.attach(scheduler, self())
    scheduler
  end
end
