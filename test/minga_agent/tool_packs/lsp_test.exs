defmodule MingaAgent.ToolPacks.LSPTest do
  # async: false because provider reload tests mutate the global agent tool registry.
  use ExUnit.Case, async: false

  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Providers.Native
  alias MingaAgent.Tool.Context, as: ToolContext
  alias MingaAgent.Tool.Executor
  alias MingaAgent.Tool.Registry
  alias MingaAgent.Tool.Spec
  alias MingaAgent.ToolPacks.LSP

  setup do
    table = :"lsp_pack_test_#{System.unique_integer([:positive])}"
    :ets.new(table, [:named_table, :set, :public, read_concurrency: true])

    on_exit(fn ->
      if :ets.whereis(table) != :undefined, do: :ets.delete(table)
      LSP.register()
    end)

    %{table: table}
  end

  test "declares the bundled source and stable LSP tool names" do
    assert LSP.source() == {:bundle, :lsp_tools}

    assert LSP.tool_names() ==
             ~w(diagnostics definition references hover document_symbols workspace_symbols rename code_actions)

    builtin_names = Enum.map(MingaAgent.Tools.builtin_specs(), & &1.name)
    refute Enum.any?(LSP.tool_names(), &(&1 in builtin_names))
  end

  test "starts as a bundled registrar after the tool registry" do
    table = :"lsp_pack_service_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, name: table})
    start_supervised!({LSP, name: :"#{table}_lsp_pack", registry: table})

    names = Registry.all(table) |> Enum.map(& &1.name)

    for name <- LSP.tool_names() do
      assert {:ok, %Spec{source: {:bundle, :lsp_tools}}} = Registry.lookup(table, name)
      assert Enum.count(names, &(&1 == name)) == 1
    end
  end

  test "registers LSP tools as source-owned specs with stable metadata", %{table: table} do
    assert :ok = LSP.register(table)

    before_metadata =
      MingaAgent.Tools.all(project_root: ".")
      |> Map.new(fn tool -> {tool.name, {tool.description, tool.parameter_schema}} end)

    for name <- LSP.tool_names() do
      assert {:ok, %Spec{} = spec} = Registry.lookup(table, name)
      assert spec.source == LSP.source()
      assert spec.category == :lsp
      assert spec.context_requirements == [:tool_context]
      assert spec.metadata.pack == :lsp_tools
      assert {spec.description, spec.parameter_schema} == Map.fetch!(before_metadata, name)
    end

    for name <- ~w(diagnostics definition references hover document_symbols workspace_symbols) do
      assert {:ok, spec} = Registry.lookup(table, name)
      assert spec.approval_level == :auto
      assert spec.capabilities == [:lsp_read]
      assert spec.metadata.destructive == false
    end

    assert {:ok, rename} = Registry.lookup(table, "rename")
    assert rename.approval_level == :ask
    assert rename.capabilities == [:lsp_mutate]
    assert rename.metadata.destructive == true

    assert {:ok, code_actions} = Registry.lookup(table, "code_actions")
    assert code_actions.approval_level == :ask
    assert code_actions.capabilities == [:lsp_read, :lsp_mutate]
    assert code_actions.metadata.destructive == :conditional
  end

  test "unregistering and re-registering the LSP source affects only LSP tools", %{table: table} do
    other =
      Spec.new!(
        source: :config,
        name: "other_tool",
        description: "Other",
        parameter_schema: %{},
        callback: fn _args -> {:ok, "other"} end
      )

    assert :ok = Registry.register(table, other)
    assert :ok = LSP.register(table)
    assert :ok = Registry.unregister_source(table, LSP.source())
    assert {:ok, ^other} = Registry.lookup(table, "other_tool")

    for name <- LSP.tool_names() do
      assert :error = Registry.lookup(table, name)
    end

    assert :ok = LSP.register(table)
    assert :ok = LSP.register(table)

    names = Registry.all(table) |> Enum.map(& &1.name)

    for name <- LSP.tool_names() do
      assert {:ok, %Spec{source: {:bundle, :lsp_tools}}} = Registry.lookup(table, name)
      assert Enum.count(names, &(&1 == name)) == 1
    end
  end

  test "LSP bundled names stay reserved while the pack is unregistered", %{table: table} do
    assert :ok = LSP.register(table)
    assert :ok = Registry.unregister_source(table, LSP.source())

    for name <- ["definition", "rename"] do
      collision =
        Spec.new!(
          source: {:extension, :demo},
          name: name,
          description: "Override #{name}",
          parameter_schema: %{},
          callback: fn _args -> {:ok, "override"} end
        )

      assert {:error, {:reserved_builtin_tool, ^name, {:extension, :demo}}} =
               Registry.register(table, collision)
    end
  end

  test "read-only LSP tools execute automatically through pack specs", %{table: table} do
    root = Path.join(System.tmp_dir!(), "minga-lsp-pack-#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/foo.ex"), "defmodule Foo do\nend\n")
    on_exit(fn -> File.rm_rf!(root) end)

    context = ToolContext.new(project_root: root)
    assert :ok = LSP.register(table)

    assert {:ok, diagnostics} =
             Executor.execute("diagnostics", %{"path" => "lib/foo.ex"}, table, :exec,
               tool_context: context
             )

    assert diagnostics =~ "No diagnostics"

    for name <- ~w(definition references hover document_symbols) do
      args = lsp_position_args(name)
      assert {:ok, text} = Executor.execute(name, args, table, :exec, tool_context: context)
      refute match?({:needs_approval, _, _}, text)
    end
  end

  test "mutating LSP tools require approval before LSP lookup", %{table: table} do
    root =
      Path.join(
        System.tmp_dir!(),
        "minga-lsp-pack-approval-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/foo.ex"), "defmodule Foo do\nend\n")
    on_exit(fn -> File.rm_rf!(root) end)

    context = ToolContext.new(project_root: root)
    assert :ok = LSP.register(table)

    rename_args = %{"path" => "lib/foo.ex", "line" => 0, "column" => 10, "new_name" => "Bar"}

    assert {:needs_approval, %Spec{name: "rename", source: {:bundle, :lsp_tools}}, ^rename_args} =
             Executor.execute("rename", rename_args, table, :exec, tool_context: context)

    code_action_args = %{"path" => "lib/foo.ex", "line" => 0, "apply" => 1}

    assert {:needs_approval, %Spec{name: "code_actions", source: {:bundle, :lsp_tools}},
            ^code_action_args} =
             Executor.execute("code_actions", code_action_args, table, :exec,
               tool_context: context
             )
  end

  test "active providers remove and restore LSP pack tools when the source reloads" do
    LSP.register()

    {:ok, provider} =
      Native.start_link(
        subscriber: self(),
        model: "anthropic:claude-sonnet-4-20250514",
        project_root: System.tmp_dir!(),
        config: %AgentConfig{},
        skip_api_key_env: true
      )

    assert_provider_tool(provider, "definition")
    assert_provider_tool(provider, "rename")

    assert :ok = Registry.unregister_source(LSP.source())
    :sys.get_state(provider)

    refute_provider_tool(provider, "definition")
    refute_provider_tool(provider, "rename")

    assert :ok = LSP.register()
    :sys.get_state(provider)

    names = provider_tool_names(provider)

    for name <- LSP.tool_names() do
      assert name in names
      assert Enum.count(names, &(&1 == name)) == 1
    end
  end

  test "read-only native providers include read-only LSP tools and exclude mutating LSP tools" do
    LSP.register()

    {:ok, provider} =
      Native.start_link(
        subscriber: self(),
        model: "anthropic:claude-sonnet-4-20250514",
        project_root: System.tmp_dir!(),
        config: %AgentConfig{},
        read_only?: true,
        skip_api_key_env: true
      )

    names = provider_tool_names(provider)

    for name <- ~w(diagnostics definition references hover document_symbols workspace_symbols) do
      assert name in names
    end

    refute "rename" in names
    refute "code_actions" in names
  end

  defp lsp_position_args("document_symbols"), do: %{"path" => "lib/foo.ex"}

  defp lsp_position_args(_name), do: %{"path" => "lib/foo.ex", "line" => 0, "column" => 0}

  defp provider_tool_names(provider) do
    provider
    |> Native.tools()
    |> Enum.map(& &1.name)
  end

  defp assert_provider_tool(provider, name) do
    assert name in provider_tool_names(provider)
  end

  defp refute_provider_tool(provider, name) do
    refute name in provider_tool_names(provider)
  end
end
