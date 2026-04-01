defmodule MingaAgent.Tool.RegistryTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Tool.Registry
  alias MingaAgent.Tool.Spec

  setup do
    # Each test gets its own ETS table to avoid cross-test interference
    table = :"registry_test_#{:erlang.unique_integer([:positive])}"

    :ets.new(table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true
    ])

    on_exit(fn ->
      if :ets.whereis(table) != :undefined, do: :ets.delete(table)
    end)

    {:ok, table: table}
  end

  defp sample_spec(name \\ "test_tool") do
    Spec.new!(
      name: name,
      description: "A test tool",
      parameter_schema: %{"type" => "object"},
      callback: fn _args -> {:ok, "result"} end,
      category: :custom,
      approval_level: :auto
    )
  end

  describe "register/2" do
    test "stores a spec and makes it lookupable", %{table: table} do
      spec = sample_spec()
      assert :ok = Registry.register(table, spec)
      assert {:ok, ^spec} = Registry.lookup(table, "test_tool")
    end

    test "overwrites existing spec with same name", %{table: table} do
      spec1 = sample_spec()

      spec2 =
        Spec.new!(
          name: "test_tool",
          description: "Updated",
          parameter_schema: %{},
          callback: fn _ -> :ok end
        )

      Registry.register(table, spec1)
      Registry.register(table, spec2)

      {:ok, found} = Registry.lookup(table, "test_tool")
      assert found.description == "Updated"
    end
  end

  describe "lookup/2" do
    test "returns :error for unknown tools", %{table: table} do
      assert :error = Registry.lookup(table, "nonexistent")
    end

    test "returns {:ok, spec} for registered tools", %{table: table} do
      spec = sample_spec("lookup_tool")
      Registry.register(table, spec)
      assert {:ok, ^spec} = Registry.lookup(table, "lookup_tool")
    end
  end

  describe "all/1" do
    test "returns empty list when no tools registered", %{table: table} do
      assert [] = Registry.all(table)
    end

    test "returns all registered specs sorted by name", %{table: table} do
      Registry.register(table, sample_spec("zebra"))
      Registry.register(table, sample_spec("alpha"))
      Registry.register(table, sample_spec("middle"))

      specs = Registry.all(table)
      names = Enum.map(specs, & &1.name)
      assert names == ["alpha", "middle", "zebra"]
    end
  end

  describe "registered?/2" do
    test "returns false for unknown tools", %{table: table} do
      refute Registry.registered?(table, "nope")
    end

    test "returns true for registered tools", %{table: table} do
      Registry.register(table, sample_spec("exists"))
      assert Registry.registered?(table, "exists")
    end
  end

  describe "from_req_tool/1" do
    test "converts ReqLLM.Tool to Spec with correct category" do
      req_tool =
        ReqLLM.Tool.new!(
          name: "read_file",
          description: "Read a file",
          parameter_schema: %{"type" => "object"},
          callback: fn _args -> {:ok, "content"} end
        )

      spec = Registry.from_req_tool(req_tool)

      assert spec.name == "read_file"
      assert spec.description == "Read a file"
      assert spec.category == :filesystem
      assert spec.approval_level == :auto
    end

    test "marks destructive tools with :ask approval" do
      req_tool =
        ReqLLM.Tool.new!(
          name: "write_file",
          description: "Write a file",
          parameter_schema: %{"type" => "object"},
          callback: fn _args -> {:ok, "written"} end
        )

      spec = Registry.from_req_tool(req_tool)
      assert spec.approval_level == :ask
    end

    test "categorizes git tools" do
      req_tool =
        ReqLLM.Tool.new!(
          name: "git_status",
          description: "Git status",
          parameter_schema: %{},
          callback: fn _args -> {:ok, "status"} end
        )

      spec = Registry.from_req_tool(req_tool)
      assert spec.category == :git
    end

    test "categorizes LSP tools" do
      req_tool =
        ReqLLM.Tool.new!(
          name: "diagnostics",
          description: "LSP diagnostics",
          parameter_schema: %{},
          callback: fn _args -> {:ok, "diags"} end
        )

      spec = Registry.from_req_tool(req_tool)
      assert spec.category == :lsp
    end
  end
end
