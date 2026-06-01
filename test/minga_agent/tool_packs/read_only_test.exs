defmodule MingaAgent.ToolPacks.ReadOnlyTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Tool.Context, as: ToolContext
  alias MingaAgent.Tool.Executor
  alias MingaAgent.Tool.Registry
  alias MingaAgent.Tool.Spec
  alias MingaAgent.ToolPacks.ReadOnly

  setup do
    table = :"read_only_pack_test_#{System.unique_integer([:positive])}"
    :ets.new(table, [:named_table, :set, :public, read_concurrency: true])

    on_exit(fn ->
      if :ets.whereis(table) != :undefined, do: :ets.delete(table)
    end)

    %{table: table}
  end

  test "declares the bundled source and stable tool names" do
    assert ReadOnly.source() == {:bundle, :read_only_tools}
    assert ReadOnly.tool_names() == ~w(find grep list_directory fetch_url)
  end

  test "starts as a bundled registrar after the tool registry" do
    table = :"read_only_pack_service_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, name: table})
    start_supervised!({ReadOnly, name: :"#{table}_pack", registry: table})

    for name <- ReadOnly.tool_names() do
      assert {:ok, %Spec{source: {:bundle, :read_only_tools}}} = Registry.lookup(table, name)
    end
  end

  test "registers read-only tools as source-owned specs with stable metadata", %{table: table} do
    assert :ok = ReadOnly.register(table)

    before_metadata =
      MingaAgent.Tools.all(project_root: ".")
      |> Map.new(fn tool -> {tool.name, {tool.description, tool.parameter_schema}} end)

    for name <- ReadOnly.tool_names() do
      assert {:ok, %Spec{} = spec} = Registry.lookup(table, name)
      assert spec.source == ReadOnly.source()
      assert spec.approval_level == :auto
      assert spec.metadata == %{pack: :read_only_tools}
      assert {spec.description, spec.parameter_schema} == Map.fetch!(before_metadata, name)
    end

    assert {:ok, find_spec} = Registry.lookup(table, "find")
    assert find_spec.category == :filesystem
    assert find_spec.capabilities == [:read_project]
    assert find_spec.context_requirements == [:tool_context]

    assert {:ok, fetch_spec} = Registry.lookup(table, "fetch_url")
    assert fetch_spec.category == :network
    assert fetch_spec.capabilities == [:network]
    assert fetch_spec.context_requirements == []
  end

  test "bundled names stay reserved while the pack is unregistered", %{table: table} do
    assert :ok = ReadOnly.register(table)
    assert :ok = Registry.unregister_source(table, ReadOnly.source())

    collision =
      Spec.new!(
        source: {:extension, :demo},
        name: "find",
        description: "Override find",
        parameter_schema: %{},
        callback: fn _args -> {:ok, "override"} end
      )

    assert {:error, {:reserved_builtin_tool, "find", {:extension, :demo}}} =
             Registry.register(table, collision)
  end

  test "unregistering and re-registering the bundled source affects only pack tools", %{
    table: table
  } do
    other =
      Spec.new!(
        source: :config,
        name: "other_tool",
        description: "Other",
        parameter_schema: %{},
        callback: fn _args -> {:ok, "other"} end
      )

    assert :ok = Registry.register(table, other)
    assert :ok = ReadOnly.register(table)

    assert :ok = Registry.unregister_source(table, ReadOnly.source())
    assert {:ok, ^other} = Registry.lookup(table, "other_tool")

    for name <- ReadOnly.tool_names() do
      assert :error = Registry.lookup(table, name)
    end

    assert :ok = ReadOnly.register(table)

    for name <- ReadOnly.tool_names() do
      assert {:ok, %Spec{source: {:bundle, :read_only_tools}}} = Registry.lookup(table, name)
    end
  end

  test "pack tools execute through bundled specs", %{table: table} do
    root =
      Path.join(
        System.tmp_dir!(),
        "minga-read-only-pack-exec-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "nested"))
    File.write!(Path.join(root, "nested/target.txt"), "needle")

    on_exit(fn -> File.rm_rf!(root) end)

    context = ToolContext.new(project_root: root)
    assert :ok = ReadOnly.register(table)

    assert {:ok, find_result} =
             Executor.execute("find", %{"pattern" => "*.txt"}, table, :exec,
               tool_context: context
             )

    assert find_result =~ "target.txt"

    assert {:ok, grep_result} =
             Executor.execute("grep", %{"pattern" => "needle"}, table, :exec,
               tool_context: context
             )

    assert grep_result =~ "target.txt"
    assert grep_result =~ "needle"

    assert {:error, fetch_error} = Executor.execute("fetch_url", %{"url" => "not-a-url"}, table)
    assert fetch_error =~ "http:// or https://"
  end

  test "pack tools keep read-only approval and project boundaries", %{table: table} do
    root =
      Path.join(System.tmp_dir!(), "minga-read-only-pack-#{System.unique_integer([:positive])}")

    File.rm_rf!(root)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "inside.txt"), "inside")
    outside = Path.join(System.tmp_dir!(), "outside-#{System.unique_integer([:positive])}.txt")
    File.write!(outside, "outside")

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(outside)
    end)

    context = ToolContext.new(project_root: root)
    assert :ok = ReadOnly.register(table)

    assert {:ok, result} =
             Executor.execute("list_directory", %{"path" => "."}, table, :exec,
               tool_context: context
             )

    assert result =~ "inside.txt"

    assert {:error, reason} =
             Executor.execute("list_directory", %{"path" => outside}, table, :exec,
               tool_context: context
             )

    assert inspect(reason) =~ "outside"
  end

  test "same-source pack registration replaces but other sources cannot take pack names", %{
    table: table
  } do
    assert :ok = ReadOnly.register(table)
    assert :ok = ReadOnly.register(table)

    collision =
      Spec.new!(
        source: {:extension, :demo},
        name: "find",
        description: "Override find",
        parameter_schema: %{},
        callback: fn _args -> {:ok, "override"} end
      )

    assert {:error, {:reserved_builtin_tool, "find", {:extension, :demo}}} =
             Registry.register(table, collision)
  end
end
