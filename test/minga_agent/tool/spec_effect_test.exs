defmodule MingaAgent.Tool.SpecEffectTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Tool.Spec

  describe "derive_effect/2" do
    test "ask approval level produces :approval_required" do
      assert Spec.derive_effect(:ask, []) == :approval_required
      assert Spec.derive_effect(:ask, [:read_project]) == :approval_required
      assert Spec.derive_effect(:ask, [:mutate_project]) == :approval_required
    end

    test "deny approval level produces :approval_required" do
      assert Spec.derive_effect(:deny, []) == :approval_required
    end

    test "auto with mutating capabilities produces :mutating" do
      assert Spec.derive_effect(:auto, [:mutate_project]) == :mutating
      assert Spec.derive_effect(:auto, [:run_shell]) == :mutating
      assert Spec.derive_effect(:auto, [:git_mutate]) == :mutating
      assert Spec.derive_effect(:auto, [:lsp_mutate]) == :mutating
      assert Spec.derive_effect(:auto, [:memory_write]) == :mutating
      assert Spec.derive_effect(:auto, [:spawn_agent]) == :mutating
    end

    test "auto with mixed capabilities including mutating produces :mutating" do
      assert Spec.derive_effect(:auto, [:read_project, :mutate_project]) == :mutating
    end

    test "auto with read-only capabilities produces :read_only" do
      assert Spec.derive_effect(:auto, []) == :read_only
      assert Spec.derive_effect(:auto, [:read_project]) == :read_only
      assert Spec.derive_effect(:auto, [:git_read]) == :read_only
      assert Spec.derive_effect(:auto, [:lsp_read]) == :read_only
    end
  end

  describe "effect field on Spec.new/1" do
    test "derived from capabilities when not explicitly provided" do
      {:ok, read_spec} =
        Spec.new(
          name: "reader",
          description: "Reads things",
          parameter_schema: %{},
          callback: fn _args -> :ok end,
          capabilities: [:read_project]
        )

      assert read_spec.effect == :read_only

      {:ok, mutating_spec} =
        Spec.new(
          name: "writer",
          description: "Writes things",
          parameter_schema: %{},
          callback: fn _args -> :ok end,
          capabilities: [:mutate_project],
          context_requirements: [:tool_context]
        )

      assert mutating_spec.effect == :mutating

      {:ok, approval_spec} =
        Spec.new(
          name: "dangerous",
          description: "Needs approval",
          parameter_schema: %{},
          callback: fn _args -> :ok end,
          approval_level: :ask
        )

      assert approval_spec.effect == :approval_required
    end

    test "explicit effect overrides derivation" do
      {:ok, spec} =
        Spec.new(
          name: "forced_mutating",
          description: "Explicitly mutating despite read-only capabilities",
          parameter_schema: %{},
          callback: fn _args -> :ok end,
          capabilities: [:read_project],
          effect: :mutating
        )

      assert spec.effect == :mutating
    end

    test "invalid effect is rejected" do
      assert {:error, {:invalid_effect, :unknown}} =
               Spec.new(
                 name: "bad",
                 description: "Bad effect",
                 parameter_schema: %{},
                 callback: fn _args -> :ok end,
                 effect: :unknown
               )
    end
  end

  describe "read_only?/1" do
    test "returns true for read-only effect" do
      {:ok, spec} =
        Spec.new(
          name: "reader",
          description: "Reads",
          parameter_schema: %{},
          callback: fn _args -> :ok end,
          capabilities: [:read_project]
        )

      assert Spec.read_only?(spec)
    end

    test "returns false for mutating effect" do
      {:ok, spec} =
        Spec.new(
          name: "writer",
          description: "Writes",
          parameter_schema: %{},
          callback: fn _args -> :ok end,
          capabilities: [:mutate_project],
          context_requirements: [:tool_context]
        )

      refute Spec.read_only?(spec)
    end
  end

  describe "sequential?/1" do
    test "returns true for mutating and approval_required effects" do
      {:ok, mutating} =
        Spec.new(
          name: "writer",
          description: "Writes",
          parameter_schema: %{},
          callback: fn _args -> :ok end,
          capabilities: [:mutate_project],
          context_requirements: [:tool_context]
        )

      {:ok, approval} =
        Spec.new(
          name: "dangerous",
          description: "Needs approval",
          parameter_schema: %{},
          callback: fn _args -> :ok end,
          approval_level: :ask
        )

      assert Spec.sequential?(mutating)
      assert Spec.sequential?(approval)
    end

    test "returns false for read_only effect" do
      {:ok, reader} =
        Spec.new(
          name: "reader",
          description: "Reads",
          parameter_schema: %{},
          callback: fn _args -> :ok end,
          capabilities: [:read_project]
        )

      refute Spec.sequential?(reader)
    end
  end

  describe "built-in declarations" do
    test "every built-in that changes state is scheduled sequentially" do
      # A side-effecting tool classified read-only would run concurrently and break model order.
      side_effecting =
        ~w(todo_write subagent shell write_file edit_file delete_file git_stage git_commit rename)

      for spec <- MingaAgent.Tools.specs(), spec.name in side_effecting do
        assert {spec.name, Spec.sequential?(spec)} == {spec.name, true}
      end

      refute Spec.sequential?(MingaAgent.Tools.Checklist.read_spec())
    end
  end
end
