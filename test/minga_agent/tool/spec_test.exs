defmodule MingaAgent.Tool.SpecTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Tool.Context
  alias MingaAgent.Tool.Spec
  alias MingaAgent.ToolRouter

  test "context-bound specs declare source metadata and build executable callbacks" do
    build = fn %Context{project_root: root} ->
      fn args -> {:ok, {root, args}} end
    end

    assert {:ok, spec} =
             Spec.new(
               source: {:extension, :demo},
               name: "demo_write",
               description: "Demo write",
               parameter_schema: %{"type" => "object"},
               category: :filesystem,
               approval_level: :ask,
               capabilities: [:mutate_project],
               context_requirements: [:tool_context],
               build: build,
               metadata: %{display_name: "Demo Write"}
             )

    assert spec.source == {:extension, :demo}
    assert spec.capabilities == [:mutate_project]
    assert spec.context_requirements == [:tool_context]

    context = Context.new(project_root: "/tmp/demo", router_context: ToolRouter.context(nil, nil))
    callback = Spec.build_callback(spec, context)
    assert {:ok, {"/tmp/demo", %{"path" => "file.txt"}}} = callback.(%{"path" => "file.txt"})
  end

  test "rejects invalid context-bound build functions" do
    assert {:error, {:invalid_build, :not_a_function}} =
             Spec.new(
               source: :config,
               name: "bad",
               description: "Bad",
               parameter_schema: %{},
               build: :not_a_function
             )
  end

  test "mutating filesystem specs must require tool context" do
    assert {:error, {:missing_context_requirement, :tool_context}} =
             Spec.new(
               source: :config,
               name: "unsafe_write",
               description: "Unsafe",
               parameter_schema: %{},
               category: :filesystem,
               capabilities: [:mutate_project],
               build: fn _context -> fn _args -> :ok end end
             )
  end
end
