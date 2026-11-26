defmodule MingaAgent.Changeset.IsolatedIntegrationTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Changeset
  alias MingaAgent.Changeset.Server

  @base "line one\nline two\nline three\n"

  setup do
    dir =
      Path.join(System.tmp_dir!(), "isolated-integration-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "app.ex"), @base)
    File.write!(Path.join(dir, "other.ex"), "untouched\n")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{cs: start_supervised!({Server, project_root: dir})}
  end

  describe "clean integration" do
    test "merges child and parent edits to different lines and keeps undo history", %{cs: cs} do
      parent = "line one\nline two\nparent three\n"
      :ok = Changeset.write_file(cs, "app.ex", parent)
      child = "child one\nline two\nline three\n"

      assert {:ok, ["app.ex"]} =
               Changeset.integrate_isolated_changes(cs, [{"app.ex", @base, child}])

      assert {:ok, "child one\nline two\nparent three\n"} = Changeset.read_file(cs, "app.ex")
      assert :ok = Changeset.undo(cs, "app.ex")
      assert {:ok, ^parent} = Changeset.read_file(cs, "app.ex")
    end

    test "writes a file the child added and deletes a file the child removed", %{cs: cs} do
      assert {:ok, ["new.ex", "other.ex"]} =
               Changeset.integrate_isolated_changes(cs, [
                 {"new.ex", :missing, "added\n"},
                 {"other.ex", "untouched\n", :deleted}
               ])

      assert {:ok, "added\n"} = Changeset.read_file(cs, "new.ex")
      assert {:error, _} = Changeset.read_file(cs, "other.ex")
    end

    test "skips changes the parent already has", %{cs: cs} do
      :ok = Changeset.write_file(cs, "same.ex", "same\n")
      :ok = Changeset.delete_file(cs, "other.ex")

      assert {:ok, []} =
               Changeset.integrate_isolated_changes(cs, [
                 {"same.ex", :missing, "same\n"},
                 {"other.ex", "untouched\n", :deleted}
               ])
    end
  end

  describe "conflicts write nothing" do
    for {name, prepare, change, reason} <- [
          {"overlapping edits", {:write, "app.ex", "parent one\nline two\nline three\n"},
           {"app.ex", @base, "child one\nline two\nline three\n"}, :merge_conflict},
          {"both sides added different content", {:write, "new.ex", "parent\n"},
           {"new.ex", :missing, "child\n"}, :both_added},
          {"parent deleted what the child modified", {:delete, "app.ex"},
           {"app.ex", @base, "changed\n"}, :deleted_in_parent},
          {"child deleted what the parent modified", {:write, "app.ex", "parent edit\n"},
           {"app.ex", @base, :deleted}, :modified_in_parent}
        ] do
      @prepare prepare
      @change change
      @reason reason

      test "#{name}", %{cs: cs} do
        prepare(cs, @prepare)
        {path, _ancestor, _child} = @change
        {:ok, before} = read(cs, path)
        clean = {"clean.ex", :missing, "clean\n"}

        assert {:conflict, %{conflicts: [{^path, reason}], clean: ["clean.ex"]}} =
                 Changeset.integrate_isolated_changes(cs, [@change, clean])

        assert reason_tag(reason) == @reason
        assert {:ok, ^before} = read(cs, path)
        assert {:error, _} = Changeset.read_file(cs, "clean.ex")
      end
    end

    test "a path outside the project is reported as unreadable", %{cs: cs} do
      assert {:conflict, %{conflicts: [{"../escape.ex", {:unreadable, _}}]}} =
               Changeset.integrate_isolated_changes(cs, [{"../escape.ex", :missing, "x"}])
    end
  end

  @spec prepare(pid(), {:write, String.t(), binary()} | {:delete, String.t()}) :: :ok
  defp prepare(cs, {:write, path, content}), do: :ok = Changeset.write_file(cs, path, content)
  defp prepare(cs, {:delete, path}), do: :ok = Changeset.delete_file(cs, path)

  @spec read(pid(), String.t()) :: {:ok, binary() | :absent}
  defp read(cs, path) do
    case Changeset.read_file(cs, path) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> {:ok, :absent}
    end
  end

  @spec reason_tag(Changeset.integration_conflict()) :: atom()
  defp reason_tag({tag, _detail}), do: tag
  defp reason_tag(tag) when is_atom(tag), do: tag
end
