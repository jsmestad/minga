defmodule MingaEditor.State.SearchTest do
  use ExUnit.Case, async: true

  alias Minga.Editing.Search.Index
  alias Minga.Search.IndexOwner
  alias MingaEditor.State.Search

  test "old build completions cannot publish after query replacement" do
    buffer = self()
    search = Search.focus_gui_search(%Search{}, false)
    search = Search.begin_gui_build(search, buffer)
    old_revision = search.gui_search.revision

    {:accepted, search} =
      Search.apply_gui_search_edit(search, 1, 1, "new", true, false, false)

    refute Search.accepts_gui_generation?(search, old_revision, buffer)
  end

  test "version equality is insufficient when the monotonic sequence changed" do
    buffer = self()
    index = Index.build(["foo"], "foo")

    search =
      %Search{}
      |> Search.focus_gui_search(false)
      |> Search.begin_gui_build(buffer)

    revision = search.gui_search.revision
    generation = install_generation(buffer, search, 7, 10, index)
    assert {:accepted, ready} = Search.accept_gui_generation(search, revision, buffer, generation)

    assert {:ok, ^generation} = Search.ready_gui_generation(ready, buffer, {7, 10})
    assert :stale = Search.ready_gui_generation(ready, buffer, {7, 11})
  end

  test "changing an active Find session to Replace preserves its accepted index" do
    buffer = self()
    index = Index.build(["foo"], "foo")

    search =
      %Search{}
      |> Search.focus_gui_search(false)
      |> Search.begin_gui_build(buffer)

    revision = search.gui_search.revision
    generation = install_generation(buffer, search, 7, 10, index)
    assert {:accepted, ready} = Search.accept_gui_generation(search, revision, buffer, generation)

    replace = Search.focus_gui_search(ready, true)

    assert replace.gui_search.session_id == ready.gui_search.session_id + 1
    assert replace.gui_search.replace_mode
    assert replace.gui_search.revision == revision
    assert {:ok, ^generation} = Search.ready_gui_generation(replace, buffer, {7, 10})
  end

  test "ready, rebuilding, failed, dismissed, and target-switch projections are distinct" do
    buffer = self()
    other = spawn(fn -> :ok end)
    index = Index.build(["foo", "foo"], "foo")

    search =
      %Search{}
      |> Search.focus_gui_search(false)
      |> Search.begin_gui_build(buffer)

    revision = search.gui_search.revision
    generation = install_generation(buffer, search, 1, 1, index)
    assert {:accepted, ready} = Search.accept_gui_generation(search, revision, buffer, generation)

    assert %{status: :ready, match_count: 2} = Search.render_snapshot(ready, buffer, {0, 0})
    assert %{status: :rebuilding, match_count: 0} = Search.render_snapshot(ready, other, {0, 0})

    rebuilding = Search.rebuild_gui_search(ready, nil)

    assert %{status: :rebuilding, match_count: 2} =
             Search.render_snapshot(rebuilding, buffer, {0, 0})

    revision = rebuilding.gui_search.revision
    assert {:accepted, failed} = Search.fail_gui_search(rebuilding, revision, buffer, "boom")
    assert %{status: :failed, match_count: 0} = Search.render_snapshot(failed, buffer, {0, 0})

    dismissed = Search.dismiss_gui_search(failed)

    assert %{active: false, status: :ready, match_count: 0} =
             Search.render_snapshot(dismissed, buffer, {0, 0})
  end

  test "every invalid source tag rejects the ready-index transition" do
    buffer = self()
    index = Index.build(["foo"], "foo")

    for search <- [
          %Search{},
          Search.focus_gui_search(%Search{}, false) |> Search.dismiss_gui_search()
        ] do
      assert :stale = Search.ready_gui_generation(search, buffer, {0, 0})

      case search.gui_search do
        nil ->
          :ok

        session ->
          generation = install_generation(buffer, search, 0, 0, index)

          assert {:stale, ^search} =
                   Search.accept_gui_generation(search, session.revision, buffer, generation)
      end
    end
  end

  defp install_generation(buffer, search, version, sequence, index) do
    {:ok, generation} =
      IndexOwner.install(
        buffer,
        Search.gui_query_revision(search),
        version,
        sequence,
        index
      )

    generation
  end
end
