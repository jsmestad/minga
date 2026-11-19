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

  test "rejects conflicting callback and build declarations" do
    assert {:error, {:conflicting_execution_declarations, [:build, :callback]}} =
             Spec.new(
               source: :config,
               name: "conflicting",
               description: "Conflicting",
               parameter_schema: %{},
               callback: fn _args -> :callback end,
               build: fn _context -> fn _args -> :build end end
             )
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

  test "rejects unknown bundle sources" do
    assert {:error, {:invalid_source, {:bundle, :fake}}} =
             Spec.new(
               source: {:bundle, :fake},
               name: "fake_bundle_tool",
               description: "Fake",
               parameter_schema: %{},
               callback: fn _args -> :ok end
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

  test "canonical required fields, types, and constraints reject invalid SDK and generic arguments" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "minLength" => 1},
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 4}
      },
      "required" => ["path", "limit"],
      "additionalProperties" => false
    }

    sdk_tool =
      ReqLLM.Tool.new!(
        name: "bounded_read",
        description: "Read a bounded number of entries",
        parameter_schema: schema,
        callback: fn args -> {:ok, args} end
      )

    for metadata <- [%{}, %{sdk_input: sdk_tool}] do
      spec =
        Spec.new!(
          name: "bounded_read",
          description: "Read a bounded number of entries",
          parameter_schema: schema,
          metadata: metadata,
          build: fn _context -> raise "validation must not build an executable callback" end
        )

      for args <- [
            %{"path" => "file"},
            %{"path" => 42, "limit" => 2},
            %{"path" => "", "limit" => 2},
            %{"path" => "file", "limit" => "2"},
            %{"path" => "file", "limit" => 0},
            %{"path" => "file", "limit" => 5},
            %{"path" => "file", "limit" => 2, "extra" => true}
          ] do
        assert {:error, %JSV.ValidationError{}} = Spec.validate_arguments(spec, args)
      end

      assert {:ok, %{"path" => "file", "limit" => 2}} =
               Spec.validate_arguments(spec, %{"path" => "file", "limit" => 2})
    end
  end

  test "canonical checks preserve SDK normalization and default arguments for valid calls" do
    sdk_tool =
      ReqLLM.Tool.new!(
        name: "read_mode",
        description: "Select a read mode",
        parameter_schema: [
          path: [type: :string, required: true],
          verbose: [type: :boolean, default: false]
        ],
        callback: fn args -> {:ok, args} end
      )

    %{"function" => %{"parameters" => schema}} = ReqLLM.Tool.to_schema(sdk_tool, :openai)

    spec =
      Spec.new!(
        name: sdk_tool.name,
        description: sdk_tool.description,
        parameter_schema: schema,
        metadata: %{sdk_input: sdk_tool},
        build: fn _context -> raise "validation must not build an executable callback" end
      )

    for args <- [%{"path" => "file"}, %{path: "file"}] do
      assert {:ok, %{path: "file", verbose: false}} = Spec.validate_arguments(spec, args)
    end
  end

  test "nested local arguments validate without changing callback values or accepting ambiguous keys" do
    spec =
      Spec.new!(
        name: "inspect_entries",
        description: "Inspect bounded entries",
        parameter_schema: %{
          "type" => "object",
          "properties" => %{
            "entries" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "mode" => %{"enum" => ["read"]},
                  "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 4}
                },
                "required" => ["mode", "limit"],
                "additionalProperties" => false
              }
            }
          },
          "required" => ["entries"],
          "additionalProperties" => false
        },
        build: fn _context -> raise "validation must not build a callback" end
      )

    valid = %{entries: [%{mode: :read, limit: 2}]}
    assert {:ok, ^valid} = Spec.validate_arguments(spec, valid)

    assert {:error, %JSV.ValidationError{}} =
             Spec.validate_arguments(spec, %{entries: [%{mode: :read, limit: 5}]})

    assert {:error, {:invalid_tool_arguments, {:ambiguous_key, "limit"}}} =
             Spec.validate_arguments(spec, %{
               entries: [%{"limit" => 2, limit: 5, mode: :read}]
             })

    for value <- [self(), make_ref(), fn -> :unexpected end, %URI{}, [1 | :improper]] do
      assert {:error, {:invalid_tool_arguments, :non_json_value}} =
               Spec.validate_arguments(spec, %{entries: value})
    end
  end

  test "regex budget exhaustion cannot bypass declared argument constraints" do
    pattern = "^(?:(a+)+b|a+!)$"
    subject = String.duplicate("a", 20) <> "!"

    for {schema, args} <- [
          {%{"patternProperties" => %{pattern => %{"type" => "integer"}}},
           %{subject => "not an integer"}},
          {%{"properties" => %{"value" => %{"not" => %{"pattern" => pattern}}}},
           %{"value" => subject}}
        ] do
      spec =
        Spec.new!(
          name: "guarded_pattern",
          description: "Validate pattern-constrained arguments",
          parameter_schema: Map.put(schema, "type", "object"),
          build: fn _context -> raise "invalid input must never build a callback" end
        )

      assert {:error, %JSV.ValidationError{}} = Spec.validate_arguments(spec, args)
    end
  end
end
