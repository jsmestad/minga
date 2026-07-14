defmodule MingaEditor.PickerAsyncStaleTest do
  @moduledoc """
  Editor-level coverage for the async picker fetch path (ticket #2376):

    * confirming an async picker returns control with a revision-tagged fetch
      that runs off the editor input path (AC1/AC5);
    * results are revision-tagged so a stale (older-revision) result is dropped
      latest-wins and never overwrites the live picker (AC2/AC6).

  Uses the TODO search source (async). The stale-drop assertion is robust against
  the real background fetch: a sentinel item carried on a non-live revision can
  never appear, regardless of whether the real fetch has landed.
  """

  # TODO fetches spawn git/grep Ports and read the process-global Project workspace.
  use Minga.Test.EditorCase, async: false, rendering: :disabled

  alias Minga.Project
  alias Minga.Project.Root
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effects.TodoSearch
  alias MingaEditor.UI.Picker.Candidate
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.TodoSearchSource

  @sync_timeout 15_000

  setup do
    original_workspace = Project.snapshot()
    id = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "minga-async-picker-#{id}")
    reroot = Path.join(System.tmp_dir!(), "minga-async-picker-reroot-#{id}")

    File.mkdir_p!(root)
    File.mkdir_p!(reroot)
    {:ok, active_root} = Root.directory(root)
    activate_project!(active_root)

    on_exit(fn ->
      restore_project(original_workspace)
      File.rm_rf(root)
      File.rm_rf(reroot)
    end)

    %{project_root: root, reroot: reroot}
  end

  defp picker_payload(ctx) do
    state = :sys.get_state(ctx.editor, @sync_timeout)

    case MingaEditor.Shell.Runtime.state(state.shell_runtime).modal do
      {:picker, payload} -> payload
      _ -> nil
    end
  end

  defp item(label), do: %Item{id: %{path: "/tmp/x.ex", line: 1}, label: label}

  test "opens with a revision-tagged async fetch", %{project_root: root} do
    ctx = start_editor("scratch", project_root: root)

    :ok = GenServer.call(ctx.editor, {:api_execute_command, :search_todos}, @sync_timeout)

    payload = picker_payload(ctx)
    assert payload != nil
    assert payload.picker_ui.source == TodoSearchSource
    assert payload.picker_ui.load_status in [:loading, :ready]
    assert is_reference(payload.picker_ui.fetch_revision)
  end

  test "drops a stale (non-live-revision) result and never lets it overwrite the picker",
       %{project_root: root} do
    ctx = start_editor("scratch", project_root: root)
    :ok = GenServer.call(ctx.editor, {:api_execute_command, :search_todos}, @sync_timeout)

    # A result tagged with a revision that is not the picker's live one is stale
    # and must be ignored. This is latest-wins: a superseded fetch loses even if
    # it arrives after the picker opened.
    stale_revision = make_ref()
    stale_items = [item("stale-sentinel")]

    send(
      ctx.editor,
      {:picker_candidates_result, TodoSearchSource, stale_revision,
       {:ok, stale_items, Candidate.from_items(stale_items), %{}}}
    )

    _ = :sys.get_state(ctx.editor, @sync_timeout)

    labels =
      case picker_payload(ctx) do
        %{picker_ui: %{picker: %{items: items}}} -> Enum.map(items, & &1.label)
        _ -> []
      end

    refute "stale-sentinel" in labels
  end

  test "rejects a live-revision result captured before workspace rerooting",
       %{project_root: root_path, reroot: reroot_path} do
    ctx = start_editor("scratch", project_root: root_path)
    :ok = GenServer.call(ctx.editor, {:api_execute_command, :search_todos}, @sync_timeout)

    revision = picker_payload(ctx).picker_ui.fetch_revision
    state = :sys.get_state(ctx.editor, @sync_timeout)
    {:ok, captured_root} = Root.directory(root_path)
    {:ok, reroot} = Root.directory(reroot_path)
    assert Project.workspace_root() == captured_root
    assert {:ok, _snapshot} = Project.activate(reroot)

    request = TodoSearch.request(captured_root, revision)

    result = %TodoSearch.Result{
      revision: revision,
      items: [],
      candidates: [],
      meta: %{}
    }

    assert {^state, %Outcome{status: :stale, reason: :workspace_rerooted}} =
             TodoSearch.apply(state, Outcome.completed(request, result))
  end

  test "applies a live-revision result carrying candidates pre-built off the editor",
       %{project_root: root} do
    ctx = start_editor("scratch", project_root: root)
    :ok = GenServer.call(ctx.editor, {:api_execute_command, :search_todos}, @sync_timeout)

    # Grab the picker's live fetch revision so the result passes the stale guard.
    live_revision = picker_payload(ctx).picker_ui.fetch_revision
    assert is_reference(live_revision)

    # The result message carries already-built %Candidate{} structs, exactly like
    # the fetch Task now produces (#2628). The editor handler must install them
    # without re-running Candidate.from_items, so the input loop never normalizes
    # the full set inline. Sending built candidates here exercises that path.
    items = [item("prebuilt-sentinel")]
    candidates = Candidate.from_items(items)
    assert [%Candidate{}] = candidates

    send(
      ctx.editor,
      {:picker_candidates_result, TodoSearchSource, live_revision, {:ok, items, candidates, %{}}}
    )

    _ = :sys.get_state(ctx.editor, @sync_timeout)
    payload = picker_payload(ctx)

    labels = Enum.map(payload.picker_ui.picker.items, & &1.label)
    assert "prebuilt-sentinel" in labels
    # The same candidates flow straight through; the picker keeps the pre-built set.
    assert payload.picker_ui.picker.candidates == candidates
    assert payload.picker_ui.load_status == :ready
  end

  @spec activate_project!(Root.t()) :: :ok
  defp activate_project!(%Root{path: path} = root) do
    Minga.Events.subscribe(:project_rebuilt)
    assert {:ok, snapshot} = Project.activate(root)

    if snapshot.rebuilding? do
      assert_receive {:minga_event, :project_rebuilt,
                      %Minga.Events.ProjectRebuiltEvent{root: ^path}},
                     @sync_timeout
    end

    :ok
  end

  @spec restore_project(Minga.Project.WorkspaceSnapshot.t() | nil) :: :ok
  defp restore_project(nil) do
    Project.close()
    _ = :sys.get_state(Project)
    :ok
  end

  defp restore_project(%Minga.Project.WorkspaceSnapshot{root: root}) do
    Project.close()
    _ = :sys.get_state(Project)
    _ = Project.activate(root)
    :ok
  end
end
