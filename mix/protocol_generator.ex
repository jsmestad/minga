defmodule Minga.Mix.ProtocolGenerator do
  @moduledoc """
  Generates protocol opcode artifacts from `docs/protocol_schema.toml`.

  The schema is the source of truth. Generated protocol artifacts are written under `.generated/protocol/` for Elixir, `macos/.generated/protocol/` for Swift, `zig/src/generated/` for Zig, `rust/tui/src/generated/` for the Rust TUI, and `go/tui/internal/generated/` for the Go TUI. The generated Zig public export block in `zig/src/protocol.zig` is also refreshed from the schema.
  """

  @schema_path "docs/protocol_schema.toml"
  @generated_root ".generated/protocol"
  @generated_elixir_path Path.join([@generated_root, "elixir/lib/minga/protocol/opcodes.ex"])
  @generated_swift_path "macos/.generated/protocol/ProtocolOpcodes.generated.swift"
  @generated_zig_opcodes_path "zig/src/generated/protocol_opcodes.zig"
  @generated_zig_schema_test_path "zig/src/generated/protocol_schema_test.zig"
  @generated_rust_opcodes_path "rust/tui/src/generated/opcodes.rs"
  @generated_go_opcodes_path "go/tui/internal/generated/opcodes.go"
  @generated_go_command_size_path "go/tui/internal/generated/command_size.go"
  @generated_rust_command_size_path "rust/tui/src/generated/command_size.rs"
  @generated_zig_command_size_path "zig/src/generated/protocol_command_size.zig"
  @generated_swift_command_size_path "macos/.generated/protocol/ProtocolCommandSize.generated.swift"
  @generated_rust_semantic_types_path "rust/tui/src/generated/semantic_types.rs"
  @generated_rust_semantic_decode_path "rust/tui/src/generated/semantic_decode.rs"
  @generated_go_semantic_types_path "go/tui/internal/generated/semantic_types.go"
  @generated_go_semantic_decode_path "go/tui/internal/generated/semantic_decode.go"
  @protocol_zig_path "zig/src/protocol.zig"
  @allowed_opcode_categories [
    "input",
    "render",
    "config",
    "parser_commands",
    "parser_responses",
    "gui_chrome",
    "gui_semantic"
  ]
  @allowed_opcode_directions [
    "frontend_to_beam",
    "beam_to_frontend",
    "beam_to_parser",
    "parser_to_beam"
  ]

  @type opcode :: %{String.t() => term()}
  @type gui_action :: %{String.t() => term()}
  @type schema :: %{String.t() => term()}
  @type generated_file :: {Path.t(), String.t()}

  @spec run([String.t()]) :: :ok
  def run(args) do
    ensure_generator_deps_loaded!()

    {opts, _argv, _invalid} = OptionParser.parse(args, strict: [check: :boolean])
    schema = load_schema!()
    files = generated_files(schema)

    case Keyword.get(opts, :check, false) do
      true ->
        check_files!(files)
        check_zig_protocol_exports!(schema)

      false ->
        write_files!(files)
        sync_zig_protocol_exports!(schema)
    end
  end

  @spec ensure_generator_deps_loaded!() :: :ok
  defp ensure_generator_deps_loaded! do
    case Code.ensure_loaded(Toml) do
      {:module, Toml} -> :ok
      {:error, _reason} -> Mix.Task.run("deps.loadpaths", [])
    end
  end

  @spec load_schema!() :: schema()
  defp load_schema! do
    case @schema_path |> File.read!() |> Toml.decode() do
      {:ok, schema} -> validate_schema!(schema)
      {:error, reason} -> Mix.raise("Failed to parse #{@schema_path}: #{inspect(reason)}")
    end
  end

  @spec validate_schema!(schema()) :: schema()
  defp validate_schema!(schema) do
    validate_opcode_categories!(schema)
    validate_opcode_directions!(schema)
    validate_duplicate_values!(Map.fetch!(schema, "opcodes"), "opcode")
    validate_duplicate_values!(Map.fetch!(schema, "gui_actions"), "GUI action")
    validate_gui_action_canonicals!(Map.fetch!(schema, "gui_actions"))
    validate_framing!(schema)
    validate_structures!(schema)
    validate_sections!(schema)
    validate_command_fields!(schema)
    schema
  end

  @spec generated_files(schema()) :: [generated_file()]
  defp generated_files(schema) do
    [
      {@generated_elixir_path, elixir_file(schema)},
      {@generated_swift_path, swift_file(schema)},
      {@generated_zig_opcodes_path, zig_opcodes_file(schema)},
      {@generated_zig_schema_test_path, zig_schema_test_file(schema)},
      {@generated_rust_opcodes_path, rust_opcodes_file(schema)},
      {@generated_go_opcodes_path, go_opcodes_file(schema)},
      {@generated_go_command_size_path, go_command_size_file(schema)},
      {@generated_rust_command_size_path, rust_command_size_file(schema)},
      {@generated_zig_command_size_path, zig_command_size_file(schema)},
      {@generated_swift_command_size_path, swift_command_size_file(schema)},
      {@generated_rust_semantic_types_path, rust_semantic_types_file(schema)},
      {@generated_rust_semantic_decode_path, rust_semantic_decode_file(schema)},
      {@generated_go_semantic_types_path, go_semantic_types_file(schema)},
      {@generated_go_semantic_decode_path, go_semantic_decode_file(schema)}
    ]
  end

  @spec write_files!([generated_file()]) :: :ok
  defp write_files!(files) do
    Enum.each(files, fn {path, content} ->
      path |> Path.dirname() |> File.mkdir_p!()
      write_if_changed!(path, content)
    end)
  end

  @spec write_if_changed!(Path.t(), String.t()) :: :ok
  defp write_if_changed!(path, content) do
    case File.read(path) do
      {:ok, ^content} -> :ok
      _other -> File.write!(path, content)
    end
  end

  @spec format_generated_go_file(String.t()) :: String.t()
  defp format_generated_go_file(binary) do
    case System.find_executable("gofmt") do
      nil ->
        binary

      _path ->
        path =
          Path.join(System.tmp_dir!(), "minga_protocol_#{System.unique_integer([:positive])}.go")

        File.write!(path, binary)

        try do
          case System.cmd("gofmt", ["-w", path]) do
            {_output, 0} -> File.read!(path)
            {_output, _code} -> binary
          end
        after
          File.rm(path)
        end
    end
  end

  @spec check_files!([generated_file()]) :: :ok
  defp check_files!(files) do
    stale =
      Enum.filter(files, fn {path, expected} ->
        case File.read(path) do
          {:ok, actual} -> actual != expected
          {:error, _reason} -> true
        end
      end)

    case stale do
      [] -> :ok
      _ -> Mix.raise(outdated_message(stale))
    end
  end

  @spec sync_zig_protocol_exports!(schema()) :: :ok
  defp sync_zig_protocol_exports!(schema) do
    expected = zig_protocol_export_block(schema)
    current = read_protocol_zig!()
    updated = replace_zig_protocol_export_block!(current, expected)
    write_if_changed!(@protocol_zig_path, updated)
  end

  @spec check_zig_protocol_exports!(schema()) :: :ok
  defp check_zig_protocol_exports!(schema) do
    expected = zig_protocol_export_block(schema)
    current = read_protocol_zig!()

    case current == replace_zig_protocol_export_block!(current, expected) do
      true -> :ok
      false -> Mix.raise(outdated_zig_protocol_exports_message())
    end
  end

  @spec read_protocol_zig!() :: String.t()
  defp read_protocol_zig! do
    case File.read(@protocol_zig_path) do
      {:ok, content} -> content
      {:error, reason} -> Mix.raise("Failed to read #{@protocol_zig_path}: #{inspect(reason)}")
    end
  end

  @spec replace_zig_protocol_export_block!(String.t(), String.t()) :: String.t()
  defp replace_zig_protocol_export_block!(content, replacement) do
    start_marker =
      "// BEGIN GENERATED OPCODE EXPORTS. Regenerate with `mix protocol.gen`. Do not edit by hand."

    end_marker = "// END GENERATED OPCODE EXPORTS."
    pattern = ~r/#{Regex.escape(start_marker)}.*?#{Regex.escape(end_marker)}\n?/s

    case Regex.run(pattern, content) do
      nil -> Mix.raise("Missing generated opcode export markers in #{@protocol_zig_path}")
      _match -> Regex.replace(pattern, content, replacement, global: false)
    end
  end

  @spec outdated_zig_protocol_exports_message() :: String.t()
  defp outdated_zig_protocol_exports_message do
    "Generated Zig protocol opcode exports are out of date. Run `mix protocol.gen` to regenerate the public protocol boundary.\n  - #{@protocol_zig_path}"
  end

  @spec outdated_message([generated_file()]) :: String.t()
  defp outdated_message(stale) do
    paths = Enum.map_join(stale, "\n", fn {path, _content} -> "  - #{path}" end)

    "Generated protocol artifacts are out of date. Run `mix protocol.gen` to regenerate build artifacts.\n#{paths}"
  end

  @spec elixir_file(schema()) :: String.t()
  defp elixir_file(schema) do
    opcodes = Map.fetch!(schema, "opcodes")
    actions = Map.fetch!(schema, "gui_actions")

    [
      "defmodule Minga.Protocol.Opcodes do\n",
      "  @moduledoc \"\"\"\n",
      "  Generated protocol opcode constants.\n\n",
      "  Generated from `docs/protocol_schema.toml` by `mix protocol.gen`. Do not edit by hand.\n",
      "  \"\"\"\n\n",
      elixir_opcode_functions(opcodes),
      "\n",
      elixir_gui_action_functions(actions),
      "end\n"
    ]
    |> IO.iodata_to_binary()
  end

  @spec elixir_opcode_functions([opcode()]) :: iodata()
  defp elixir_opcode_functions(opcodes) do
    opcodes
    |> group_by_category()
    |> Enum.map(fn {category, entries} ->
      ["  # ", category_title(category), "\n", Enum.map(entries, &elixir_opcode_function/1), "\n"]
    end)
  end

  @spec elixir_opcode_function(opcode()) :: String.t()
  defp elixir_opcode_function(%{"name" => name, "value" => value}) do
    "  @spec #{name}() :: non_neg_integer()\n  def #{name}, do: #{hex(value)}\n"
  end

  @spec elixir_gui_action_functions([gui_action()]) :: iodata()
  defp elixir_gui_action_functions(actions) do
    [
      "  # GUI action sub-opcodes (Frontend to BEAM)\n",
      Enum.map(actions, fn %{"name" => name, "value" => value} ->
        "  @spec gui_action_#{name}() :: non_neg_integer()\n  def gui_action_#{name}, do: #{hex(value)}\n"
      end),
      "\n"
    ]
  end

  @spec swift_file(schema()) :: String.t()
  defp swift_file(schema) do
    opcodes = Map.fetch!(schema, "opcodes")
    actions = Map.fetch!(schema, "gui_actions")
    structures = Map.get(schema, "structures", [])

    [
      "/// Generated protocol opcode constants.\n",
      "///\n",
      "/// Generated from `docs/protocol_schema.toml` by `mix protocol.gen`. Do not edit by hand.\n\n",
      swift_opcodes(opcodes),
      "\n// MARK: - GUI action sub-opcodes\n\n",
      Enum.map(actions, &swift_gui_action_line/1),
      swift_structure_sizes(structures)
    ]
    |> IO.iodata_to_binary()
  end

  @spec swift_structure_sizes([map()]) :: iodata()
  defp swift_structure_sizes([]), do: []

  defp swift_structure_sizes(structures) do
    structs_map = Map.new(structures, fn s -> {s["name"], s} end)

    size_lines =
      structures
      |> Enum.filter(fn s -> fixed_structure_size(s["name"], structs_map) != nil end)
      |> Enum.map(fn s ->
        size = fixed_structure_size(s["name"], structs_map)
        name = constant_name(s["name"])
        "let WIRE_#{name}_SIZE: Int = #{size}\n"
      end)

    case size_lines do
      [] -> []
      lines -> ["\n// MARK: - Wire structure sizes (from schema)\n\n" | lines]
    end
  end

  @spec swift_opcodes([opcode()]) :: iodata()
  defp swift_opcodes(opcodes) do
    opcodes
    |> group_by_category()
    |> Enum.map(fn {category, entries} ->
      [
        "// MARK: - ",
        category_title(category),
        "\n\n",
        Enum.map(entries, &swift_opcode_line/1),
        "\n"
      ]
    end)
  end

  @spec swift_opcode_line(opcode()) :: String.t()
  defp swift_opcode_line(%{"name" => name, "value" => value}) do
    "let OP_#{constant_name(name)}: UInt8 = #{hex(value)}\n"
  end

  @spec swift_gui_action_line(gui_action()) :: String.t()
  defp swift_gui_action_line(%{"name" => name, "value" => value}) do
    "let GUI_ACTION_#{constant_name(name)}: UInt8 = #{hex(value)}\n"
  end

  @spec zig_opcodes_file(schema()) :: String.t()
  defp zig_opcodes_file(schema) do
    opcodes = Map.fetch!(schema, "opcodes")
    actions = Map.fetch!(schema, "gui_actions")

    [
      "//! Generated protocol opcode constants.\n",
      "//!\n",
      "//! Generated from `docs/protocol_schema.toml` by `mix protocol.gen`. Do not edit by hand.\n\n",
      zig_opcodes(opcodes),
      "// GUI action sub-opcodes.\n\n",
      Enum.map(actions, &zig_gui_action_line/1)
    ]
    |> IO.iodata_to_binary()
  end

  @spec zig_protocol_export_block(schema()) :: String.t()
  defp zig_protocol_export_block(schema) do
    opcodes = Map.fetch!(schema, "opcodes")
    actions = Map.fetch!(schema, "gui_actions")

    [
      "// BEGIN GENERATED OPCODE EXPORTS. Regenerate with `mix protocol.gen`. Do not edit by hand.\n",
      zig_protocol_exports(opcodes),
      Enum.map(actions, &zig_protocol_gui_action_export_line/1),
      "// END GENERATED OPCODE EXPORTS.\n"
    ]
    |> IO.iodata_to_binary()
  end

  @spec zig_protocol_exports([opcode()]) :: iodata()
  defp zig_protocol_exports(opcodes) do
    opcodes
    |> group_by_category()
    |> Enum.map(fn {category, entries} ->
      [
        "// ",
        category_title(category),
        "\n",
        Enum.map(entries, &zig_protocol_opcode_export_line/1),
        "\n"
      ]
    end)
  end

  @spec zig_protocol_opcode_export_line(opcode()) :: String.t()
  defp zig_protocol_opcode_export_line(%{"name" => name}) do
    constant = "OP_#{constant_name(name)}"
    "pub const #{constant} = opcodes.#{constant};\n"
  end

  @spec zig_protocol_gui_action_export_line(gui_action()) :: String.t()
  defp zig_protocol_gui_action_export_line(%{"name" => name}) do
    constant = "GUI_ACTION_#{constant_name(name)}"
    "pub const #{constant} = opcodes.#{constant};\n"
  end

  @spec zig_opcodes([opcode()]) :: iodata()
  defp zig_opcodes(opcodes) do
    opcodes
    |> group_by_category()
    |> Enum.map(fn {category, entries} ->
      ["// ", category_title(category), "\n\n", Enum.map(entries, &zig_opcode_line/1), "\n"]
    end)
  end

  @spec zig_opcode_line(opcode()) :: String.t()
  defp zig_opcode_line(%{"name" => name, "value" => value}) do
    "pub const OP_#{constant_name(name)}: u8 = #{hex(value)};\n"
  end

  @spec zig_gui_action_line(gui_action()) :: String.t()
  defp zig_gui_action_line(%{"name" => name, "value" => value}) do
    "pub const GUI_ACTION_#{constant_name(name)}: u8 = #{hex(value)};\n"
  end

  @spec rust_opcodes_file(schema()) :: String.t()
  defp rust_opcodes_file(schema) do
    opcodes = Map.fetch!(schema, "opcodes")
    actions = Map.fetch!(schema, "gui_actions")

    [
      "// Generated protocol opcode constants.\n",
      "//\n",
      "// Generated from `docs/protocol_schema.toml` by `mix protocol.gen`. Do not edit by hand.\n\n",
      rust_opcodes(opcodes),
      "// GUI action sub-opcodes.\n\n",
      Enum.map(actions, &rust_gui_action_line/1)
    ]
    |> IO.iodata_to_binary()
  end

  @spec rust_opcodes([opcode()]) :: iodata()
  defp rust_opcodes(opcodes) do
    opcodes
    |> group_by_category()
    |> Enum.map(fn {category, entries} ->
      ["// ", category_title(category), "\n\n", Enum.map(entries, &rust_opcode_line/1), "\n"]
    end)
  end

  @spec rust_opcode_line(opcode()) :: String.t()
  defp rust_opcode_line(%{"name" => name, "value" => value}) do
    "pub const OP_#{constant_name(name)}: u8 = #{hex(value)};\n"
  end

  @spec rust_gui_action_line(gui_action()) :: String.t()
  defp rust_gui_action_line(%{"name" => name, "value" => value}) do
    "pub const GUI_ACTION_#{constant_name(name)}: u8 = #{hex(value)};\n"
  end

  @spec go_opcodes_file(schema()) :: String.t()
  defp go_opcodes_file(schema) do
    opcodes = Map.fetch!(schema, "opcodes")
    actions = Map.fetch!(schema, "gui_actions")

    [
      "// Code generated by mix protocol.gen. DO NOT EDIT.\n\n",
      "package generated\n\n",
      "const (\n",
      go_opcodes(opcodes),
      go_gui_actions(actions),
      ")\n"
    ]
    |> IO.iodata_to_binary()
    |> format_generated_go_file()
  end

  @spec go_opcodes([opcode()]) :: iodata()
  defp go_opcodes(opcodes) do
    opcodes
    |> group_by_category()
    |> Enum.map(fn {category, entries} ->
      width = go_const_width(entries, &go_opcode_const_name/1)

      [
        "\t// ",
        category_title(category),
        "\n",
        Enum.map(entries, &go_opcode_line(&1, width)),
        "\n"
      ]
    end)
  end

  @spec go_opcode_line(opcode(), non_neg_integer()) :: String.t()
  defp go_opcode_line(%{"value" => value} = opcode, width) do
    "\t#{String.pad_trailing(go_opcode_const_name(opcode), width)} byte = #{hex(value)}\n"
  end

  @spec go_gui_actions([gui_action()]) :: iodata()
  defp go_gui_actions(actions) do
    width = go_const_width(actions, &go_gui_action_const_name/1)
    Enum.map(actions, &go_gui_action_line(&1, width))
  end

  @spec go_gui_action_line(gui_action(), non_neg_integer()) :: String.t()
  defp go_gui_action_line(%{"value" => value} = action, width) do
    "\t#{String.pad_trailing(go_gui_action_const_name(action), width)} byte = #{hex(value)}\n"
  end

  @spec go_opcode_const_name(opcode()) :: String.t()
  defp go_opcode_const_name(%{"name" => name}) do
    "OP#{go_constant_name(name)}"
  end

  @spec go_gui_action_const_name(gui_action()) :: String.t()
  defp go_gui_action_const_name(%{"name" => name}) do
    "GUIAction#{go_constant_name(name)}"
  end

  @spec go_const_width([map()], (map() -> String.t())) :: non_neg_integer()
  defp go_const_width(entries, name_fun) do
    entries
    |> Enum.map(name_fun)
    |> Enum.map(&String.length/1)
    |> Enum.max(fn -> 0 end)
  end

  @spec zig_schema_test_file(schema()) :: String.t()
  defp zig_schema_test_file(schema) do
    opcodes = Map.fetch!(schema, "opcodes")
    actions = Map.fetch!(schema, "gui_actions")

    [
      "//! Generated protocol schema assertions.\n",
      "//!\n",
      "//! Generated from `docs/protocol_schema.toml` by `mix protocol.gen`. Do not edit by hand.\n\n",
      "const std = @import(\"std\");\n",
      "const protocol = @import(\"../protocol.zig\");\n",
      "const opcodes = @import(\"protocol_opcodes.zig\");\n\n",
      "test \"generated opcode constants match schema\" {\n",
      Enum.map(opcodes, &zig_opcode_expect_line/1),
      Enum.map(actions, &zig_gui_action_expect_line/1),
      "}\n\n",
      "test \"protocol re-exports generated opcode constants\" {\n",
      Enum.map(opcodes, &zig_opcode_reexport_expect_line/1),
      Enum.map(actions, &zig_gui_action_reexport_expect_line/1),
      "}\n\n",
      "test \"protocol exposes generated opcode declarations\" {\n",
      "    comptime {\n",
      Enum.map(opcodes, &zig_opcode_has_decl_line/1),
      Enum.map(actions, &zig_gui_action_has_decl_line/1),
      "    }\n",
      "}\n"
    ]
    |> IO.iodata_to_binary()
  end

  @spec zig_opcode_expect_line(opcode()) :: String.t()
  defp zig_opcode_expect_line(%{"name" => name, "value" => value}) do
    constant = constant_name(name)
    "    try std.testing.expectEqual(@as(u8, #{hex(value)}), opcodes.OP_#{constant});\n"
  end

  @spec zig_gui_action_expect_line(gui_action()) :: String.t()
  defp zig_gui_action_expect_line(%{"name" => name, "value" => value}) do
    constant = constant_name(name)
    "    try std.testing.expectEqual(@as(u8, #{hex(value)}), opcodes.GUI_ACTION_#{constant});\n"
  end

  @spec zig_opcode_reexport_expect_line(opcode()) :: String.t()
  defp zig_opcode_reexport_expect_line(%{"name" => name}) do
    constant = constant_name(name)
    "    try std.testing.expectEqual(opcodes.OP_#{constant}, protocol.OP_#{constant});\n"
  end

  @spec zig_gui_action_reexport_expect_line(gui_action()) :: String.t()
  defp zig_gui_action_reexport_expect_line(%{"name" => name}) do
    constant = constant_name(name)

    "    try std.testing.expectEqual(opcodes.GUI_ACTION_#{constant}, protocol.GUI_ACTION_#{constant});\n"
  end

  @spec zig_opcode_has_decl_line(opcode()) :: String.t()
  defp zig_opcode_has_decl_line(%{"name" => name}) do
    constant = "OP_#{constant_name(name)}"
    "        if (!@hasDecl(protocol, \"#{constant}\")) @compileError(\"missing #{constant}\");\n"
  end

  @spec zig_gui_action_has_decl_line(gui_action()) :: String.t()
  defp zig_gui_action_has_decl_line(%{"name" => name}) do
    constant = "GUI_ACTION_#{constant_name(name)}"
    "        if (!@hasDecl(protocol, \"#{constant}\")) @compileError(\"missing #{constant}\");\n"
  end

  @spec validate_opcode_categories!(schema()) :: :ok
  defp validate_opcode_categories!(schema) do
    invalid =
      schema
      |> Map.fetch!("opcodes")
      |> Enum.reject(fn entry -> Map.get(entry, "category") in @allowed_opcode_categories end)
      |> Enum.map_join(", ", fn entry -> "#{entry["name"]}(#{entry["category"]})" end)

    case invalid do
      "" -> :ok
      _ -> Mix.raise("Invalid opcode categories in #{@schema_path}: #{invalid}")
    end
  end

  @spec validate_opcode_directions!(schema()) :: :ok
  defp validate_opcode_directions!(schema) do
    invalid =
      schema
      |> Map.fetch!("opcodes")
      |> Enum.reject(fn entry -> Map.get(entry, "direction") in @allowed_opcode_directions end)
      |> Enum.map_join(", ", fn entry -> "#{entry["name"]}(#{entry["direction"]})" end)

    case invalid do
      "" -> :ok
      _ -> Mix.raise("Invalid opcode directions in #{@schema_path}: #{invalid}")
    end
  end

  @spec validate_duplicate_values!([opcode() | gui_action()], String.t()) :: :ok
  defp validate_duplicate_values!(entries, label) do
    duplicates =
      entries
      |> Enum.group_by(& &1["value"])
      |> Enum.filter(fn {_value, grouped} -> length(grouped) > 1 end)
      |> Enum.map_join(", ", fn {value, grouped} ->
        names = Enum.map_join(grouped, ", ", & &1["name"])
        "#{hex(value)}: #{names}"
      end)

    case duplicates do
      "" -> :ok
      _ -> Mix.raise("Duplicate #{label} values in #{@schema_path}: #{duplicates}")
    end
  end

  @spec validate_gui_action_canonicals!([gui_action()]) :: :ok
  defp validate_gui_action_canonicals!(actions) do
    action_names = MapSet.new(Enum.map(actions, & &1["name"]))

    invalid =
      actions
      |> Enum.flat_map(&invalid_canonical_reference(&1, action_names))
      |> Enum.join(", ")

    case invalid do
      "" -> :ok
      _ -> Mix.raise("Invalid gui_action canonical references in #{@schema_path}: #{invalid}")
    end
  end

  @spec invalid_canonical_reference(gui_action(), MapSet.t(String.t())) :: [String.t()]
  defp invalid_canonical_reference(%{"canonical" => nil}, _action_names), do: []

  defp invalid_canonical_reference(%{"canonical" => canonical, "name" => name}, action_names)
       when is_binary(canonical) do
    canonical_result(MapSet.member?(action_names, canonical), name, canonical)
  end

  defp invalid_canonical_reference(_action, _action_names), do: []

  @spec canonical_result(boolean(), String.t(), String.t()) :: [String.t()]
  defp canonical_result(true, _name, _canonical), do: []
  defp canonical_result(false, name, canonical), do: ["#{name} -> #{canonical}"]

  @spec group_by_category([opcode()]) :: [{String.t(), [opcode()]}]
  defp group_by_category(opcodes) do
    {groups, order} =
      Enum.reduce(opcodes, {%{}, []}, fn %{"category" => category} = opcode, {groups, order} ->
        order = add_category_order(order, category)
        groups = Map.update(groups, category, [opcode], &(&1 ++ [opcode]))
        {groups, order}
      end)

    Enum.map(order, fn category -> {category, Map.fetch!(groups, category)} end)
  end

  @spec add_category_order([String.t()], String.t()) :: [String.t()]
  defp add_category_order(order, category) do
    case category in order do
      true -> order
      false -> order ++ [category]
    end
  end

  @spec category_title(String.t()) :: String.t()
  defp category_title(category) do
    category
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  # ── Framing (command_size) ────────────────────────────────────────────────
  #
  # Every `beam_to_frontend` opcode declares a `framing` describing how a
  # frontend computes the on-wire byte length of one command so it can advance
  # through a batch. Kinds:
  #
  #   fixed:N    exactly N bytes
  #   len16      opcode(1) + payload_len(u16) + payload   => 3 + len
  #   len32      opcode(1) + payload_len(u32) + payload   => 5 + len
  #   sectioned  opcode(1) + section_count(u8) + sections => 2 + sum(3 + section_len)
  #   custom     bespoke layout; the frontend's decoder owns sizing
  #
  # The generated `command_size` functions size every generic framing and report
  # `custom` for the rest. New opcodes at 0x90+ are also handled by the
  # forward-compatible len16 fallback even before a frontend learns to size them.

  @allowed_simple_framings ~w(len16 len32 sectioned custom)

  @spec validate_framing!(schema()) :: :ok
  defp validate_framing!(schema) do
    invalid =
      schema
      |> Map.fetch!("opcodes")
      |> Enum.filter(&(Map.get(&1, "direction") == "beam_to_frontend"))
      |> Enum.reject(&valid_framing?(Map.get(&1, "framing")))
      |> Enum.map_join(", ", fn entry -> "#{entry["name"]}(#{inspect(entry["framing"])})" end)

    case invalid do
      "" ->
        :ok

      _ ->
        Mix.raise(
          "Missing/invalid framing for beam_to_frontend opcodes in #{@schema_path}: #{invalid}"
        )
    end
  end

  @spec valid_framing?(term()) :: boolean()
  defp valid_framing?(framing) when framing in @allowed_simple_framings, do: true
  defp valid_framing?("fixed:" <> rest), do: match?({_int, ""}, Integer.parse(rest))
  defp valid_framing?(_framing), do: false

  @spec framing_kind(opcode()) :: {:fixed, pos_integer()} | :len16 | :len32 | :sectioned | :custom
  defp framing_kind(%{"framing" => "fixed:" <> rest}), do: {:fixed, String.to_integer(rest)}
  defp framing_kind(%{"framing" => framing}), do: String.to_atom(framing)

  @spec framing_opcodes(schema()) :: [opcode()]
  defp framing_opcodes(schema) do
    schema
    |> Map.fetch!("opcodes")
    |> Enum.filter(&(Map.get(&1, "direction") == "beam_to_frontend"))
    |> Enum.sort_by(& &1["value"])
  end

  @spec parser_command_opcodes(schema()) :: [opcode()]
  defp parser_command_opcodes(schema) do
    schema
    |> Map.fetch!("opcodes")
    |> Enum.filter(&(Map.get(&1, "direction") == "beam_to_parser"))
    |> Enum.sort_by(& &1["value"])
  end

  @spec opcodes_of_kind([opcode()], term()) :: [opcode()]
  defp opcodes_of_kind(opcodes, kind), do: Enum.filter(opcodes, &(framing_kind(&1) == kind))

  @spec fixed_sizes([opcode()]) :: [pos_integer()]
  defp fixed_sizes(opcodes) do
    opcodes
    |> Enum.map(&framing_kind/1)
    |> Enum.flat_map(fn
      {:fixed, n} -> [n]
      _other -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec rust_swift_zig_const_name(opcode()) :: String.t()
  defp rust_swift_zig_const_name(%{"name" => name}), do: "OP_#{constant_name(name)}"

  # ── Go: command_size.go ───────────────────────────────────────────────────

  @spec go_command_size_file(schema()) :: String.t()
  defp go_command_size_file(schema) do
    ops = framing_opcodes(schema)
    cn = &go_opcode_const_name/1

    fixed_cases =
      Enum.map(fixed_sizes(ops), fn n ->
        names = ops |> opcodes_of_kind({:fixed, n}) |> Enum.map_join(", ", cn)
        "\tcase #{names}:\n\t\treturn fixedCommandSize(payload, #{n})\n"
      end)

    ("// Code generated by mix protocol.gen. DO NOT EDIT.\n\n" <>
       "package generated\n\n" <>
       "// CommandSizeStatus classifies the result of CommandSize.\n" <>
       "type CommandSizeStatus int\n\n" <>
       "const (\n" <>
       "\t// CommandSizeOK means the returned size is authoritative.\n" <>
       "\tCommandSizeOK CommandSizeStatus = iota\n" <>
       "\t// CommandSizeCustom means the opcode uses bespoke framing; size it with a decoder.\n" <>
       "\tCommandSizeCustom\n" <>
       "\t// CommandSizeIncomplete means payload is truncated; read more bytes.\n" <>
       "\tCommandSizeIncomplete\n" <>
       "\t// CommandSizeUnknown means the opcode is unknown and cannot be sized.\n" <>
       "\tCommandSizeUnknown\n" <>
       ")\n\n" <>
       "// CommandSize returns the on-wire byte length of the first command in\n" <>
       "// payload, derived from each opcode's schema framing. It is the single\n" <>
       "// authority a batch reader uses to advance between concatenated commands.\n" <>
       "func CommandSize(payload []byte) (int, CommandSizeStatus) {\n" <>
       "\tif len(payload) == 0 {\n\t\treturn 0, CommandSizeIncomplete\n\t}\n" <>
       "\tswitch payload[0] {\n" <>
       IO.iodata_to_binary(fixed_cases) <>
       "\tcase #{ops |> opcodes_of_kind(:len16) |> Enum.map_join(", ", cn)}:\n\t\treturn len16CommandSize(payload)\n" <>
       "\tcase #{ops |> opcodes_of_kind(:len32) |> Enum.map_join(", ", cn)}:\n\t\treturn len32CommandSize(payload)\n" <>
       "\tcase #{ops |> opcodes_of_kind(:sectioned) |> Enum.map_join(", ", cn)}:\n\t\treturn sectionedCommandSize(payload)\n" <>
       "\tcase #{ops |> opcodes_of_kind(:custom) |> Enum.map_join(", ", cn)}:\n\t\treturn 0, CommandSizeCustom\n" <>
       "\tdefault:\n" <>
       "\t\t// Forward-compatibility: opcodes >= 0x90 carry a u16 length prefix.\n" <>
       "\t\tif payload[0] >= 0x90 {\n\t\t\treturn len16CommandSize(payload)\n\t\t}\n" <>
       "\t\treturn 0, CommandSizeUnknown\n" <>
       "\t}\n}\n\n" <>
       go_command_size_helpers())
    |> format_generated_go_file()
  end

  @spec go_command_size_helpers() :: String.t()
  defp go_command_size_helpers do
    """
    func fixedCommandSize(payload []byte, size int) (int, CommandSizeStatus) {
    \tif len(payload) < size {
    \t\treturn 0, CommandSizeIncomplete
    \t}
    \treturn size, CommandSizeOK
    }

    func len16CommandSize(payload []byte) (int, CommandSizeStatus) {
    \tif len(payload) < 3 {
    \t\treturn 0, CommandSizeIncomplete
    \t}
    \tsize := 3 + int(payload[1])<<8 + int(payload[2])
    \tif len(payload) < size {
    \t\treturn 0, CommandSizeIncomplete
    \t}
    \treturn size, CommandSizeOK
    }

    func len32CommandSize(payload []byte) (int, CommandSizeStatus) {
    \tif len(payload) < 5 {
    \t\treturn 0, CommandSizeIncomplete
    \t}
    \tsize := 5 + int(payload[1])<<24 + int(payload[2])<<16 + int(payload[3])<<8 + int(payload[4])
    \tif len(payload) < size {
    \t\treturn 0, CommandSizeIncomplete
    \t}
    \treturn size, CommandSizeOK
    }

    func sectionedCommandSize(payload []byte) (int, CommandSizeStatus) {
    \tif len(payload) < 2 {
    \t\treturn 0, CommandSizeIncomplete
    \t}
    \toffset := 2
    \tcount := int(payload[1])
    \tfor i := 0; i < count; i++ {
    \t\tif len(payload) < offset+3 {
    \t\t\treturn 0, CommandSizeIncomplete
    \t\t}
    \t\toffset += 3 + int(payload[offset+1])<<8 + int(payload[offset+2])
    \t\tif len(payload) < offset {
    \t\t\treturn 0, CommandSizeIncomplete
    \t\t}
    \t}
    \treturn offset, CommandSizeOK
    }
    """
  end

  # ── Rust: command_size.rs ─────────────────────────────────────────────────

  @spec rust_command_size_file(schema()) :: String.t()
  defp rust_command_size_file(schema) do
    ops = framing_opcodes(schema)
    cn = &rust_swift_zig_const_name/1

    fixed_arms =
      Enum.map(fixed_sizes(ops), fn n ->
        names =
          ops
          |> opcodes_of_kind({:fixed, n})
          |> Enum.map_join("\n        | ", &"opcodes::#{cn.(&1)}")

        "        #{names} => fixed(payload, #{n}),\n"
      end)

    rust_arm = fn kind, call ->
      names =
        ops |> opcodes_of_kind(kind) |> Enum.map_join("\n        | ", &"opcodes::#{cn.(&1)}")

      "        #{names} => #{call},\n"
    end

    "// Generated protocol command sizing.\n" <>
      "//\n" <>
      "// Generated from `docs/protocol_schema.toml` by `mix protocol.gen`. Do not edit by hand.\n\n" <>
      "use crate::protocol::opcodes;\n\n" <>
      "/// Outcome of [`command_size`].\n" <>
      "#[derive(Debug, Clone, Copy, PartialEq, Eq)]\n" <>
      "pub enum CommandSize {\n" <>
      "    /// Authoritative on-wire byte length of the command.\n" <>
      "    Sized(usize),\n" <>
      "    /// Opcode uses bespoke framing; its decoder owns sizing.\n" <>
      "    Custom,\n" <>
      "    /// Payload is truncated; read more bytes.\n" <>
      "    Incomplete,\n" <>
      "    /// Opcode is unknown and cannot be sized.\n" <>
      "    Unknown,\n" <>
      "}\n\n" <>
      "/// Returns the on-wire byte length of the first command in `payload`,\n" <>
      "/// derived from each opcode's schema framing.\n" <>
      "pub fn command_size(payload: &[u8]) -> CommandSize {\n" <>
      "    let opcode = match payload.first() {\n" <>
      "        Some(byte) => *byte,\n" <>
      "        None => return CommandSize::Incomplete,\n" <>
      "    };\n" <>
      "    match opcode {\n" <>
      IO.iodata_to_binary(fixed_arms) <>
      rust_arm.(:len16, "len16(payload)") <>
      rust_arm.(:len32, "len32(payload)") <>
      rust_arm.(:sectioned, "sectioned(payload)") <>
      rust_arm.(:custom, "CommandSize::Custom") <>
      "        // Forward-compatibility: opcodes >= 0x90 carry a u16 length prefix.\n" <>
      "        _ if opcode >= 0x90 => len16(payload),\n" <>
      "        _ => CommandSize::Unknown,\n" <>
      "    }\n}\n\n" <>
      rust_command_size_helpers()
  end

  @spec rust_command_size_helpers() :: String.t()
  defp rust_command_size_helpers do
    """
    fn fixed(payload: &[u8], size: usize) -> CommandSize {
        if payload.len() < size {
            return CommandSize::Incomplete;
        }
        CommandSize::Sized(size)
    }

    fn len16(payload: &[u8]) -> CommandSize {
        if payload.len() < 3 {
            return CommandSize::Incomplete;
        }
        let size = 3 + ((payload[1] as usize) << 8 | payload[2] as usize);
        if payload.len() < size {
            return CommandSize::Incomplete;
        }
        CommandSize::Sized(size)
    }

    fn len32(payload: &[u8]) -> CommandSize {
        if payload.len() < 5 {
            return CommandSize::Incomplete;
        }
        let size = 5
            + ((payload[1] as usize) << 24
                | (payload[2] as usize) << 16
                | (payload[3] as usize) << 8
                | payload[4] as usize);
        if payload.len() < size {
            return CommandSize::Incomplete;
        }
        CommandSize::Sized(size)
    }

    fn sectioned(payload: &[u8]) -> CommandSize {
        if payload.len() < 2 {
            return CommandSize::Incomplete;
        }
        let mut offset = 2;
        let count = payload[1] as usize;
        for _ in 0..count {
            if payload.len() < offset + 3 {
                return CommandSize::Incomplete;
            }
            offset += 3 + ((payload[offset + 1] as usize) << 8 | payload[offset + 2] as usize);
            if payload.len() < offset {
                return CommandSize::Incomplete;
            }
        }
        CommandSize::Sized(offset)
    }
    """
  end

  # ── Zig: protocol_command_size.zig ────────────────────────────────────────

  @spec zig_command_size_file(schema()) :: String.t()
  defp zig_command_size_file(schema) do
    ops = framing_opcodes(schema)
    cn = &rust_swift_zig_const_name/1

    fixed_arms =
      Enum.map(fixed_sizes(ops), fn n ->
        names = ops |> opcodes_of_kind({:fixed, n}) |> Enum.map_join(", ", &"opcodes.#{cn.(&1)}")
        "        #{names} => fixed(payload, #{n}),\n"
      end)

    zig_arm = fn kind, call ->
      names = ops |> opcodes_of_kind(kind) |> Enum.map_join(", ", &"opcodes.#{cn.(&1)}")
      "        #{names} => #{call},\n"
    end

    "//! Generated protocol command sizing.\n" <>
      "//!\n" <>
      "//! Generated from `docs/protocol_schema.toml` by `mix protocol.gen`. Do not edit by hand.\n\n" <>
      "const opcodes = @import(\"protocol_opcodes.zig\");\n\n" <>
      "pub const Status = enum { sized, custom, incomplete, unknown };\n\n" <>
      "pub const Result = struct { status: Status, size: usize = 0 };\n\n" <>
      "/// Returns the on-wire byte length of the first command in `payload`,\n" <>
      "/// derived from each opcode's schema framing.\n" <>
      "pub fn commandSize(payload: []const u8) Result {\n" <>
      "    if (payload.len == 0) return .{ .status = .incomplete };\n" <>
      "    return switch (payload[0]) {\n" <>
      IO.iodata_to_binary(fixed_arms) <>
      zig_arm.(:len16, "len16(payload)") <>
      zig_arm.(:len32, "len32(payload)") <>
      zig_arm.(:sectioned, "sectioned(payload)") <>
      zig_arm.(:custom, ".{ .status = .custom }") <>
      "        // Forward-compatibility: opcodes >= 0x90 carry a u16 length prefix.\n" <>
      "        else => if (payload[0] >= 0x90) len16(payload) else .{ .status = .unknown },\n" <>
      "    };\n}\n\n" <>
      zig_command_size_helpers()
  end

  @spec zig_command_size_helpers() :: String.t()
  defp zig_command_size_helpers do
    """
    fn fixed(payload: []const u8, size: usize) Result {
        if (payload.len < size) return .{ .status = .incomplete };
        return .{ .status = .sized, .size = size };
    }

    fn len16(payload: []const u8) Result {
        if (payload.len < 3) return .{ .status = .incomplete };
        const size: usize = 3 + (@as(usize, payload[1]) << 8 | @as(usize, payload[2]));
        if (payload.len < size) return .{ .status = .incomplete };
        return .{ .status = .sized, .size = size };
    }

    fn len32(payload: []const u8) Result {
        if (payload.len < 5) return .{ .status = .incomplete };
        const size: usize = 5 + (@as(usize, payload[1]) << 24 | @as(usize, payload[2]) << 16 | @as(usize, payload[3]) << 8 | @as(usize, payload[4]));
        if (payload.len < size) return .{ .status = .incomplete };
        return .{ .status = .sized, .size = size };
    }

    fn sectioned(payload: []const u8) Result {
        if (payload.len < 2) return .{ .status = .incomplete };
        var offset: usize = 2;
        const count: usize = payload[1];
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (payload.len < offset + 3) return .{ .status = .incomplete };
            offset += 3 + (@as(usize, payload[offset + 1]) << 8 | @as(usize, payload[offset + 2]));
            if (payload.len < offset) return .{ .status = .incomplete };
        }
        return .{ .status = .sized, .size = offset };
    }
    """
  end

  # ── Swift: ProtocolCommandSize.generated.swift ────────────────────────────

  @spec swift_command_size_file(schema()) :: String.t()
  defp swift_command_size_file(schema) do
    ops = framing_opcodes(schema)
    swift_custom_ops = opcodes_of_kind(ops, :custom) ++ parser_command_opcodes(schema)
    cn = &rust_swift_zig_const_name/1

    fixed_cases =
      Enum.map(fixed_sizes(ops), fn n ->
        names = ops |> opcodes_of_kind({:fixed, n}) |> Enum.map_join(", ", cn)
        "    case #{names}:\n        return fixedCommandSize(payload, #{n})\n"
      end)

    swift_case = fn kind, call ->
      names = ops |> opcodes_of_kind(kind) |> Enum.map_join(", ", cn)
      "    case #{names}:\n        return #{call}\n"
    end

    swift_custom_case = fn ->
      names = Enum.map_join(swift_custom_ops, ", ", cn)
      "    case #{names}:\n        return .custom\n"
    end

    "// Generated protocol command sizing.\n" <>
      "//\n" <>
      "// Generated from `docs/protocol_schema.toml` by `mix protocol.gen`. Do not edit by hand.\n\n" <>
      "import Foundation\n\n" <>
      "/// Outcome of `commandSize(_:)`.\n" <>
      "public enum CommandSizeResult: Equatable {\n" <>
      "    /// Authoritative on-wire byte length of the command.\n" <>
      "    case sized(Int)\n" <>
      "    /// Opcode uses bespoke framing; its decoder owns sizing.\n" <>
      "    case custom\n" <>
      "    /// Payload is truncated; read more bytes.\n" <>
      "    case incomplete\n" <>
      "    /// Opcode is unknown and cannot be sized.\n" <>
      "    case unknown\n" <>
      "}\n\n" <>
      "/// Returns the on-wire byte length of the first command in `payload`,\n" <>
      "/// derived from each opcode's schema framing.\n" <>
      "public func commandSize(_ payload: [UInt8]) -> CommandSizeResult {\n" <>
      "    guard let opcode = payload.first else { return .incomplete }\n" <>
      "    switch opcode {\n" <>
      IO.iodata_to_binary(fixed_cases) <>
      swift_case.(:len16, "len16CommandSize(payload)") <>
      swift_case.(:len32, "len32CommandSize(payload)") <>
      swift_case.(:sectioned, "sectionedCommandSize(payload)") <>
      swift_custom_case.() <>
      "    default:\n" <>
      "        // Forward-compatibility: opcodes >= 0x90 carry a u16 length prefix.\n" <>
      "        if opcode >= 0x90 { return len16CommandSize(payload) }\n" <>
      "        return .unknown\n" <>
      "    }\n}\n\n" <>
      swift_command_size_helpers()
  end

  @spec swift_command_size_helpers() :: String.t()
  defp swift_command_size_helpers do
    """
    private func fixedCommandSize(_ payload: [UInt8], _ size: Int) -> CommandSizeResult {
        payload.count < size ? .incomplete : .sized(size)
    }

    private func len16CommandSize(_ payload: [UInt8]) -> CommandSizeResult {
        if payload.count < 3 { return .incomplete }
        let size = 3 + (Int(payload[1]) << 8 | Int(payload[2]))
        return payload.count < size ? .incomplete : .sized(size)
    }

    private func len32CommandSize(_ payload: [UInt8]) -> CommandSizeResult {
        if payload.count < 5 { return .incomplete }
        let size = 5 + (Int(payload[1]) << 24 | Int(payload[2]) << 16 | Int(payload[3]) << 8 | Int(payload[4]))
        return payload.count < size ? .incomplete : .sized(size)
    }

    private func sectionedCommandSize(_ payload: [UInt8]) -> CommandSizeResult {
        if payload.count < 2 { return .incomplete }
        var offset = 2
        let count = Int(payload[1])
        for _ in 0..<count {
            if payload.count < offset + 3 { return .incomplete }
            offset += 3 + (Int(payload[offset + 1]) << 8 | Int(payload[offset + 2]))
            if payload.count < offset { return .incomplete }
        }
        return .sized(offset)
    }
    """
  end

  # ── Structures & Sections: validation ──────────────────────────────────

  @type structure :: %{String.t() => term()}
  @type section :: %{String.t() => term()}

  @spec structures_map(schema()) :: %{String.t() => structure()}
  defp structures_map(schema) do
    schema
    |> Map.get("structures", [])
    |> Map.new(fn s -> {s["name"], s} end)
  end

  @spec sections_list(schema()) :: [section()]
  defp sections_list(schema), do: Map.get(schema, "sections", [])

  @spec entry_fields(map()) :: [map()]
  defp entry_fields(entry) do
    fields = Map.get(entry, "fields", [])

    case Map.get(entry, "conditional_tail") do
      %{"fields" => tail_fields} -> fields ++ tail_fields
      _ -> fields
    end
  end

  @spec entry_conditional_tail(map()) :: map() | nil
  defp entry_conditional_tail(entry), do: Map.get(entry, "conditional_tail")

  @spec entry_custom_layout?(map()) :: boolean()
  defp entry_custom_layout?(entry), do: Map.get(entry, "layout") == "custom"

  @spec conditional_tail_fields(map()) :: [map()]
  defp conditional_tail_fields(entry) do
    case entry_conditional_tail(entry) do
      %{"fields" => fields} -> fields
      _ -> []
    end
  end

  @spec conditional_tail_guard(map()) :: String.t() | nil
  defp conditional_tail_guard(entry) do
    case entry_conditional_tail(entry) do
      %{"guard" => guard} when is_binary(guard) -> guard
      _ -> nil
    end
  end

  @type command_fields :: %{String.t() => term()}

  @spec command_fields_list(schema()) :: [command_fields()]
  defp command_fields_list(schema), do: Map.get(schema, "command_fields", [])

  @spec validate_structures!(schema()) :: :ok
  defp validate_structures!(schema) do
    structures = Map.get(schema, "structures", [])
    names = Enum.map(structures, & &1["name"])
    dupes = names -- Enum.uniq(names)

    case dupes do
      [] ->
        :ok

      _ ->
        Mix.raise(
          "Duplicate structure names in #{@schema_path}: #{Enum.join(Enum.uniq(dupes), ", ")}"
        )
    end

    smap = Map.new(structures, fn s -> {s["name"], s} end)
    validate_struct_references!(structures, smap)
  end

  @spec validate_struct_references!([structure()], %{String.t() => structure()}) :: :ok
  defp validate_struct_references!(structures, smap) do
    bad =
      structures
      |> Enum.flat_map(fn s -> Enum.map(entry_fields(s), &{s["name"], &1}) end)
      |> Enum.filter(fn {_parent, field} ->
        (field["type"] == "struct" or field["type"] == "counted_array") and
          is_binary(field["element"]) and not Map.has_key?(smap, field["element"])
      end)
      |> Enum.map_join(", ", fn {parent, field} ->
        "#{parent}.#{field["name"]} -> #{field["element"]}"
      end)

    case bad do
      "" -> :ok
      _ -> Mix.raise("Unresolved struct references in #{@schema_path}: #{bad}")
    end
  end

  @spec validate_sections!(schema()) :: :ok
  defp validate_sections!(schema) do
    sections = sections_list(schema)
    opcode_names = schema |> Map.fetch!("opcodes") |> MapSet.new(& &1["name"])
    smap = structures_map(schema)

    validate_section_opcodes!(sections, opcode_names)
    validate_section_ids!(sections)
    validate_section_element_refs!(sections, smap)
    validate_section_field_refs!(sections, smap)
  end

  @spec validate_section_opcodes!([section()], MapSet.t()) :: :ok
  defp validate_section_opcodes!(sections, opcode_names) do
    bad =
      sections
      |> Enum.reject(&MapSet.member?(opcode_names, &1["opcode"]))
      |> Enum.map_join(", ", fn s -> "#{s["opcode"]}/#{s["name"]}" end)

    case bad do
      "" -> :ok
      _ -> Mix.raise("Sections reference unknown opcodes in #{@schema_path}: #{bad}")
    end
  end

  @spec validate_section_ids!([section()]) :: :ok
  defp validate_section_ids!(sections) do
    bad =
      sections
      |> Enum.group_by(& &1["opcode"])
      |> Enum.flat_map(fn {opcode, secs} ->
        secs
        |> Enum.group_by(& &1["id"])
        |> Enum.filter(fn {_id, grouped} -> length(grouped) > 1 end)
        |> Enum.map(fn {id, _grouped} -> "#{opcode}:#{hex(id)}" end)
      end)
      |> Enum.join(", ")

    case bad do
      "" -> :ok
      _ -> Mix.raise("Duplicate section IDs in #{@schema_path}: #{bad}")
    end
  end

  @spec validate_section_element_refs!([section()], %{String.t() => structure()}) :: :ok
  defp validate_section_element_refs!(sections, smap) do
    bad =
      sections
      |> Enum.filter(fn s -> s["layout"] == "counted_array" and is_binary(s["element"]) end)
      |> Enum.reject(fn s -> Map.has_key?(smap, s["element"]) end)
      |> Enum.map_join(", ", fn s -> "#{s["opcode"]}/#{s["name"]} -> #{s["element"]}" end)

    case bad do
      "" -> :ok
      _ -> Mix.raise("Sections reference unknown structures in #{@schema_path}: #{bad}")
    end
  end

  @spec validate_section_field_refs!([section()], %{String.t() => structure()}) :: :ok
  defp validate_section_field_refs!(sections, smap) do
    bad =
      sections
      |> Enum.reject(&entry_custom_layout?/1)
      |> Enum.flat_map(fn s -> Enum.map(entry_fields(s), &{s, &1}) end)
      |> Enum.filter(fn {_s, field} ->
        (field["type"] == "struct" or field["type"] == "counted_array") and
          is_binary(field["element"]) and not Map.has_key?(smap, field["element"])
      end)
      |> Enum.map_join(", ", fn {s, field} ->
        "#{s["opcode"]}/#{s["name"]}.#{field["name"]} -> #{field["element"]}"
      end)

    case bad do
      "" -> :ok
      _ -> Mix.raise("Section fields reference unknown structures in #{@schema_path}: #{bad}")
    end
  end

  @spec validate_command_fields!(schema()) :: :ok
  defp validate_command_fields!(schema) do
    command_fields = command_fields_list(schema)
    opcode_names = schema |> Map.fetch!("opcodes") |> MapSet.new(& &1["name"])
    smap = structures_map(schema)

    # All command_fields opcodes must reference existing opcodes
    bad_opcodes =
      command_fields
      |> Enum.reject(&MapSet.member?(opcode_names, &1["opcode"]))
      |> Enum.map_join(", ", & &1["opcode"])

    case bad_opcodes do
      "" ->
        :ok

      _ ->
        Mix.raise("command_fields reference unknown opcodes in #{@schema_path}: #{bad_opcodes}")
    end

    # Validate struct/counted_array field references (base fields + conditional tail)
    bad_refs =
      command_fields
      |> Enum.flat_map(fn cf -> Enum.map(entry_fields(cf), &{cf, &1}) end)
      |> Enum.filter(fn {_cf, field} ->
        (field["type"] == "struct" or field["type"] == "counted_array") and
          is_binary(field["element"]) and not Map.has_key?(smap, field["element"])
      end)
      |> Enum.map_join(", ", fn {cf, field} ->
        "#{cf["opcode"]}.#{field["name"]} -> #{field["element"]}"
      end)

    case bad_refs do
      "" ->
        :ok

      _ ->
        Mix.raise("command_fields reference unknown structures in #{@schema_path}: #{bad_refs}")
    end
  end

  # ── Type model helpers ───────────────────────────────────────────────────

  @primitive_sizes %{
    "u8" => 1,
    "u16" => 2,
    "u24" => 3,
    "u32" => 4,
    "u64" => 8,
    "rgb" => 3
  }

  @spec fixed_type_size(String.t(), %{String.t() => structure()}) :: non_neg_integer() | nil
  defp fixed_type_size(type_name, _smap) when is_map_key(@primitive_sizes, type_name) do
    Map.fetch!(@primitive_sizes, type_name)
  end

  defp fixed_type_size("string8", _smap), do: nil
  defp fixed_type_size("string16", _smap), do: nil
  defp fixed_type_size("string32", _smap), do: nil
  defp fixed_type_size("counted_array", _smap), do: nil

  defp fixed_type_size("struct", smap) when is_map(smap) do
    # This shouldn't be called directly; use fixed_field_size for struct fields
    nil
  end

  defp fixed_type_size(_other, _smap), do: nil

  @spec fixed_field_size(map(), %{String.t() => structure()}) :: non_neg_integer() | nil
  defp fixed_field_size(%{"type" => "struct", "element" => element}, smap) do
    fixed_structure_size(element, smap)
  end

  defp fixed_field_size(%{"type" => "counted_array"}, _smap), do: nil
  defp fixed_field_size(%{"type" => type_name}, smap), do: fixed_type_size(type_name, smap)

  @spec fixed_structure_size(String.t(), %{String.t() => structure()}) :: non_neg_integer() | nil
  defp fixed_structure_size(name, smap) do
    case Map.get(smap, name) do
      nil ->
        nil

      structure ->
        if Map.has_key?(structure, "conditional_tail") do
          nil
        else
          fixed_fields_size(structure["fields"] || [], smap)
        end
    end
  end

  @spec fixed_fields_size([map()], %{String.t() => structure()}) :: non_neg_integer() | nil
  defp fixed_fields_size(fields, smap) do
    Enum.reduce_while(fields, 0, fn field, acc ->
      case fixed_field_size(field, smap) do
        nil -> {:halt, nil}
        size -> {:cont, acc + size}
      end
    end)
  end

  @spec translate_guard(String.t(), [{String.t(), String.t()}]) :: String.t()
  defp translate_guard(guard, replacements) do
    Enum.reduce(replacements, guard, fn {from, to}, acc ->
      Regex.replace(~r/\b#{Regex.escape(from)}\b/, acc, to)
    end)
  end

  @spec go_guard_expression(map()) :: String.t()
  defp go_guard_expression(entry) do
    guard = conditional_tail_guard(entry) || "true"

    translate_guard(
      guard,
      Enum.map(Map.get(entry, "fields", []), fn field ->
        {field["name"], go_local_name(field["name"])}
      end)
    )
  end

  @spec rust_guard_expression(map()) :: String.t()
  defp rust_guard_expression(entry) do
    guard = conditional_tail_guard(entry) || "true"

    translate_guard(
      guard,
      Enum.map(Map.get(entry, "fields", []), fn field ->
        {field["name"], rust_field_name(field["name"])}
      end)
    )
  end

  # Only fields whose conditional-tail assignment statement reuses the outer
  # `err` variable (via `local, pos, err = ...`) need it declared. string/struct
  # do; counted_array scopes its own `err :=` in the decode loop, and primitives
  # scope theirs in `if err := decodeRequireLen(...)`. Listing counted_array here
  # would emit an unused `var err error` for a counted_array-only tail, which is
  # a Go compile error.
  @spec go_field_needs_error?(map()) :: boolean()
  defp go_field_needs_error?(%{"type" => type})
       when type in ["string8", "string16", "string32", "struct"], do: true

  defp go_field_needs_error?(_field), do: false

  @spec go_decode_conditional_tail_block(map(), %{String.t() => structure()}, String.t()) ::
          iodata()
  defp go_decode_conditional_tail_block(entry, smap, zero) do
    tail_fields = conditional_tail_fields(entry)

    case tail_fields do
      [] ->
        []

      _ ->
        needs_err = Enum.any?(tail_fields, &go_field_needs_error?/1)

        [
          Enum.map(tail_fields, fn field ->
            "\tvar #{go_local_name(field["name"])} #{go_type(field, smap)}\n"
          end),
          "\tif #{go_guard_expression(entry)} {\n",
          if(needs_err, do: "\t\tvar err error\n", else: ""),
          Enum.map(tail_fields, fn field ->
            go_decode_field_assignment_statement(field, smap, zero)
          end),
          "\t}\n"
        ]
    end
  end

  @spec go_decode_field_assignment_statement(map(), %{String.t() => structure()}, String.t()) ::
          iodata()
  defp go_decode_field_assignment_statement(%{"name" => name, "type" => "u8"}, _smap, zero) do
    local = go_local_name(name)

    [
      "\t\tif err := decodeRequireLen(data, pos+1, \"#{name}\"); err != nil {\n",
      "\t\t\treturn #{zero}, offset, err\n",
      "\t\t}\n",
      "\t\t#{local} = data[pos]\n",
      "\t\tpos++\n"
    ]
  end

  defp go_decode_field_assignment_statement(%{"name" => name, "type" => "u16"}, _smap, zero) do
    local = go_local_name(name)

    [
      "\t\tif err := decodeRequireLen(data, pos+2, \"#{name}\"); err != nil {\n",
      "\t\t\treturn #{zero}, offset, err\n",
      "\t\t}\n",
      "\t\t#{local} = decodeU16(data, pos)\n",
      "\t\tpos += 2\n"
    ]
  end

  defp go_decode_field_assignment_statement(%{"name" => name, "type" => "u24"}, _smap, zero) do
    local = go_local_name(name)

    [
      "\t\tif err := decodeRequireLen(data, pos+3, \"#{name}\"); err != nil {\n",
      "\t\t\treturn #{zero}, offset, err\n",
      "\t\t}\n",
      "\t\t#{local} = decodeU24(data, pos)\n",
      "\t\tpos += 3\n"
    ]
  end

  defp go_decode_field_assignment_statement(%{"name" => name, "type" => "u32"}, _smap, zero) do
    local = go_local_name(name)

    [
      "\t\tif err := decodeRequireLen(data, pos+4, \"#{name}\"); err != nil {\n",
      "\t\t\treturn #{zero}, offset, err\n",
      "\t\t}\n",
      "\t\t#{local} = decodeU32(data, pos)\n",
      "\t\tpos += 4\n"
    ]
  end

  defp go_decode_field_assignment_statement(%{"name" => name, "type" => "u64"}, _smap, zero) do
    local = go_local_name(name)

    [
      "\t\tif err := decodeRequireLen(data, pos+8, \"#{name}\"); err != nil {\n",
      "\t\t\treturn #{zero}, offset, err\n",
      "\t\t}\n",
      "\t\t#{local} = decodeU64(data, pos)\n",
      "\t\tpos += 8\n"
    ]
  end

  defp go_decode_field_assignment_statement(%{"name" => name, "type" => "rgb"}, _smap, zero) do
    local = go_local_name(name)

    [
      "\t\tif err := decodeRequireLen(data, pos+3, \"#{name}\"); err != nil {\n",
      "\t\t\treturn #{zero}, offset, err\n",
      "\t\t}\n",
      "\t\t#{local} = decodeU24(data, pos)\n",
      "\t\tpos += 3\n"
    ]
  end

  defp go_decode_field_assignment_statement(%{"name" => name, "type" => "string8"}, _smap, zero) do
    local = go_local_name(name)

    [
      "\t\t#{local}, pos, err = decodeString8(data, pos)\n",
      "\t\tif err != nil {\n",
      "\t\t\treturn #{zero}, offset, err\n",
      "\t\t}\n"
    ]
  end

  defp go_decode_field_assignment_statement(%{"name" => name, "type" => "string16"}, _smap, zero) do
    local = go_local_name(name)

    [
      "\t\t#{local}, pos, err = decodeString16(data, pos)\n",
      "\t\tif err != nil {\n",
      "\t\t\treturn #{zero}, offset, err\n",
      "\t\t}\n"
    ]
  end

  defp go_decode_field_assignment_statement(%{"name" => name, "type" => "string32"}, _smap, zero) do
    local = go_local_name(name)

    [
      "\t\t#{local}, pos, err = decodeString32(data, pos)\n",
      "\t\tif err != nil {\n",
      "\t\t\treturn #{zero}, offset, err\n",
      "\t\t}\n"
    ]
  end

  defp go_decode_field_assignment_statement(
         %{"name" => name, "type" => "struct", "element" => element},
         _smap,
         zero
       ) do
    local = go_local_name(name)

    [
      "\t\t#{local}, pos, err = Decode#{go_struct_name(element)}(data, pos)\n",
      "\t\tif err != nil {\n",
      "\t\t\treturn #{zero}, offset, err\n",
      "\t\t}\n"
    ]
  end

  defp go_decode_field_assignment_statement(
         %{
           "name" => name,
           "type" => "counted_array",
           "count_type" => count_type,
           "element" => element
         },
         smap,
         zero
       ) do
    local = go_local_name(name)
    {count_read, count_size} = go_count_read(count_type)
    element_fixed_size = fixed_structure_size(element, smap)

    stride_check =
      case element_fixed_size do
        nil ->
          []

        stride ->
          [
            "\t\tif err := decodeRequireLen(data, pos+#{local}Count*#{stride}, \"#{name}\"); err != nil {\n",
            "\t\t\treturn #{zero}, offset, err\n",
            "\t\t}\n"
          ]
      end

    [
      "\t\tif err := decodeRequireLen(data, pos+#{count_size}, \"#{name} count\"); err != nil {\n",
      "\t\t\treturn #{zero}, offset, err\n",
      "\t\t}\n",
      "\t\t#{local}Count := int(#{count_read})\n",
      "\t\tpos += #{count_size}\n",
      stride_check,
      "\t\t#{local} = make([]#{go_struct_name(element)}, 0, #{local}Count)\n",
      "\t\tfor i := 0; i < #{local}Count; i++ {\n",
      "\t\t\titem, nextPos, err := Decode#{go_struct_name(element)}(data, pos)\n",
      "\t\t\tif err != nil {\n",
      "\t\t\t\treturn #{zero}, offset, err\n",
      "\t\t\t}\n",
      "\t\t\tpos = nextPos\n",
      "\t\t\t#{local} = append(#{local}, item)\n",
      "\t\t}\n"
    ]
  end

  @spec rust_zero_value(map(), %{String.t() => structure()}) :: String.t()
  defp rust_zero_value(%{"type" => type}, _smap)
       when type in ["u8", "u16", "u24", "u32", "u64", "rgb"], do: "0"

  defp rust_zero_value(%{"type" => type}, _smap) when type in ["string8", "string16", "string32"],
    do: "String::new()"

  defp rust_zero_value(%{"type" => "struct", "element" => element}, _smap),
    do: "#{rust_struct_name(element)}::default()"

  defp rust_zero_value(%{"type" => "counted_array", "element" => element}, _smap),
    do: "Vec::<#{rust_struct_name(element)}>::new()"

  defp rust_zero_value(_field, _smap), do: "Default::default()"

  @spec rust_decode_conditional_tail_block(map(), %{String.t() => structure()}) :: iodata()
  defp rust_decode_conditional_tail_block(entry, smap) do
    tail_fields = conditional_tail_fields(entry)

    case tail_fields do
      [] ->
        []

      _ ->
        [
          Enum.map(tail_fields, fn field ->
            "    let mut #{rust_field_name(field["name"])} = #{rust_zero_value(field, smap)};\n"
          end),
          "    if #{rust_guard_expression(entry)} {\n",
          Enum.map(tail_fields, fn field ->
            rust_decode_field_assignment_statement(field, smap)
          end),
          "    }\n"
        ]
    end
  end

  @spec rust_decode_field_assignment_statement(map(), %{String.t() => structure()}) :: iodata()
  defp rust_decode_field_assignment_statement(%{"name" => name, "type" => "u8"}, _smap) do
    local = rust_field_name(name)

    [
      "        require_len(bytes, pos + 1, \"#{name}\")?;\n",
      "        #{local} = bytes[pos];\n",
      "        pos += 1;\n"
    ]
  end

  defp rust_decode_field_assignment_statement(%{"name" => name, "type" => "u16"}, _smap) do
    local = rust_field_name(name)

    [
      "        require_len(bytes, pos + 2, \"#{name}\")?;\n",
      "        #{local} = read_u16(bytes, pos);\n",
      "        pos += 2;\n"
    ]
  end

  defp rust_decode_field_assignment_statement(%{"name" => name, "type" => "u24"}, _smap) do
    local = rust_field_name(name)

    [
      "        require_len(bytes, pos + 3, \"#{name}\")?;\n",
      "        #{local} = read_u24(bytes, pos);\n",
      "        pos += 3;\n"
    ]
  end

  defp rust_decode_field_assignment_statement(%{"name" => name, "type" => "u32"}, _smap) do
    local = rust_field_name(name)

    [
      "        require_len(bytes, pos + 4, \"#{name}\")?;\n",
      "        #{local} = read_u32(bytes, pos);\n",
      "        pos += 4;\n"
    ]
  end

  defp rust_decode_field_assignment_statement(%{"name" => name, "type" => "u64"}, _smap) do
    local = rust_field_name(name)

    [
      "        require_len(bytes, pos + 8, \"#{name}\")?;\n",
      "        #{local} = read_u64(bytes, pos);\n",
      "        pos += 8;\n"
    ]
  end

  defp rust_decode_field_assignment_statement(%{"name" => name, "type" => "rgb"}, _smap) do
    local = rust_field_name(name)

    [
      "        require_len(bytes, pos + 3, \"#{name}\")?;\n",
      "        #{local} = read_u24(bytes, pos);\n",
      "        pos += 3;\n"
    ]
  end

  defp rust_decode_field_assignment_statement(%{"name" => name, "type" => "string8"}, _smap) do
    local = rust_field_name(name)

    [
      "        #{local} = read_string8(bytes, &mut pos)?;\n"
    ]
  end

  defp rust_decode_field_assignment_statement(%{"name" => name, "type" => "string16"}, _smap) do
    local = rust_field_name(name)

    [
      "        #{local} = read_string16(bytes, &mut pos)?;\n"
    ]
  end

  defp rust_decode_field_assignment_statement(%{"name" => name, "type" => "string32"}, _smap) do
    local = rust_field_name(name)

    [
      "        #{local} = read_string32(bytes, &mut pos)?;\n"
    ]
  end

  defp rust_decode_field_assignment_statement(
         %{"name" => name, "type" => "struct", "element" => element},
         _smap
       ) do
    local = rust_field_name(name)

    [
      "        let (#{local}_value, consumed) = decode_#{element}(bytes, pos)?;\n",
      "        #{local} = #{local}_value;\n",
      "        pos += consumed;\n"
    ]
  end

  defp rust_decode_field_assignment_statement(
         %{
           "name" => name,
           "type" => "counted_array",
           "count_type" => count_type,
           "element" => element
         },
         smap
       ) do
    local = rust_field_name(name)
    {count_read, count_size} = rust_count_read(count_type)
    element_fixed_size = fixed_structure_size(element, smap)

    stride_check =
      case element_fixed_size do
        nil ->
          []

        stride ->
          [
            "        require_len(bytes, pos + #{local}_count * #{stride}, \"#{name}\")?;\n"
          ]
      end

    [
      "        require_len(bytes, pos + #{count_size}, \"#{name} count\")?;\n",
      "        let #{local}_count = #{count_read};\n",
      "        pos += #{count_size};\n",
      stride_check,
      "        let mut #{local}_value = Vec::with_capacity(#{local}_count);\n",
      "        for _ in 0..#{local}_count {\n",
      "            let (item, consumed) = decode_#{element}(bytes, pos)?;\n",
      "            pos += consumed;\n",
      "            #{local}_value.push(item);\n",
      "        }\n",
      "        #{local} = #{local}_value;\n"
    ]
  end

  # ── Rust type mapping helpers ────────────────────────────────────────────

  @spec rust_type(map(), %{String.t() => structure()}) :: String.t()
  defp rust_type(%{"type" => "u8"}, _smap), do: "u8"
  defp rust_type(%{"type" => "u16"}, _smap), do: "u16"
  defp rust_type(%{"type" => "u24"}, _smap), do: "u32"
  defp rust_type(%{"type" => "u32"}, _smap), do: "u32"
  defp rust_type(%{"type" => "u64"}, _smap), do: "u64"
  defp rust_type(%{"type" => "rgb"}, _smap), do: "u32"
  defp rust_type(%{"type" => "string8"}, _smap), do: "String"
  defp rust_type(%{"type" => "string16"}, _smap), do: "String"
  defp rust_type(%{"type" => "string32"}, _smap), do: "String"

  defp rust_type(%{"type" => "struct", "element" => element}, _smap) do
    rust_struct_name(element)
  end

  defp rust_type(%{"type" => "counted_array", "element" => element}, _smap) do
    "Vec<#{rust_struct_name(element)}>"
  end

  @spec rust_struct_name(String.t()) :: String.t()
  defp rust_struct_name(name) do
    name
    |> String.split("_")
    |> Enum.map_join("", &String.capitalize/1)
  end

  @rust_keywords ~w(type self super crate mod fn struct enum impl trait pub use let mut const static ref match return if else for while loop break continue where as in move box dyn async await try macro yield)
  @spec rust_field_name(String.t()) :: String.t()
  defp rust_field_name(name) when name in @rust_keywords, do: "r##{name}"
  defp rust_field_name(name), do: name

  # ── Rust: semantic_types.rs ──────────────────────────────────────────────

  @spec rust_semantic_types_file(schema()) :: String.t()
  defp rust_semantic_types_file(schema) do
    structures = Map.get(schema, "structures", [])
    sections = sections_list(schema)
    command_fields = command_fields_list(schema)
    smap = structures_map(schema)

    [
      "// Generated semantic wire types.\n",
      "//\n",
      "// Generated from `docs/protocol_schema.toml` by `mix protocol.gen`. Do not edit by hand.\n\n",
      rust_structure_definitions(structures, smap),
      "\n",
      rust_size_constants(structures, smap),
      "\n",
      rust_section_struct_definitions(sections, smap),
      rust_command_fields_struct_definitions(command_fields, smap)
    ]
    |> IO.iodata_to_binary()
  end

  @spec rust_structure_definitions([structure()], %{String.t() => structure()}) :: iodata()
  defp rust_structure_definitions(structures, smap) do
    Enum.map(structures, fn s ->
      name = rust_struct_name(s["name"])
      fields = entry_fields(s)

      has_variable =
        Map.has_key?(s, "conditional_tail") or
          Enum.any?(fields, fn f -> fixed_field_size(f, smap) == nil end)

      derive =
        if has_variable,
          do: "#[derive(Debug, Clone, Default, PartialEq, Eq)]\n",
          else: "#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]\n"

      [
        derive,
        "pub struct #{name} {\n",
        Enum.map(fields, fn field ->
          "    pub #{rust_field_name(field["name"])}: #{rust_type(field, smap)},\n"
        end),
        "}\n\n"
      ]
    end)
  end

  @spec rust_size_constants([structure()], %{String.t() => structure()}) :: iodata()
  defp rust_size_constants(structures, smap) do
    structures
    |> Enum.flat_map(fn s ->
      case fixed_structure_size(s["name"], smap) do
        nil -> []
        size -> [{s["name"], size}]
      end
    end)
    |> Enum.map(fn {name, size} ->
      "pub const #{constant_name(name)}_SIZE: usize = #{size};\n"
    end)
  end

  @spec rust_section_struct_definitions([section()], %{String.t() => structure()}) :: iodata()
  defp rust_section_struct_definitions(sections, smap) do
    # Only generate structs for sections with inline fields (not counted_array layout or custom sections)
    sections
    |> Enum.reject(&entry_custom_layout?/1)
    |> Enum.filter(&(Map.has_key?(&1, "fields") or Map.has_key?(&1, "conditional_tail")))
    |> Enum.map(fn s ->
      name = rust_section_struct_name(s)
      fields = entry_fields(s)
      has_variable = Enum.any?(fields, fn f -> fixed_field_size(f, smap) == nil end)

      derive =
        if has_variable,
          do: "#[derive(Debug, Clone, Default, PartialEq, Eq)]\n",
          else: "#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]\n"

      [
        derive,
        "pub struct #{name} {\n",
        Enum.map(fields, fn field ->
          "    pub #{rust_field_name(field["name"])}: #{rust_type(field, smap)},\n"
        end),
        "}\n\n"
      ]
    end)
  end

  @spec rust_section_struct_name(section()) :: String.t()
  defp rust_section_struct_name(section) do
    opcode_part = rust_struct_name(section["opcode"])
    section_part = rust_struct_name(section["name"])
    "#{opcode_part}#{section_part}"
  end

  # ── Rust: semantic_decode.rs ─────────────────────────────────────────────

  @spec rust_semantic_decode_file(schema()) :: String.t()
  defp rust_semantic_decode_file(schema) do
    structures = Map.get(schema, "structures", [])
    sections = sections_list(schema)
    command_fields = command_fields_list(schema)
    smap = structures_map(schema)

    [
      "// Generated semantic decode functions.\n",
      "//\n",
      "// Generated from `docs/protocol_schema.toml` by `mix protocol.gen`. Do not edit by hand.\n\n",
      "use crate::protocol::DecodeError;\n",
      "use super::semantic_types::*;\n\n",
      rust_decode_helpers(),
      "\n",
      Enum.map(structures, &rust_decode_structure(&1, smap)),
      "\n",
      rust_decode_section_functions(sections, smap),
      rust_decode_command_fields_functions(command_fields, smap)
    ]
    |> IO.iodata_to_binary()
  end

  @spec rust_decode_helpers() :: iodata()
  defp rust_decode_helpers do
    """
    fn require_len(bytes: &[u8], needed: usize, label: &'static str) -> Result<(), DecodeError> {
        if bytes.len() < needed {
            Err(DecodeError::Malformed(label))
        } else {
            Ok(())
        }
    }

    fn read_u16(bytes: &[u8], offset: usize) -> u16 {
        u16::from_be_bytes([bytes[offset], bytes[offset + 1]])
    }

    fn read_u24(bytes: &[u8], offset: usize) -> u32 {
        ((bytes[offset] as u32) << 16) | ((bytes[offset + 1] as u32) << 8) | bytes[offset + 2] as u32
    }

    fn read_u32(bytes: &[u8], offset: usize) -> u32 {
        u32::from_be_bytes([bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]])
    }

    fn read_u64(bytes: &[u8], offset: usize) -> u64 {
        u64::from_be_bytes([
            bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3],
            bytes[offset + 4], bytes[offset + 5], bytes[offset + 6], bytes[offset + 7],
        ])
    }

    fn read_string(bytes: &[u8], offset: usize, len: usize) -> Result<String, DecodeError> {
        require_len(bytes, offset + len, "string body")?;
        std::str::from_utf8(&bytes[offset..offset + len])
            .map(str::to_owned)
            .map_err(|_| DecodeError::Utf8)
    }

    fn read_string8(bytes: &[u8], offset: &mut usize) -> Result<String, DecodeError> {
        require_len(bytes, *offset + 1, "string8 header")?;
        let len = bytes[*offset] as usize;
        *offset += 1;
        let value = read_string(bytes, *offset, len)?;
        *offset += len;
        Ok(value)
    }

    fn read_string16(bytes: &[u8], offset: &mut usize) -> Result<String, DecodeError> {
        require_len(bytes, *offset + 2, "string16 header")?;
        let len = read_u16(bytes, *offset) as usize;
        *offset += 2;
        let value = read_string(bytes, *offset, len)?;
        *offset += len;
        Ok(value)
    }

    fn read_string32(bytes: &[u8], offset: &mut usize) -> Result<String, DecodeError> {
        require_len(bytes, *offset + 4, "string32 header")?;
        let len = read_u32(bytes, *offset) as usize;
        *offset += 4;
        let value = read_string(bytes, *offset, len)?;
        *offset += len;
        Ok(value)
    }
    """
  end

  @spec rust_decode_structure(structure(), %{String.t() => structure()}) :: iodata()
  defp rust_decode_structure(structure, smap) do
    name = structure["name"]
    struct_name = rust_struct_name(name)
    fn_name = "decode_#{name}"
    fields = structure["fields"] || []

    [
      "pub fn #{fn_name}(bytes: &[u8], offset: usize) -> Result<(#{struct_name}, usize), DecodeError> {\n",
      "    let mut pos = offset;\n",
      Enum.map(fields, &rust_decode_field_statement(&1, smap)),
      rust_decode_conditional_tail_block(structure, smap),
      "    Ok((#{struct_name} {\n",
      Enum.map(entry_fields(structure), fn field ->
        "        #{rust_field_name(field["name"])},\n"
      end),
      "    }, pos - offset))\n",
      "}\n\n"
    ]
  end

  @spec rust_decode_field_statement(map(), %{String.t() => structure()}) :: iodata()
  defp rust_decode_field_statement(%{"name" => name, "type" => "u8"}, _smap) do
    rname = rust_field_name(name)

    [
      "    require_len(bytes, pos + 1, \"#{name}\")?;\n",
      "    let #{rname} = bytes[pos];\n",
      "    pos += 1;\n"
    ]
  end

  defp rust_decode_field_statement(%{"name" => name, "type" => "u16"}, _smap) do
    rname = rust_field_name(name)

    [
      "    require_len(bytes, pos + 2, \"#{name}\")?;\n",
      "    let #{rname} = read_u16(bytes, pos);\n",
      "    pos += 2;\n"
    ]
  end

  defp rust_decode_field_statement(%{"name" => name, "type" => "u24"}, _smap) do
    rname = rust_field_name(name)

    [
      "    require_len(bytes, pos + 3, \"#{name}\")?;\n",
      "    let #{rname} = read_u24(bytes, pos);\n",
      "    pos += 3;\n"
    ]
  end

  defp rust_decode_field_statement(%{"name" => name, "type" => "u32"}, _smap) do
    rname = rust_field_name(name)

    [
      "    require_len(bytes, pos + 4, \"#{name}\")?;\n",
      "    let #{rname} = read_u32(bytes, pos);\n",
      "    pos += 4;\n"
    ]
  end

  defp rust_decode_field_statement(%{"name" => name, "type" => "u64"}, _smap) do
    rname = rust_field_name(name)

    [
      "    require_len(bytes, pos + 8, \"#{name}\")?;\n",
      "    let #{rname} = read_u64(bytes, pos);\n",
      "    pos += 8;\n"
    ]
  end

  defp rust_decode_field_statement(%{"name" => name, "type" => "rgb"}, _smap) do
    rname = rust_field_name(name)

    [
      "    require_len(bytes, pos + 3, \"#{name}\")?;\n",
      "    let #{rname} = read_u24(bytes, pos);\n",
      "    pos += 3;\n"
    ]
  end

  defp rust_decode_field_statement(%{"name" => name, "type" => "string8"}, _smap) do
    rname = rust_field_name(name)
    ["    let #{rname} = read_string8(bytes, &mut pos)?;\n"]
  end

  defp rust_decode_field_statement(%{"name" => name, "type" => "string16"}, _smap) do
    rname = rust_field_name(name)
    ["    let #{rname} = read_string16(bytes, &mut pos)?;\n"]
  end

  defp rust_decode_field_statement(%{"name" => name, "type" => "string32"}, _smap) do
    rname = rust_field_name(name)
    ["    let #{rname} = read_string32(bytes, &mut pos)?;\n"]
  end

  defp rust_decode_field_statement(
         %{"name" => name, "type" => "struct", "element" => element},
         _smap
       ) do
    rname = rust_field_name(name)

    [
      "    let (#{rname}, consumed) = decode_#{element}(bytes, pos)?;\n",
      "    pos += consumed;\n"
    ]
  end

  defp rust_decode_field_statement(
         %{
           "name" => name,
           "type" => "counted_array",
           "count_type" => count_type,
           "element" => element
         },
         smap
       ) do
    rname = rust_field_name(name)
    {count_read, count_size} = rust_count_read(count_type)
    element_fixed_size = fixed_structure_size(element, smap)

    count_lines = [
      "    require_len(bytes, pos + #{count_size}, \"#{name} count\")?;\n",
      "    let #{rname}_count = #{count_read};\n",
      "    pos += #{count_size};\n"
    ]

    decode_lines =
      case element_fixed_size do
        nil ->
          # Variable-size elements: decode one by one
          [
            "    let mut #{rname} = Vec::with_capacity(#{rname}_count);\n",
            "    for _ in 0..#{rname}_count {\n",
            "        let (item, consumed) = decode_#{element}(bytes, pos)?;\n",
            "        pos += consumed;\n",
            "        #{rname}.push(item);\n",
            "    }\n"
          ]

        stride ->
          # Fixed-size elements: can validate upfront, still decode individually
          [
            "    require_len(bytes, pos + #{rname}_count * #{stride}, \"#{name}\")?;\n",
            "    let mut #{rname} = Vec::with_capacity(#{rname}_count);\n",
            "    for _ in 0..#{rname}_count {\n",
            "        let (item, consumed) = decode_#{element}(bytes, pos)?;\n",
            "        pos += consumed;\n",
            "        #{rname}.push(item);\n",
            "    }\n"
          ]
      end

    count_lines ++ decode_lines
  end

  @spec rust_count_read(String.t()) :: {String.t(), non_neg_integer()}
  defp rust_count_read("u8"), do: {"bytes[pos] as usize", 1}
  defp rust_count_read("u16"), do: {"read_u16(bytes, pos) as usize", 2}
  defp rust_count_read("u32"), do: {"read_u32(bytes, pos) as usize", 4}

  @spec rust_decode_section_functions([section()], %{String.t() => structure()}) :: iodata()
  defp rust_decode_section_functions(sections, smap) do
    sections
    |> Enum.group_by(& &1["opcode"])
    |> Enum.sort_by(fn {opcode, _} -> opcode end)
    |> Enum.map(fn {opcode, secs} ->
      rust_decode_opcode_sections(opcode, Enum.sort_by(secs, & &1["id"]), smap)
    end)
  end

  @spec rust_decode_opcode_sections(String.t(), [section()], %{String.t() => structure()}) ::
          iodata()
  defp rust_decode_opcode_sections(opcode, secs, smap) do
    [
      "// Section decoders for #{opcode}\n\n",
      Enum.map(secs, fn sec ->
        cond do
          entry_custom_layout?(sec) -> []
          sec["layout"] == "counted_array" -> rust_decode_counted_array_section(opcode, sec, smap)
          true -> rust_decode_inline_section(opcode, sec, smap)
        end
      end)
    ]
  end

  @spec rust_decode_inline_section(String.t(), section(), %{String.t() => structure()}) ::
          iodata()
  defp rust_decode_inline_section(_opcode, section, smap) do
    struct_name = rust_section_struct_name(section)
    fn_name = "decode_#{section["opcode"]}_#{section["name"]}"
    fields = section["fields"] || []

    [
      "pub fn #{fn_name}(bytes: &[u8], offset: usize) -> Result<(#{struct_name}, usize), DecodeError> {\n",
      "    let mut pos = offset;\n",
      Enum.map(fields, &rust_decode_field_statement(&1, smap)),
      rust_decode_conditional_tail_block(section, smap),
      "    Ok((#{struct_name} {\n",
      Enum.map(entry_fields(section), fn field ->
        "        #{rust_field_name(field["name"])},\n"
      end),
      "    }, pos - offset))\n",
      "}\n\n"
    ]
  end

  @spec rust_decode_counted_array_section(String.t(), section(), %{String.t() => structure()}) ::
          iodata()
  defp rust_decode_counted_array_section(_opcode, section, smap) do
    element = section["element"]
    element_struct = rust_struct_name(element)
    fn_name = "decode_#{section["opcode"]}_#{section["name"]}"
    count_type = section["count_type"] || "u16"
    {count_read, count_size} = rust_count_read(count_type)
    element_fixed_size = fixed_structure_size(element, smap)

    decode_loop =
      case element_fixed_size do
        nil ->
          [
            "    let mut items = Vec::with_capacity(count);\n",
            "    for _ in 0..count {\n",
            "        let (item, consumed) = decode_#{element}(bytes, pos)?;\n",
            "        pos += consumed;\n",
            "        items.push(item);\n",
            "    }\n"
          ]

        stride ->
          [
            "    require_len(bytes, pos + count * #{stride}, \"#{section["name"]}\")?;\n",
            "    let mut items = Vec::with_capacity(count);\n",
            "    for _ in 0..count {\n",
            "        let (item, consumed) = decode_#{element}(bytes, pos)?;\n",
            "        pos += consumed;\n",
            "        items.push(item);\n",
            "    }\n"
          ]
      end

    [
      "pub fn #{fn_name}(bytes: &[u8], offset: usize) -> Result<(Vec<#{element_struct}>, usize), DecodeError> {\n",
      "    let mut pos = offset;\n",
      "    require_len(bytes, pos + #{count_size}, \"#{section["name"]} count\")?;\n",
      "    let count = #{count_read};\n",
      "    pos += #{count_size};\n",
      decode_loop,
      "    Ok((items, pos - offset))\n",
      "}\n\n"
    ]
  end

  # ── Go type mapping helpers ───────────────────────────────────────────────

  @spec go_type(map(), %{String.t() => structure()}) :: String.t()
  defp go_type(%{"type" => "u8"}, _smap), do: "uint8"
  defp go_type(%{"type" => "u16"}, _smap), do: "uint16"
  defp go_type(%{"type" => "u24"}, _smap), do: "uint32"
  defp go_type(%{"type" => "u32"}, _smap), do: "uint32"
  defp go_type(%{"type" => "u64"}, _smap), do: "uint64"
  defp go_type(%{"type" => "rgb"}, _smap), do: "uint32"
  defp go_type(%{"type" => "string8"}, _smap), do: "string"
  defp go_type(%{"type" => "string16"}, _smap), do: "string"
  defp go_type(%{"type" => "string32"}, _smap), do: "string"

  defp go_type(%{"type" => "struct", "element" => element}, _smap) do
    go_struct_name(element)
  end

  defp go_type(%{"type" => "counted_array", "element" => element}, _smap) do
    "[]#{go_struct_name(element)}"
  end

  @spec go_struct_name(String.t()) :: String.t()
  defp go_struct_name(name) do
    name
    |> String.split("_")
    |> Enum.map_join("", &String.capitalize/1)
  end

  # Go convention: common acronyms are fully uppercased (ID, FG, BG, URL, etc.)
  @go_acronyms %{
    "id" => "ID",
    "fg" => "FG",
    "bg" => "BG",
    "url" => "URL",
    "ip" => "IP",
    "lsp" => "LSP"
  }

  @spec go_field_name(String.t()) :: String.t()
  defp go_field_name(name) do
    name
    |> String.split("_")
    |> Enum.map_join("", fn part ->
      Map.get(@go_acronyms, part, String.capitalize(part))
    end)
  end

  @go_keywords ~w(type break default func interface select case defer go map struct chan else goto package switch const fallthrough if range var continue for import return)
  @spec go_local_name(String.t()) :: String.t()
  defp go_local_name(name) do
    camel = go_camel_case(name)
    if camel in @go_keywords, do: camel <> "Val", else: camel
  end

  @spec go_camel_case(String.t()) :: String.t()
  defp go_camel_case(name) do
    case String.split(name, "_") do
      [first | rest] ->
        first <>
          Enum.map_join(rest, "", fn part ->
            Map.get(@go_acronyms, part, String.capitalize(part))
          end)

      _ ->
        name
    end
  end

  @spec go_section_struct_name(section()) :: String.t()
  defp go_section_struct_name(section) do
    opcode_part = go_struct_name(section["opcode"])
    section_part = go_struct_name(section["name"])
    "#{opcode_part}#{section_part}"
  end

  # ── Go: semantic_types.go ───────────────────────────────────────────────

  @spec go_semantic_types_file(schema()) :: String.t()
  defp go_semantic_types_file(schema) do
    structures = Map.get(schema, "structures", [])
    sections = sections_list(schema)
    command_fields = command_fields_list(schema)
    smap = structures_map(schema)

    [
      "// Code generated by mix protocol.gen. DO NOT EDIT.\n\n",
      "package generated\n\n",
      go_structure_definitions(structures, smap),
      go_size_constants(structures, smap),
      go_section_struct_definitions(sections, smap),
      go_command_fields_struct_definitions(command_fields, smap)
    ]
    |> IO.iodata_to_binary()
    |> format_generated_go_file()
  end

  @spec go_structure_definitions([structure()], %{String.t() => structure()}) :: iodata()
  defp go_structure_definitions(structures, smap) do
    Enum.map(structures, fn s ->
      name = go_struct_name(s["name"])
      fields = entry_fields(s)
      go_struct_block(name, fields, smap)
    end)
  end

  @spec go_struct_block(String.t(), [map()], %{String.t() => structure()}) :: iodata()
  defp go_struct_block(name, fields, smap) do
    max_name_len =
      fields
      |> Enum.map(fn f -> String.length(go_field_name(f["name"])) end)
      |> Enum.max(fn -> 0 end)

    [
      "type #{name} struct {\n",
      Enum.map(fields, fn field ->
        fname = go_field_name(field["name"])
        padded = String.pad_trailing(fname, max_name_len)
        "\t#{padded} #{go_type(field, smap)}\n"
      end),
      "}\n\n"
    ]
  end

  @spec go_size_constants([structure()], %{String.t() => structure()}) :: iodata()
  defp go_size_constants(structures, smap) do
    constants =
      structures
      |> Enum.flat_map(fn s ->
        case fixed_structure_size(s["name"], smap) do
          nil -> []
          size -> [{s["name"], size}]
        end
      end)

    case constants do
      [] ->
        []

      _ ->
        max_len =
          constants
          |> Enum.map(fn {name, _} -> String.length("#{go_struct_name(name)}Size") end)
          |> Enum.max()

        [
          "const (\n",
          Enum.map(constants, fn {name, size} ->
            cname = "#{go_struct_name(name)}Size"
            "\t#{String.pad_trailing(cname, max_len)} = #{size}\n"
          end),
          ")\n\n"
        ]
    end
  end

  @spec go_section_struct_definitions([section()], %{String.t() => structure()}) :: iodata()
  defp go_section_struct_definitions(sections, smap) do
    sections
    |> Enum.reject(&entry_custom_layout?/1)
    |> Enum.filter(&(Map.has_key?(&1, "fields") or Map.has_key?(&1, "conditional_tail")))
    |> Enum.map(fn s ->
      name = go_section_struct_name(s)
      fields = entry_fields(s)
      go_struct_block(name, fields, smap)
    end)
  end

  # ── Go: semantic_decode.go ──────────────────────────────────────────────

  @spec go_semantic_decode_file(schema()) :: String.t()
  defp go_semantic_decode_file(schema) do
    structures = Map.get(schema, "structures", [])
    sections = sections_list(schema)
    command_fields = command_fields_list(schema)
    smap = structures_map(schema)

    [
      "// Code generated by mix protocol.gen. DO NOT EDIT.\n\n",
      "package generated\n\n",
      "import (\n\t\"encoding/binary\"\n\t\"fmt\"\n)\n\n",
      go_decode_helpers(),
      "\n",
      Enum.map(structures, &go_decode_structure(&1, smap)),
      "\n",
      go_decode_section_functions(sections, smap),
      go_decode_command_fields_functions(command_fields, smap)
    ]
    |> IO.iodata_to_binary()
    |> format_generated_go_file()
  end

  @spec go_decode_helpers() :: String.t()
  defp go_decode_helpers do
    """
    func decodeRequireLen(data []byte, needed int, label string) error {
    \tif len(data) < needed {
    \t\treturn fmt.Errorf("short %s", label)
    \t}
    \treturn nil
    }

    func decodeU16(data []byte, offset int) uint16 {
    \treturn binary.BigEndian.Uint16(data[offset : offset+2])
    }

    func decodeU24(data []byte, offset int) uint32 {
    \treturn uint32(data[offset])<<16 | uint32(data[offset+1])<<8 | uint32(data[offset+2])
    }

    func decodeU32(data []byte, offset int) uint32 {
    \treturn binary.BigEndian.Uint32(data[offset : offset+4])
    }

    func decodeU64(data []byte, offset int) uint64 {
    \treturn binary.BigEndian.Uint64(data[offset : offset+8])
    }

    func decodeString8(data []byte, offset int) (string, int, error) {
    \tif err := decodeRequireLen(data, offset+1, "string8 header"); err != nil {
    \t\treturn "", offset, err
    \t}
    \tl := int(data[offset])
    \toffset++
    \tif err := decodeRequireLen(data, offset+l, "string8 body"); err != nil {
    \t\treturn "", offset, err
    \t}
    \ts := string(data[offset : offset+l])
    \treturn s, offset + l, nil
    }

    func decodeString16(data []byte, offset int) (string, int, error) {
    \tif err := decodeRequireLen(data, offset+2, "string16 header"); err != nil {
    \t\treturn "", offset, err
    \t}
    \tl := int(decodeU16(data, offset))
    \toffset += 2
    \tif err := decodeRequireLen(data, offset+l, "string16 body"); err != nil {
    \t\treturn "", offset, err
    \t}
    \ts := string(data[offset : offset+l])
    \treturn s, offset + l, nil
    }

    func decodeString32(data []byte, offset int) (string, int, error) {
    \tif err := decodeRequireLen(data, offset+4, "string32 header"); err != nil {
    \t\treturn "", offset, err
    \t}
    \tl := int(decodeU32(data, offset))
    \toffset += 4
    \tif err := decodeRequireLen(data, offset+l, "string32 body"); err != nil {
    \t\treturn "", offset, err
    \t}
    \ts := string(data[offset : offset+l])
    \treturn s, offset + l, nil
    }
    """
  end

  @spec go_decode_structure(structure(), %{String.t() => structure()}) :: iodata()
  defp go_decode_structure(structure, smap) do
    name = structure["name"]
    struct_name = go_struct_name(name)
    fn_name = "Decode#{struct_name}"
    fields = structure["fields"] || []
    zero = "#{struct_name}{}"

    [
      "func #{fn_name}(data []byte, offset int) (#{struct_name}, int, error) {\n",
      "\tpos := offset\n",
      Enum.map(fields, &go_decode_field_statement(&1, smap, zero)),
      go_decode_conditional_tail_block(structure, smap, zero),
      "\treturn #{struct_name}{\n",
      Enum.map(entry_fields(structure), fn field ->
        "\t\t#{go_field_name(field["name"])}: #{go_local_name(field["name"])},\n"
      end),
      "\t}, pos, nil\n",
      "}\n\n"
    ]
  end

  @spec go_decode_field_statement(map(), %{String.t() => structure()}, String.t()) :: iodata()
  defp go_decode_field_statement(%{"name" => name, "type" => "u8"}, _smap, zero) do
    local = go_local_name(name)

    [
      "\tif err := decodeRequireLen(data, pos+1, \"#{name}\"); err != nil {\n",
      "\t\treturn #{zero}, offset, err\n",
      "\t}\n",
      "\t#{local} := data[pos]\n",
      "\tpos++\n"
    ]
  end

  defp go_decode_field_statement(%{"name" => name, "type" => "u16"}, _smap, zero) do
    local = go_local_name(name)

    [
      "\tif err := decodeRequireLen(data, pos+2, \"#{name}\"); err != nil {\n",
      "\t\treturn #{zero}, offset, err\n",
      "\t}\n",
      "\t#{local} := decodeU16(data, pos)\n",
      "\tpos += 2\n"
    ]
  end

  defp go_decode_field_statement(%{"name" => name, "type" => "u24"}, _smap, zero) do
    local = go_local_name(name)

    [
      "\tif err := decodeRequireLen(data, pos+3, \"#{name}\"); err != nil {\n",
      "\t\treturn #{zero}, offset, err\n",
      "\t}\n",
      "\t#{local} := decodeU24(data, pos)\n",
      "\tpos += 3\n"
    ]
  end

  defp go_decode_field_statement(%{"name" => name, "type" => "u32"}, _smap, zero) do
    local = go_local_name(name)

    [
      "\tif err := decodeRequireLen(data, pos+4, \"#{name}\"); err != nil {\n",
      "\t\treturn #{zero}, offset, err\n",
      "\t}\n",
      "\t#{local} := decodeU32(data, pos)\n",
      "\tpos += 4\n"
    ]
  end

  defp go_decode_field_statement(%{"name" => name, "type" => "u64"}, _smap, zero) do
    local = go_local_name(name)

    [
      "\tif err := decodeRequireLen(data, pos+8, \"#{name}\"); err != nil {\n",
      "\t\treturn #{zero}, offset, err\n",
      "\t}\n",
      "\t#{local} := decodeU64(data, pos)\n",
      "\tpos += 8\n"
    ]
  end

  defp go_decode_field_statement(%{"name" => name, "type" => "rgb"}, _smap, zero) do
    local = go_local_name(name)

    [
      "\tif err := decodeRequireLen(data, pos+3, \"#{name}\"); err != nil {\n",
      "\t\treturn #{zero}, offset, err\n",
      "\t}\n",
      "\t#{local} := decodeU24(data, pos)\n",
      "\tpos += 3\n"
    ]
  end

  defp go_decode_field_statement(%{"name" => name, "type" => "string8"}, _smap, zero) do
    local = go_local_name(name)

    [
      "\t#{local}, pos, err := decodeString8(data, pos)\n",
      "\tif err != nil {\n",
      "\t\treturn #{zero}, offset, err\n",
      "\t}\n"
    ]
  end

  defp go_decode_field_statement(%{"name" => name, "type" => "string16"}, _smap, zero) do
    local = go_local_name(name)

    [
      "\t#{local}, pos, err := decodeString16(data, pos)\n",
      "\tif err != nil {\n",
      "\t\treturn #{zero}, offset, err\n",
      "\t}\n"
    ]
  end

  defp go_decode_field_statement(%{"name" => name, "type" => "string32"}, _smap, zero) do
    local = go_local_name(name)

    [
      "\t#{local}, pos, err := decodeString32(data, pos)\n",
      "\tif err != nil {\n",
      "\t\treturn #{zero}, offset, err\n",
      "\t}\n"
    ]
  end

  defp go_decode_field_statement(
         %{"name" => name, "type" => "struct", "element" => element},
         _smap,
         zero
       ) do
    local = go_local_name(name)

    [
      "\t#{local}, pos, err := Decode#{go_struct_name(element)}(data, pos)\n",
      "\tif err != nil {\n",
      "\t\treturn #{zero}, offset, err\n",
      "\t}\n"
    ]
  end

  defp go_decode_field_statement(
         %{
           "name" => name,
           "type" => "counted_array",
           "count_type" => count_type,
           "element" => element
         },
         smap,
         zero
       ) do
    local = go_local_name(name)
    {count_read, count_size} = go_count_read(count_type)
    element_fixed_size = fixed_structure_size(element, smap)

    count_lines = [
      "\tif err := decodeRequireLen(data, pos+#{count_size}, \"#{name} count\"); err != nil {\n",
      "\t\treturn #{zero}, offset, err\n",
      "\t}\n",
      "\t#{local}Count := int(#{count_read})\n",
      "\tpos += #{count_size}\n"
    ]

    stride_check =
      case element_fixed_size do
        nil ->
          []

        stride ->
          [
            "\tif err := decodeRequireLen(data, pos+#{local}Count*#{stride}, \"#{name}\"); err != nil {\n",
            "\t\treturn #{zero}, offset, err\n",
            "\t}\n"
          ]
      end

    decode_lines = [
      "\t#{local} := make([]#{go_struct_name(element)}, 0, #{local}Count)\n",
      "\tfor i := 0; i < #{local}Count; i++ {\n",
      "\t\titem, nextPos, err := Decode#{go_struct_name(element)}(data, pos)\n",
      "\t\tif err != nil {\n",
      "\t\t\treturn #{zero}, offset, err\n",
      "\t\t}\n",
      "\t\tpos = nextPos\n",
      "\t\t#{local} = append(#{local}, item)\n",
      "\t}\n"
    ]

    count_lines ++ stride_check ++ decode_lines
  end

  @spec go_count_read(String.t()) :: {String.t(), non_neg_integer()}
  defp go_count_read("u8"), do: {"data[pos]", 1}
  defp go_count_read("u16"), do: {"decodeU16(data, pos)", 2}
  defp go_count_read("u32"), do: {"decodeU32(data, pos)", 4}

  @spec go_decode_section_functions([section()], %{String.t() => structure()}) :: iodata()
  defp go_decode_section_functions(sections, smap) do
    sections
    |> Enum.group_by(& &1["opcode"])
    |> Enum.sort_by(fn {opcode, _} -> opcode end)
    |> Enum.map(fn {opcode, secs} ->
      go_decode_opcode_sections(opcode, Enum.sort_by(secs, & &1["id"]), smap)
    end)
  end

  @spec go_decode_opcode_sections(String.t(), [section()], %{String.t() => structure()}) ::
          iodata()
  defp go_decode_opcode_sections(opcode, secs, smap) do
    [
      "// Section decoders for #{opcode}\n\n",
      Enum.map(secs, fn sec ->
        cond do
          entry_custom_layout?(sec) -> []
          sec["layout"] == "counted_array" -> go_decode_counted_array_section(opcode, sec, smap)
          true -> go_decode_inline_section(opcode, sec, smap)
        end
      end)
    ]
  end

  @spec go_decode_inline_section(String.t(), section(), %{String.t() => structure()}) :: iodata()
  defp go_decode_inline_section(_opcode, section, smap) do
    struct_name = go_section_struct_name(section)
    fn_name = "Decode#{go_struct_name(section["opcode"])}#{go_struct_name(section["name"])}"
    fields = section["fields"] || []
    zero = "#{struct_name}{}"

    [
      "func #{fn_name}(data []byte, offset int) (#{struct_name}, int, error) {\n",
      "\tpos := offset\n",
      Enum.map(fields, &go_decode_field_statement(&1, smap, zero)),
      go_decode_conditional_tail_block(section, smap, zero),
      "\treturn #{struct_name}{\n",
      Enum.map(entry_fields(section), fn field ->
        "\t\t#{go_field_name(field["name"])}: #{go_local_name(field["name"])},\n"
      end),
      "\t}, pos, nil\n",
      "}\n\n"
    ]
  end

  @spec go_decode_counted_array_section(String.t(), section(), %{String.t() => structure()}) ::
          iodata()
  defp go_decode_counted_array_section(_opcode, section, smap) do
    element = section["element"]
    element_struct = go_struct_name(element)
    fn_name = "Decode#{go_struct_name(section["opcode"])}#{go_struct_name(section["name"])}"
    count_type = section["count_type"] || "u16"
    {count_read, count_size} = go_count_read(count_type)
    element_fixed_size = fixed_structure_size(element, smap)

    stride_check =
      case element_fixed_size do
        nil ->
          []

        stride ->
          [
            "\tif err := decodeRequireLen(data, pos+count*#{stride}, \"#{section["name"]}\"); err != nil {\n",
            "\t\treturn nil, offset, err\n",
            "\t}\n"
          ]
      end

    [
      "func #{fn_name}(data []byte, offset int) ([]#{element_struct}, int, error) {\n",
      "\tpos := offset\n",
      "\tif err := decodeRequireLen(data, pos+#{count_size}, \"#{section["name"]} count\"); err != nil {\n",
      "\t\treturn nil, offset, err\n",
      "\t}\n",
      "\tcount := int(#{count_read})\n",
      "\tpos += #{count_size}\n",
      stride_check,
      "\titems := make([]#{element_struct}, 0, count)\n",
      "\tfor i := 0; i < count; i++ {\n",
      "\t\titem, nextPos, err := Decode#{element_struct}(data, pos)\n",
      "\t\tif err != nil {\n",
      "\t\t\treturn nil, offset, err\n",
      "\t\t}\n",
      "\t\tpos = nextPos\n",
      "\t\titems = append(items, item)\n",
      "\t}\n",
      "\treturn items, pos, nil\n",
      "}\n\n"
    ]
  end

  # ── Rust: command_fields types & decode ────────────────────────────────

  @spec rust_command_fields_struct_definitions([command_fields()], %{String.t() => structure()}) ::
          iodata()
  defp rust_command_fields_struct_definitions(command_fields, smap) do
    command_fields
    |> Enum.map(fn cf ->
      name = rust_struct_name(cf["opcode"]) <> "Fields"
      fields = entry_fields(cf)
      has_variable = Enum.any?(fields, fn f -> fixed_field_size(f, smap) == nil end)

      derive =
        if has_variable,
          do: "#[derive(Debug, Clone, PartialEq, Eq)]\n",
          else: "#[derive(Debug, Clone, Copy, PartialEq, Eq)]\n"

      [
        derive,
        "pub struct #{name} {\n",
        Enum.map(fields, fn field ->
          "    pub #{rust_field_name(field["name"])}: #{rust_type(field, smap)},\n"
        end),
        "}\n\n"
      ]
    end)
  end

  @spec rust_decode_command_fields_functions([command_fields()], %{String.t() => structure()}) ::
          iodata()
  defp rust_decode_command_fields_functions(command_fields, smap) do
    command_fields
    |> Enum.map(fn cf ->
      struct_name = rust_struct_name(cf["opcode"]) <> "Fields"
      fn_name = "decode_#{cf["opcode"]}_fields"
      fields = cf["fields"] || []

      [
        "// Command field decoder for #{cf["opcode"]}\n\n",
        "pub fn #{fn_name}(bytes: &[u8], offset: usize) -> Result<(#{struct_name}, usize), DecodeError> {\n",
        "    let mut pos = offset;\n",
        Enum.map(fields, &rust_decode_field_statement(&1, smap)),
        rust_decode_conditional_tail_block(cf, smap),
        "    Ok((#{struct_name} {\n",
        Enum.map(entry_fields(cf), fn field -> "        #{rust_field_name(field["name"])},\n" end),
        "    }, pos - offset))\n",
        "}\n\n"
      ]
    end)
  end

  # ── Go: command_fields types & decode ──────────────────────────────────

  @spec go_command_fields_struct_definitions([command_fields()], %{String.t() => structure()}) ::
          iodata()
  defp go_command_fields_struct_definitions(command_fields, smap) do
    command_fields
    |> Enum.map(fn cf ->
      name = go_struct_name(cf["opcode"]) <> "Fields"
      fields = entry_fields(cf)

      [
        "type #{name} struct {\n",
        Enum.map(fields, fn field ->
          "\t#{go_field_name(field["name"])} #{go_type(field, smap)}\n"
        end),
        "}\n\n"
      ]
    end)
  end

  @spec go_decode_command_fields_functions([command_fields()], %{String.t() => structure()}) ::
          iodata()
  defp go_decode_command_fields_functions(command_fields, smap) do
    command_fields
    |> Enum.map(fn cf ->
      struct_name = go_struct_name(cf["opcode"]) <> "Fields"
      fn_name = "Decode#{struct_name}"
      fields = cf["fields"] || []
      zero = "#{struct_name}{}"

      [
        "// Command field decoder for #{cf["opcode"]}\n\n",
        "func #{fn_name}(data []byte, offset int) (#{struct_name}, int, error) {\n",
        "\tpos := offset\n",
        Enum.map(fields, &go_decode_field_statement(&1, smap, zero)),
        go_decode_conditional_tail_block(cf, smap, zero),
        "\treturn #{struct_name}{\n",
        Enum.map(entry_fields(cf), fn field ->
          "\t\t#{go_field_name(field["name"])}: #{go_local_name(field["name"])},\n"
        end),
        "\t}, pos, nil\n",
        "}\n\n"
      ]
    end)
  end

  @spec constant_name(String.t()) :: String.t()
  defp constant_name(name), do: String.upcase(name)

  @spec go_constant_name(String.t()) :: String.t()
  defp go_constant_name(name) do
    name
    |> String.split("_")
    |> Enum.map_join("", &String.capitalize/1)
  end

  @spec hex(non_neg_integer()) :: String.t()
  defp hex(value),
    do: "0x" <> (value |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(2, "0"))
end
