defmodule MingaAgent.Tool.SpecEffectTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Tool.Spec

  defp spec(attrs) do
    [name: "tool", description: "A tool", parameter_schema: %{}, callback: fn _args -> :ok end]
    |> Keyword.merge(attrs)
    |> Spec.new()
  end

  describe "derive_effect/1" do
    test "an undeclared effect is never read-only" do
      assert Spec.derive_effect(:ask) == :approval_required
      assert Spec.derive_effect(:deny) == :approval_required
      assert Spec.derive_effect(:auto) == :mutating
    end
  end

  describe "effect field on Spec.new/1" do
    test "a spec without an effect declaration is scheduled sequentially, whatever its capabilities" do
      for capabilities <- [[], [:read_project], [:git_read], [:lsp_read], [:network]] do
        assert {:ok, %Spec{effect: :mutating} = undeclared} = spec(capabilities: capabilities)
        assert Spec.sequential?(undeclared)
      end

      assert {:ok, %Spec{effect: :approval_required}} = spec(approval_level: :ask)
    end

    test "an explicit read-only declaration makes a spec concurrent" do
      assert {:ok, %Spec{effect: :read_only} = reader} =
               spec(capabilities: [:read_project], effect: :read_only)

      assert Spec.read_only?(reader)
      refute Spec.sequential?(reader)
    end

    test "a read-only declaration cannot claim a mutating capability" do
      assert {:error, {:read_only_with_mutating_capabilities, [:mutate_project]}} =
               spec(
                 capabilities: [:read_project, :mutate_project],
                 context_requirements: [:tool_context],
                 effect: :read_only
               )
    end

    test "an explicit mutating declaration is kept" do
      assert {:ok, %Spec{effect: :mutating}} =
               spec(capabilities: [:read_project], effect: :mutating)
    end

    test "invalid effect is rejected" do
      assert {:error, {:invalid_effect, :unknown}} = spec(effect: :unknown)
    end
  end

  describe "built-in declarations" do
    # Every canonical built-in and bundled tool by scheduling class. Add a new tool here deliberately.
    @concurrent ~w(
      definition describe_runtime describe_tools diagnostics document_symbols fetch_output fetch_url
      find git_diff git_log git_status grep hover job_output job_status list_directory memory_read
      read_file references todo_read workspace_symbols
    )

    @sequential ~w(
      ask_user code_actions delete_file edit_file git_commit git_stage job_cancel rename shell
      subagent todo_write write_file
    )

    test "only built-ins declared read-only run concurrently; every other built-in is sequential" do
      specs = MingaAgent.Tools.specs()
      assert Enum.sort(Enum.map(specs, & &1.name)) == Enum.sort(@concurrent ++ @sequential)

      for spec <- specs do
        expected = if spec.name in @concurrent, do: :concurrent, else: :sequential
        actual = if Spec.sequential?(spec), do: :sequential, else: :concurrent
        assert {spec.name, actual} == {spec.name, expected}
      end
    end
  end
end
