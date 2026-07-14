defmodule MingaEditor.UI.Picker.FileSourceAsyncTest do
  @moduledoc "Tests FileSource behavior that does not mutate the global project singleton."

  use ExUnit.Case, async: true

  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.State.FileTree
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.FileSource
  alias MingaEditor.UI.Picker.Item

  @moduletag :tmp_dir

  test "on_bulk_select opens all marked project-relative files", %{tmp_dir: tmp_dir} do
    project = Path.join(tmp_dir, "bulk_project_#{:erlang.unique_integer([:positive])}")
    lib = Path.join(project, "lib")
    File.mkdir_p!(lib)
    File.write!(Path.join(lib, "one.ex"), "one")
    File.write!(Path.join(lib, "two.ex"), "two")

    state =
      TestHelpers.base_state(content: "initial")
      |> then(fn state ->
        %{
          state
          | workspace:
              then(
                state.workspace,
                &MingaEditor.Session.State.set_file_tree(&1, %FileTree{project_root: project})
              )
        }
      end)

    initial_pids = state.workspace.buffers.list

    state =
      FileSource.on_bulk_select(
        [%Item{id: "lib/one.ex", label: "one.ex"}, %Item{id: "lib/two.ex", label: "two.ex"}],
        state
      )

    paths = Enum.map(state.workspace.buffers.list, &Minga.Buffer.file_path/1)
    new_pids = Enum.reject(state.workspace.buffers.list, &Enum.member?(initial_pids, &1))
    on_exit(fn -> Enum.each(new_pids, &stop_pid/1) end)

    assert Path.join(lib, "one.ex") in paths
    assert Path.join(lib, "two.ex") in paths
    assert Minga.Buffer.file_path(state.workspace.buffers.active) == Path.join(lib, "two.ex")
  end

  test "no-workspace picker returns no candidates without a cwd fallback" do
    context =
      TestHelpers.base_state(content: "loose file")
      |> Context.from_editor_state(%{project_root: nil})

    assert FileSource.candidates(context) == []
  end

  test "bulk actions expose open all marked" do
    assert FileSource.bulk_actions([%Item{id: "lib/one.ex", label: "one.ex"}]) ==
             [{"Open all marked", :open_marked}]
  end

  describe "enrich/1" do
    test "builds icon, color, two-line description, and git annotation for winners" do
      lean = %Item{
        id: "lib/foo/bar.ex",
        label: "bar.ex",
        search_text: "lib/foo/bar.ex",
        meta: %{git: :modified}
      }

      [enriched] = FileSource.enrich([lean])

      assert enriched.id == "lib/foo/bar.ex"
      assert String.ends_with?(enriched.label, " bar.ex")
      assert String.first(enriched.label) != "b"
      assert enriched.description == "lib/foo"
      assert enriched.annotation == "M"
      assert enriched.two_line == false
      assert is_integer(enriched.icon_color)
    end

    test "uses an empty description for root-level files and no git annotation" do
      lean = %Item{id: "mix.exs", label: "mix.exs", search_text: "mix.exs", meta: %{git: nil}}
      [enriched] = FileSource.enrich([lean])
      assert enriched.description == ""
      assert enriched.annotation == nil
    end
  end

  defp stop_pid(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end
end
