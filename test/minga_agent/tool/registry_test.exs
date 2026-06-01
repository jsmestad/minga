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
      source: :config,
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

    test "same-source registration replaces an existing custom tool", %{table: table} do
      spec1 = sample_spec()

      spec2 =
        Spec.new!(
          source: :config,
          name: "test_tool",
          description: "Updated",
          parameter_schema: %{},
          callback: fn _ -> :ok end
        )

      assert :ok = Registry.register(table, spec1)
      assert :ok = Registry.register(table, spec2)

      {:ok, found} = Registry.lookup(table, "test_tool")
      assert found.description == "Updated"
    end

    test "cross-source duplicate custom names fail deterministically", %{table: table} do
      first =
        Spec.new!(
          source: {:extension, :one},
          name: "custom",
          description: "One",
          parameter_schema: %{},
          callback: fn _ -> :ok end
        )

      second =
        Spec.new!(
          source: {:extension, :two},
          name: "custom",
          description: "Two",
          parameter_schema: %{},
          callback: fn _ -> :ok end
        )

      assert :ok = Registry.register(table, first)

      assert {:error, {:duplicate_tool_name, "custom", {:extension, :one}, {:extension, :two}}} =
               Registry.register(table, second)
    end

    test "built-in tool names are reserved for builtin source", %{table: table} do
      spec =
        Spec.new!(
          source: {:extension, :demo},
          name: "read_file",
          description: "Read",
          parameter_schema: %{},
          callback: fn _ -> :ok end
        )

      assert {:error, {:reserved_builtin_tool, "read_file", {:extension, :demo}}} =
               Registry.register(table, spec)
    end

    test "unregister_source removes all matching tool contributions", %{table: table} do
      source = {:extension, :demo}

      assert :ok =
               Registry.register(
                 table,
                 Spec.new!(
                   source: source,
                   name: "one",
                   description: "One",
                   parameter_schema: %{},
                   callback: fn _ -> :ok end
                 )
               )

      assert :ok =
               Registry.register(
                 table,
                 Spec.new!(
                   source: source,
                   name: "two",
                   description: "Two",
                   parameter_schema: %{},
                   callback: fn _ -> :ok end
                 )
               )

      assert :ok =
               Registry.register(
                 table,
                 Spec.new!(
                   source: {:extension, :other},
                   name: "other",
                   description: "Other",
                   parameter_schema: %{},
                   callback: fn _ -> :ok end
                 )
               )

      assert :ok = Registry.unregister_source(table, source)
      assert :error = Registry.lookup(table, "one")
      assert :error = Registry.lookup(table, "two")
      assert {:ok, _spec} = Registry.lookup(table, "other")
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

  describe "GenServer lifecycle" do
    test "concurrent cross-source duplicate registration through service has one winner" do
      table = :"registry_concurrent_#{:erlang.unique_integer([:positive])}"
      start_supervised!(%{id: table, start: {Registry, :start_link, [[name: table]]}})
      parent = self()

      make_spec = fn source ->
        Spec.new!(
          source: source,
          name: "race_tool",
          description: "Race",
          parameter_schema: %{},
          callback: fn _ -> :ok end
        )
      end

      tasks =
        for source <- [{:extension, :a}, {:extension, :b}] do
          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> Registry.register(table, make_spec.(source))
            end
          end)
        end

      assert_receive {:ready, pid1}
      assert_receive {:ready, pid2}
      send(pid1, :go)
      send(pid2, :go)
      results = Enum.map(tasks, &Task.await/1)

      assert Enum.count(results, &(&1 == :ok)) == 1

      assert Enum.count(results, &match?({:error, {:duplicate_tool_name, "race_tool", _, _}}, &1)) ==
               1
    end

    test "init registers exactly the builtin tools" do
      table = :"registry_init_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Registry, name: table, project_root: "."})

      expected_names =
        MingaAgent.Tools.all(project_root: ".") |> Enum.map(& &1.name) |> MapSet.new()

      registered_names = Registry.all(table) |> Enum.map(& &1.name) |> MapSet.new()

      assert expected_names == registered_names

      {:ok, read_spec} = Registry.lookup(table, "read_file")
      assert read_spec.source == :builtin
      assert read_spec.category == :filesystem
      assert read_spec.approval_level == :auto
      assert read_spec.capabilities == [:read_project]
      assert read_spec.context_requirements == [:tool_context]
      assert is_function(read_spec.build, 1)

      {:ok, write_spec} = Registry.lookup(table, "write_file")
      assert write_spec.source == :builtin
      assert write_spec.category == :filesystem
      assert write_spec.approval_level == :ask
      assert write_spec.capabilities == [:mutate_project]
      assert write_spec.context_requirements == [:tool_context]
      assert is_function(write_spec.build, 1)
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
      assert spec.source == :config
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
