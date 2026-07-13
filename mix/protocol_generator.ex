defmodule Minga.Mix.ProtocolGenerator do
  @moduledoc """
  Generates protocol opcode artifacts from `docs/protocol_schema.toml`.

  The schema is the source of truth. Generated protocol artifacts are written under `.generated/protocol/` for Elixir, `macos/.generated/protocol/` for Swift, `zig/src/generated/` for Zig, and `go/tui/internal/generated/` for the Go TUI. The generated Zig public export block in `zig/src/protocol.zig` is also refreshed from the schema.
  """

  @schema_path "docs/protocol_schema.toml"
  @generated_root ".generated/protocol"
  @generated_elixir_path Path.join([@generated_root, "elixir/lib/minga/protocol/opcodes.ex"])
  @generated_golden_fields_path Path.join([
                                  @generated_root,
                                  "elixir/lib/minga/protocol/golden_fields.ex"
                                ])
  @generated_encode_path Path.join([
                           @generated_root,
                           "elixir/lib/minga/protocol/encode.ex"
                         ])
  @generated_swift_path "macos/.generated/protocol/ProtocolOpcodes.generated.swift"
  @generated_zig_opcodes_path "zig/src/generated/protocol_opcodes.zig"
  @generated_zig_schema_test_path "zig/src/generated/protocol_schema_test.zig"
  @generated_go_opcodes_path "go/tui/internal/generated/opcodes.go"
  @generated_go_command_size_path "go/tui/internal/generated/command_size.go"
  @generated_zig_command_size_path "zig/src/generated/protocol_command_size.zig"
  @generated_swift_command_size_path "macos/.generated/protocol/ProtocolCommandSize.generated.swift"
  @generated_swift_semantic_decode_path "macos/.generated/protocol/ProtocolSemanticDecode.generated.swift"
  @generated_go_semantic_types_path "go/tui/internal/generated/semantic_types.go"
  @generated_go_semantic_decode_path "go/tui/internal/generated/semantic_decode.go"
  @generated_go_golden_path "go/tui/internal/generated/golden_decode.go"
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
  @type run_option :: {:format_generated_go, boolean()}

  @spec run([String.t()]) :: :ok
  def run(args), do: run(args, [])

  @spec run([String.t()], [run_option()]) :: :ok
  def run(args, options) do
    ensure_generator_deps_loaded!()

    {opts, _argv, _invalid} = OptionParser.parse(args, strict: [check: :boolean])
    schema = load_schema!()
    files = generated_files(schema, Keyword.get(options, :format_generated_go, true))

    if Keyword.get(opts, :check, false) do
      check_files!(files)
      check_zig_protocol_exports!(schema)
    else
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
      {:ok, schema} -> schema |> validate_schema!() |> attach_enum_reprs()
      {:error, reason} -> Mix.raise("Failed to parse #{@schema_path}: #{inspect(reason)}")
    end
  end

  # Annotate every `type = "enum"` field with the repr primitive of its enum so
  # the downstream sizing/decode helpers can read it as that primitive while the
  # Go type mapping still names the typed constant. Runs after validation so the
  # enum reference is known to resolve.
  @spec attach_enum_reprs(schema()) :: schema()
  defp attach_enum_reprs(schema) do
    emap = enums_map(schema)

    schema
    |> Map.update("structures", [], fn structs ->
      Enum.map(structs, &map_entry_fields(&1, emap))
    end)
    |> Map.update("sections", [], fn sections ->
      Enum.map(sections, &map_entry_fields(&1, emap))
    end)
    |> Map.update("command_fields", [], fn cfs -> Enum.map(cfs, &map_entry_fields(&1, emap)) end)
  end

  @spec map_entry_fields(map(), %{String.t() => enum()}) :: map()
  defp map_entry_fields(entry, emap) do
    entry
    |> maybe_map_fields("fields", emap)
    |> maybe_map_conditional_tail(emap)
  end

  @spec maybe_map_fields(map(), String.t(), %{String.t() => enum()}) :: map()
  defp maybe_map_fields(entry, key, emap) do
    case Map.get(entry, key) do
      fields when is_list(fields) ->
        Map.put(entry, key, Enum.map(fields, &annotate_enum_field(&1, emap)))

      _ ->
        entry
    end
  end

  @spec maybe_map_conditional_tail(map(), %{String.t() => enum()}) :: map()
  defp maybe_map_conditional_tail(entry, emap) do
    case Map.get(entry, "conditional_tail") do
      %{} = tail -> Map.put(entry, "conditional_tail", maybe_map_fields(tail, "fields", emap))
      _ -> entry
    end
  end

  @spec annotate_enum_field(map(), %{String.t() => enum()}) :: map()
  defp annotate_enum_field(%{"type" => "enum", "enum" => name} = field, emap) do
    Map.put(field, "repr", Map.fetch!(emap, name)["repr"])
  end

  defp annotate_enum_field(field, _emap), do: field

  @spec validate_schema!(schema()) :: schema()
  defp validate_schema!(schema) do
    validate_opcode_categories!(schema)
    validate_opcode_directions!(schema)
    validate_duplicate_values!(Map.fetch!(schema, "opcodes"), "opcode")
    validate_duplicate_values!(Map.fetch!(schema, "gui_actions"), "GUI action")
    validate_gui_action_canonicals!(Map.fetch!(schema, "gui_actions"))
    validate_framing!(schema)
    validate_enums!(schema)
    validate_structures!(schema)
    validate_sections!(schema)
    validate_command_fields!(schema)
    validate_enum_field_refs!(schema)
    validate_conditional_tail_guards!(schema)
    schema
  end

  # A conditional_tail guard is decoded by substituting base-field names with
  # their decoded locals (go_guard_expression). It must render identically in Go
  # and Elixir after substitution, so the legal
  # grammar is the cross-language-common subset: base-field identifiers, integer
  # literals, the boolean literals `true`/`false`, comparison operators
  # (== != < > <= >=), and the connectives && / ||. Any other identifier (named
  # constant, helper call, a language keyword like Go's `in`) is emitted verbatim
  # and would not compile, so it is rejected here with a clear message instead.
  @guard_literals ~w(true false)

  @spec validate_conditional_tail_guards!(schema()) :: :ok
  defp validate_conditional_tail_guards!(schema) do
    entries =
      Map.get(schema, "structures", []) ++
        Map.get(schema, "sections", []) ++
        command_fields_list(schema)

    bad =
      entries
      |> Enum.filter(&entry_conditional_tail/1)
      |> Enum.flat_map(fn entry ->
        base = Map.get(entry, "fields", []) |> MapSet.new(& &1["name"])
        label = entry["name"] || entry["opcode"]

        (conditional_tail_guard(entry) || "")
        |> guard_identifiers()
        |> Enum.reject(&(MapSet.member?(base, &1) or &1 in @guard_literals))
        |> Enum.map(fn id -> "#{label} -> #{id}" end)
      end)

    case bad do
      [] ->
        :ok

      _ ->
        Mix.raise(
          "conditional_tail guards must reference only base fields in #{@schema_path}: " <>
            Enum.join(bad, ", ")
        )
    end
  end

  @spec guard_identifiers(String.t()) :: [String.t()]
  @spec guard_identifiers(String.t()) :: [String.t()]
  defp guard_identifiers(guard) do
    ~r/[A-Za-z_][A-Za-z0-9_]*/
    |> Regex.scan(guard)
    |> List.flatten()
  end

  @spec generated_files(schema(), boolean()) :: [generated_file()]
  defp generated_files(schema, format_generated_go) do
    [
      {@generated_elixir_path, elixir_file(schema)},
      {@generated_golden_fields_path, golden_fields_elixir_file(schema)},
      {@generated_encode_path, encode_elixir_file(schema)},
      {@generated_swift_path, swift_file(schema)},
      {@generated_zig_opcodes_path, zig_opcodes_file(schema)},
      {@generated_zig_schema_test_path, zig_schema_test_file(schema)},
      {@generated_go_opcodes_path, go_opcodes_file(schema, format_generated_go)},
      {@generated_go_command_size_path, go_command_size_file(schema, format_generated_go)},
      {@generated_zig_command_size_path, zig_command_size_file(schema)},
      {@generated_swift_command_size_path, swift_command_size_file(schema)},
      {@generated_swift_semantic_decode_path, swift_semantic_decode_file(schema)},
      {@generated_go_semantic_types_path, go_semantic_types_file(schema, format_generated_go)},
      {@generated_go_semantic_decode_path, go_semantic_decode_file(schema, format_generated_go)},
      {@generated_go_golden_path, go_golden_decode_file(schema, format_generated_go)}
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

  @spec maybe_format_generated_go_file(String.t(), boolean()) :: String.t()
  defp maybe_format_generated_go_file(binary, false), do: binary
  defp maybe_format_generated_go_file(binary, true), do: format_generated_go_file(binary)

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

    if current == replace_zig_protocol_export_block!(current, expected) do
      :ok
    else
      Mix.raise(outdated_zig_protocol_exports_message())
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
      "  # Protocol version\n",
      "  @spec protocol_version() :: non_neg_integer()\n",
      "  def protocol_version, do: #{protocol_version(schema)}\n\n",
      elixir_opcode_functions(opcodes),
      "\n",
      elixir_gui_action_functions(actions),
      "end\n"
    ]
    |> IO.iodata_to_binary()
  end

  @spec protocol_version(schema()) :: non_neg_integer()
  defp protocol_version(schema), do: Map.fetch!(schema, "protocol_version")

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
      "// MARK: - Protocol version\n\n",
      "let PROTOCOL_VERSION: UInt16 = #{protocol_version(schema)}\n\n",
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
      "// Protocol version.\n\n",
      "pub const PROTOCOL_VERSION: u16 = #{protocol_version(schema)};\n\n",
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

  @spec go_opcodes_file(schema(), boolean()) :: String.t()
  defp go_opcodes_file(schema, format_generated_go) do
    opcodes = Map.fetch!(schema, "opcodes")
    actions = Map.fetch!(schema, "gui_actions")

    [
      "// Code generated by mix protocol.gen. DO NOT EDIT.\n\n",
      "package generated\n\n",
      "// ProtocolVersion is the wire-contract version the frontend exchanges with\n",
      "// the BEAM in the ready handshake. A mismatch yields an explicit protocol_error.\n",
      "const ProtocolVersion uint16 = #{protocol_version(schema)}\n\n",
      "const (\n",
      go_opcodes(opcodes),
      go_gui_actions(actions),
      ")\n"
    ]
    |> IO.iodata_to_binary()
    |> maybe_format_generated_go_file(format_generated_go)
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
    |> Enum.map(fn entry -> String.length(name_fun.(entry)) end)
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
      |> Enum.filter(fn {_value, grouped} -> Enum.count(grouped) > 1 end)
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
        groups = Map.update(groups, category, [opcode], &[opcode | &1])
        {groups, order}
      end)

    Enum.map(order, fn category ->
      {category, groups |> Map.fetch!(category) |> Enum.reverse()}
    end)
  end

  @spec add_category_order([String.t()], String.t()) :: [String.t()]
  defp add_category_order(order, category) do
    if category in order do
      order
    else
      List.insert_at(order, -1, category)
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
  #   sectioned32 opcode(1) + section_count(u8) + sections => 2 + sum(5 + section_len)
  #   custom     bespoke layout; the frontend's decoder owns sizing
  #
  # The generated `command_size` functions size every generic framing and report
  # `custom` for the rest. New opcodes at 0x90+ are also handled by the
  # forward-compatible len16 fallback even before a frontend learns to size them.

  @allowed_simple_framings ~w(len16 len32 sectioned sectioned32 custom)

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

  @spec framing_kind(opcode()) ::
          {:fixed, pos_integer()} | :len16 | :len32 | :sectioned | :sectioned32 | :custom
  defp framing_kind(%{"framing" => "fixed:" <> rest}), do: {:fixed, String.to_integer(rest)}
  defp framing_kind(%{"framing" => framing}), do: String.to_atom(framing)

  # ── Enums ─────────────────────────────────────────────────────────────────
  #
  # An [[enums]] entry declares a closed byte vocabulary. A field references it
  # with `type = "enum", enum = "<name>"`; it is sized and decoded as the
  # underlying `repr` primitive and surfaces in generated decoders as a typed
  # constant. Validation guards the invariants the consult locked: unique value
  # bytes, every byte in range for the repr, and a `default` that resolves to a
  # declared value.

  @type enum :: %{String.t() => term()}

  @enum_repr_max %{"u8" => 0xFF, "u16" => 0xFFFF, "u32" => 0xFFFFFFFF}

  @spec enums_list(schema()) :: [enum()]
  defp enums_list(schema), do: Map.get(schema, "enums", [])

  @spec enums_map(schema()) :: %{String.t() => enum()}
  defp enums_map(schema), do: Map.new(enums_list(schema), fn e -> {e["name"], e} end)

  @spec enum_field?(map()) :: boolean()
  defp enum_field?(%{"type" => "enum"}), do: true
  defp enum_field?(_field), do: false

  @spec validate_enums!(schema()) :: :ok
  defp validate_enums!(schema) do
    enums = enums_list(schema)
    validate_enum_names!(enums)

    Enum.each(enums, fn enum ->
      validate_enum_repr!(enum)
      validate_enum_values!(enum)
      validate_enum_default!(enum)
    end)
  end

  @spec validate_enum_names!([enum()]) :: :ok
  defp validate_enum_names!(enums) do
    names = Enum.map(enums, & &1["name"])
    dupes = names -- Enum.uniq(names)

    case dupes do
      [] ->
        :ok

      _ ->
        Mix.raise("Duplicate enum names in #{@schema_path}: #{Enum.join(Enum.uniq(dupes), ", ")}")
    end
  end

  @spec validate_enum_repr!(enum()) :: :ok
  defp validate_enum_repr!(%{"repr" => repr})
       when is_map_key(@enum_repr_max, repr),
       do: :ok

  defp validate_enum_repr!(%{"name" => name} = enum) do
    Mix.raise(
      "Enum #{name} has invalid repr #{inspect(enum["repr"])} in #{@schema_path} (allowed: u8, u16, u32)"
    )
  end

  @spec validate_enum_values!(enum()) :: :ok
  defp validate_enum_values!(%{"name" => name, "repr" => repr} = enum) do
    values = Map.get(enum, "values", [])
    max = @enum_repr_max[repr]

    out_of_range =
      values
      |> Enum.reject(fn v -> is_integer(v["value"]) and v["value"] >= 0 and v["value"] <= max end)
      |> Enum.map_join(", ", fn v -> "#{v["name"]}=#{inspect(v["value"])}" end)

    case out_of_range do
      "" ->
        :ok

      _ ->
        Mix.raise(
          "Enum #{name} values out of range for #{repr} in #{@schema_path}: #{out_of_range}"
        )
    end

    byte_values = Enum.map(values, & &1["value"])
    dupes = byte_values -- Enum.uniq(byte_values)

    case dupes do
      [] ->
        :ok

      _ ->
        Mix.raise(
          "Enum #{name} has duplicate value bytes in #{@schema_path}: #{Enum.join(Enum.uniq(dupes), ", ")}"
        )
    end
  end

  @spec validate_enum_default!(enum()) :: :ok
  defp validate_enum_default!(%{"default" => nil}), do: :ok
  defp validate_enum_default!(enum) when not is_map_key(enum, "default"), do: :ok

  defp validate_enum_default!(%{"name" => name, "default" => default} = enum) do
    value_names = enum |> Map.get("values", []) |> MapSet.new(& &1["name"])

    if MapSet.member?(value_names, default) do
      :ok
    else
      Mix.raise(
        "Enum #{name} default #{inspect(default)} is not a declared value in #{@schema_path}"
      )
    end
  end

  @spec validate_enum_field_refs!(schema()) :: :ok
  defp validate_enum_field_refs!(schema) do
    emap = enums_map(schema)

    entries =
      Map.get(schema, "structures", []) ++
        Enum.reject(sections_list(schema), &entry_custom_layout?/1) ++
        command_fields_list(schema)

    bad =
      entries
      |> Enum.flat_map(fn entry ->
        label = entry["name"] || entry["opcode"]
        Enum.map(entry_fields(entry), &{label, &1})
      end)
      |> Enum.filter(fn {_label, field} ->
        enum_field?(field) and not Map.has_key?(emap, field["enum"])
      end)
      |> Enum.map_join(", ", fn {label, field} ->
        "#{label}.#{field["name"]} -> #{inspect(field["enum"])}"
      end)

    case bad do
      "" -> :ok
      _ -> Mix.raise("Fields reference unknown enums in #{@schema_path}: #{bad}")
    end
  end

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

  @spec swift_zig_const_name(opcode()) :: String.t()
  defp swift_zig_const_name(%{"name" => name}), do: "OP_#{constant_name(name)}"

  # ── Go: command_size.go ───────────────────────────────────────────────────

  @spec go_command_size_file(schema(), boolean()) :: String.t()
  defp go_command_size_file(schema, format_generated_go) do
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
       "\tcase #{ops |> opcodes_of_kind(:sectioned32) |> Enum.map_join(", ", cn)}:\n\t\treturn sectioned32CommandSize(payload)\n" <>
       "\tcase #{ops |> opcodes_of_kind(:custom) |> Enum.map_join(", ", cn)}:\n\t\treturn 0, CommandSizeCustom\n" <>
       "\tdefault:\n" <>
       "\t\t// Forward-compatibility: opcodes >= 0x90 carry a u16 length prefix.\n" <>
       "\t\tif payload[0] >= 0x90 {\n\t\t\treturn len16CommandSize(payload)\n\t\t}\n" <>
       "\t\treturn 0, CommandSizeUnknown\n" <>
       "\t}\n}\n\n" <>
       go_command_size_helpers())
    |> maybe_format_generated_go_file(format_generated_go)
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

        func sectioned32CommandSize(payload []byte) (int, CommandSizeStatus) {
        if len(payload) < 2 {
        return 0, CommandSizeIncomplete
        }
        offset := 2
        count := int(payload[1])
        for i := 0; i < count; i++ {
        if len(payload) < offset+5 {
        return 0, CommandSizeIncomplete
        }
        offset += 5 + int(payload[offset+1])<<24 + int(payload[offset+2])<<16 + int(payload[offset+3])<<8 + int(payload[offset+4])
        if len(payload) < offset {
        return 0, CommandSizeIncomplete
        }
        }
        return offset, CommandSizeOK
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

  # ── Zig: protocol_command_size.zig ────────────────────────────────────────

  @spec zig_command_size_file(schema()) :: String.t()
  defp zig_command_size_file(schema) do
    ops = framing_opcodes(schema)
    cn = &swift_zig_const_name/1

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
      zig_arm.(:sectioned32, "sectioned32(payload)") <>
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

    fn sectioned32(payload: []const u8) Result {
        if (payload.len < 2) return .{ .status = .incomplete };
        var offset: usize = 2;
        const count: usize = payload[1];
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (payload.len < offset + 5) return .{ .status = .incomplete };
            offset += 5 + (@as(usize, payload[offset + 1]) << 24 | @as(usize, payload[offset + 2]) << 16 | @as(usize, payload[offset + 3]) << 8 | @as(usize, payload[offset + 4]));
            if (payload.len < offset) return .{ .status = .incomplete };
        }
        return .{ .status = .sized, .size = offset };
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
    cn = &swift_zig_const_name/1

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
      "/// derived from each opcode's schema framing. Accepting integer-indexed\n" <>
      "/// collections lets Data slices be sized without copying packet tails.\n" <>
      "public func commandSize<C: RandomAccessCollection>(_ payload: C) -> CommandSizeResult where C.Element == UInt8, C.Index == Int {\n" <>
      "    guard let opcode = payload.first else { return .incomplete }\n" <>
      "    switch opcode {\n" <>
      IO.iodata_to_binary(fixed_cases) <>
      swift_case.(:len16, "len16CommandSize(payload)") <>
      swift_case.(:len32, "len32CommandSize(payload)") <>
      swift_case.(:sectioned, "sectionedCommandSize(payload)") <>
      swift_case.(:sectioned32, "sectioned32CommandSize(payload)") <>
      swift_custom_case.() <>
      "    default:\n" <>
      "        return .unknown\n" <>
      "    }\n}\n\n" <>
      swift_command_size_helpers()
  end

  @spec swift_command_size_helpers() :: String.t()
  defp swift_command_size_helpers do
    """
    private func fixedCommandSize<C: RandomAccessCollection>(_ payload: C, _ size: Int) -> CommandSizeResult where C.Element == UInt8, C.Index == Int {
        payload.count < size ? .incomplete : .sized(size)
    }

    private func byte<C: RandomAccessCollection>(_ payload: C, _ offset: Int) -> UInt8 where C.Element == UInt8, C.Index == Int {
        payload[payload.startIndex + offset]
    }

    private func len16CommandSize<C: RandomAccessCollection>(_ payload: C) -> CommandSizeResult where C.Element == UInt8, C.Index == Int {
        if payload.count < 3 { return .incomplete }
        let size = 3 + (Int(byte(payload, 1)) << 8 | Int(byte(payload, 2)))
        return payload.count < size ? .incomplete : .sized(size)
    }

    private func len32CommandSize<C: RandomAccessCollection>(_ payload: C) -> CommandSizeResult where C.Element == UInt8, C.Index == Int {
        if payload.count < 5 { return .incomplete }
        let size = 5 + (Int(byte(payload, 1)) << 24 | Int(byte(payload, 2)) << 16 | Int(byte(payload, 3)) << 8 | Int(byte(payload, 4)))
        return payload.count < size ? .incomplete : .sized(size)
    }

    private func sectioned32CommandSize<C: RandomAccessCollection>(_ payload: C) -> CommandSizeResult where C.Element == UInt8, C.Index == Int {
        if payload.count < 2 { return .incomplete }
        var offset = 2
        let count = Int(byte(payload, 1))
        for _ in 0..<count {
            if payload.count < offset + 5 { return .incomplete }
            offset += 5 + (Int(byte(payload, offset + 1)) << 24 | Int(byte(payload, offset + 2)) << 16 | Int(byte(payload, offset + 3)) << 8 | Int(byte(payload, offset + 4)))
            if payload.count < offset { return .incomplete }
        }
        return .sized(offset)
    }

    private func sectionedCommandSize<C: RandomAccessCollection>(_ payload: C) -> CommandSizeResult where C.Element == UInt8, C.Index == Int {
        if payload.count < 2 { return .incomplete }
        var offset = 2
        let count = Int(byte(payload, 1))
        for _ in 0..<count {
            if payload.count < offset + 3 { return .incomplete }
            offset += 3 + (Int(byte(payload, offset + 1)) << 8 | Int(byte(payload, offset + 2)))
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
          is_binary(field["element"]) and
          not element_resolves?(field["type"], field["element"], smap)
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
    validate_optional_fields!(schema, sections)
  end

  # `optional = true` is a section-only, suffix-only tail marker. It is rejected
  # on command_fields, structures, and counted_array-layout sections (none carry
  # a section window), and within an inline section the optional fields must form
  # a contiguous trailing run (a non-optional field may not follow an optional
  # one). Conditional-tail fields are never optional: a guarded tail is all-or-
  # nothing, decoded only when its guard holds.
  @spec validate_optional_fields!(schema(), [section()]) :: :ok
  defp validate_optional_fields!(schema, sections) do
    raise_if_any!(
      non_section_optionals(schema),
      "`optional = true` is only allowed on section fields"
    )

    raise_if_any!(
      counted_array_optionals(sections),
      "`optional = true` is not allowed on counted_array sections"
    )

    raise_if_any!(
      conditional_tail_optionals(sections),
      "`optional = true` is not allowed on conditional_tail fields"
    )

    raise_if_any!(
      non_suffix_optional_sections(sections),
      "`optional = true` fields must be a contiguous trailing suffix"
    )
  end

  @spec raise_if_any!([String.t()], String.t()) :: :ok
  defp raise_if_any!([], _message), do: :ok

  defp raise_if_any!(bad, message),
    do: Mix.raise("#{message} in #{@schema_path}: #{Enum.join(bad, ", ")}")

  @spec non_section_optionals(schema()) :: [String.t()]
  defp non_section_optionals(schema) do
    (Map.get(schema, "structures", []) ++ command_fields_list(schema))
    |> Enum.flat_map(fn entry ->
      entry
      |> entry_fields()
      |> Enum.filter(&field_optional?/1)
      |> Enum.map(fn field -> "#{entry["name"] || entry["opcode"]}.#{field["name"]}" end)
    end)
  end

  @spec counted_array_optionals([section()]) :: [String.t()]
  defp counted_array_optionals(sections) do
    sections
    |> Enum.filter(fn s -> s["layout"] == "counted_array" end)
    |> Enum.flat_map(&optional_field_labels/1)
  end

  @spec conditional_tail_optionals([section()]) :: [String.t()]
  defp conditional_tail_optionals(sections) do
    Enum.flat_map(sections, fn s ->
      s
      |> conditional_tail_fields()
      |> Enum.filter(&field_optional?/1)
      |> Enum.map(fn f -> "#{s["opcode"]}/#{s["name"]}.#{f["name"]}" end)
    end)
  end

  @spec non_suffix_optional_sections([section()]) :: [String.t()]
  defp non_suffix_optional_sections(sections) do
    sections
    |> Enum.reject(fn s ->
      entry_custom_layout?(s) or s["layout"] == "counted_array" or
        s |> Map.get("fields", []) |> optional_suffix?()
    end)
    |> Enum.map(fn s -> "#{s["opcode"]}/#{s["name"]}" end)
  end

  @spec optional_field_labels(section()) :: [String.t()]
  defp optional_field_labels(s) do
    s
    |> entry_fields()
    |> Enum.filter(&field_optional?/1)
    |> Enum.map(fn field -> "#{s["opcode"]}/#{s["name"]}.#{field["name"]}" end)
  end

  # True when no required (non-optional) field follows an optional one.
  @spec optional_suffix?([map()]) :: boolean()
  defp optional_suffix?(fields) do
    fields
    |> Enum.drop_while(&(not field_optional?(&1)))
    |> Enum.all?(&field_optional?/1)
  end

  @spec field_optional?(map()) :: boolean()
  defp field_optional?(field), do: Map.get(field, "optional", false) == true

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
        |> Enum.filter(fn {_id, grouped} -> Enum.count(grouped) > 1 end)
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
      |> Enum.reject(fn s -> element_resolves?("counted_array", s["element"], smap) end)
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
          is_binary(field["element"]) and
          not element_resolves?(field["type"], field["element"], smap)
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
          is_binary(field["element"]) and
          not element_resolves?(field["type"], field["element"], smap)
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

  # Single source of truth for how each primitive wire type is read, shared by
  # the scalar-field, conditional-tail, and counted_array-element decoders. Byte
  # sizes come from @primitive_sizes so a width lives in exactly one place.
  @go_primitive_reads %{
    "u8" => "data[pos]",
    "u16" => "decodeU16(data, pos)",
    "u24" => "decodeU24(data, pos)",
    "rgb" => "decodeU24(data, pos)",
    "u32" => "decodeU32(data, pos)",
    "u64" => "decodeU64(data, pos)"
  }

  # Window-bounded string readers, used inside generated record decoders so every
  # read bounds against the section window end instead of the whole buffer.
  @go_string_window_decoders %{
    "string8" => "decodeString8Window",
    "string16" => "decodeString16Window",
    "string32" => "decodeString32Window"
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

  defp fixed_field_size(%{"type" => "enum", "repr" => repr}, smap),
    do: fixed_type_size(repr, smap)

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

  # Go advances the cursor with `pos++` for a single byte and `pos += N`
  # otherwise; preserved so single-byte reads regenerate byte-for-byte.
  @spec go_pos_advance(non_neg_integer(), String.t()) :: String.t()
  defp go_pos_advance(1, indent), do: "#{indent}pos++\n"
  defp go_pos_advance(size, indent), do: "#{indent}pos += #{size}\n"

  @spec go_decode_field_assignment_statement(map(), %{String.t() => structure()}, String.t()) ::
          iodata()
  defp go_decode_field_assignment_statement(
         %{"name" => name, "type" => "enum", "enum" => enum_name, "repr" => repr},
         _smap,
         zero
       ) do
    local = go_local_name(name)
    size = @primitive_sizes[repr]

    [
      "\t\tif err := decodeRequireWindow(windowEnd, pos+#{size}, \"#{name}\"); err != nil {\n",
      "\t\t\treturn #{zero}, offset, err\n",
      "\t\t}\n",
      "\t\t#{local} = #{go_struct_name(enum_name)}(#{@go_primitive_reads[repr]})\n",
      go_pos_advance(size, "\t\t")
    ]
  end

  defp go_decode_field_assignment_statement(%{"name" => name, "type" => type}, _smap, zero)
       when is_map_key(@go_primitive_reads, type) do
    local = go_local_name(name)
    size = @primitive_sizes[type]

    [
      "\t\tif err := decodeRequireWindow(windowEnd, pos+#{size}, \"#{name}\"); err != nil {\n",
      "\t\t\treturn #{zero}, offset, err\n",
      "\t\t}\n",
      "\t\t#{local} = #{@go_primitive_reads[type]}\n",
      go_pos_advance(size, "\t\t")
    ]
  end

  defp go_decode_field_assignment_statement(%{"name" => name, "type" => str}, _smap, zero)
       when is_map_key(@go_string_window_decoders, str) do
    local = go_local_name(name)

    [
      "\t\t#{local}, pos, err = #{@go_string_window_decoders[str]}(data, pos, windowEnd)\n",
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
      "\t\t#{local}, pos, err = Decode#{go_struct_name(element)}(data, pos, windowEnd)\n",
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

    stride_check =
      case element_fixed_byte_size(element, smap) do
        nil ->
          []

        stride ->
          [
            "\t\tif err := decodeRequireWindow(windowEnd, pos+#{local}Count*#{stride}, \"#{name}\"); err != nil {\n",
            "\t\t\treturn #{zero}, offset, err\n",
            "\t\t}\n"
          ]
      end

    [
      "\t\tif err := decodeRequireWindow(windowEnd, pos+#{count_size}, \"#{name} count\"); err != nil {\n",
      "\t\t\treturn #{zero}, offset, err\n",
      "\t\t}\n",
      "\t\t#{local}Count := int(#{count_read})\n",
      "\t\tpos += #{count_size}\n",
      stride_check,
      "\t\t#{local} = make([]#{go_type(element_field(element), smap)}, 0, #{go_prealloc("#{local}Count", element, smap)})\n",
      "\t\tfor i := 0; i < #{local}Count; i++ {\n",
      go_decode_array_element(element, local, "\t\t\t", zero),
      "\t\t}\n"
    ]
  end

  # Locals the generated decoders introduce themselves. A schema field whose
  # name matches one of these would shadow the byte cursor, input slice, or loop
  # temp and silently corrupt decoding (or fail to compile in Go), so field names
  # that collide are suffixed. Kept in sync with the decode templates below.
  @reserved_decoder_locals ~w(pos offset data bytes err item consumed next_pos count)

  # A counted_array element is either a named structure or a bare wire type
  # (primitive or string). This normalizes it to a field-shaped map so the
  # existing type/size helpers apply, which lets counted_array hold primitives
  # directly without a single-field wrapper structure.
  @element_wire_types ~w(u8 u16 u24 u32 u64 rgb string8 string16 string32)
  @spec element_field(String.t()) :: map()
  defp element_field(element) when element in @element_wire_types, do: %{"type" => element}
  defp element_field(element), do: %{"type" => "struct", "element" => element}

  # Fixed byte size of one counted_array element (nil for variable-size:
  # strings, or structures that contain strings/arrays).
  @spec element_fixed_byte_size(String.t(), %{String.t() => structure()}) ::
          non_neg_integer() | nil
  defp element_fixed_byte_size(element, smap), do: fixed_field_size(element_field(element), smap)

  # Whether a struct/counted_array element reference resolves: counted_array may
  # name a bare wire type (primitive/string) or a structure; a struct field must
  # name a defined structure.
  @spec element_resolves?(String.t(), term(), %{String.t() => structure()}) :: boolean()
  defp element_resolves?("counted_array", element, smap),
    do: element in @element_wire_types or Map.has_key?(smap, element)

  defp element_resolves?(_type, element, smap), do: Map.has_key?(smap, element)

  # Upper bound on the capacity we pre-allocate from a wire-supplied count.
  # Fixed-size element arrays are already bounded by their `count * stride`
  # length check, so only variable-size element arrays (strings / structs with
  # strings) need a clamp to stop a bogus count from forcing a large speculative
  # allocation before any element bytes are validated. Every element occupies at
  # least one byte, so the remaining buffer length is a safe, self-scaling upper
  # bound: tight for small buffers (DoS-safe) and unbounded for genuinely large
  # payloads (no needless regrowth).
  @spec go_prealloc(String.t(), String.t(), %{String.t() => structure()}) :: String.t()
  defp go_prealloc(count_var, element, smap) do
    case element_fixed_byte_size(element, smap) do
      nil -> "min(#{count_var}, len(data)-pos)"
      _ -> count_var
    end
  end

  # ── Go type mapping helpers ───────────────────────────────────────────────

  @spec go_type(map(), %{String.t() => structure()}) :: String.t()
  defp go_type(%{"type" => "enum", "enum" => name}, _smap), do: go_struct_name(name)
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

  defp go_type(%{"type" => "counted_array", "element" => element}, smap) do
    "[]#{go_type(element_field(element), smap)}"
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

    if camel in @go_keywords or name in @reserved_decoder_locals,
      do: camel <> "Val",
      else: camel
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

  @spec go_semantic_types_file(schema(), boolean()) :: String.t()
  defp go_semantic_types_file(schema, format_generated_go) do
    structures = Map.get(schema, "structures", [])
    sections = sections_list(schema)
    command_fields = command_fields_list(schema)
    smap = structures_map(schema)

    [
      "// Code generated by mix protocol.gen. DO NOT EDIT.\n\n",
      "package generated\n\n",
      go_enum_definitions(enums_list(schema)),
      go_structure_definitions(structures, smap),
      go_size_constants(structures, smap),
      go_section_struct_definitions(sections, smap),
      go_command_fields_struct_definitions(command_fields, smap)
    ]
    |> IO.iodata_to_binary()
    |> maybe_format_generated_go_file(format_generated_go)
  end

  # Emit one named uint type per enum plus a typed constant for each value, so a
  # decoded enum field surfaces as a self-documenting constant instead of a bare
  # byte while still marshaling to its integer value.
  @spec go_enum_definitions([enum()]) :: iodata()
  defp go_enum_definitions([]), do: []

  defp go_enum_definitions(enums) do
    Enum.map(enums, fn enum ->
      type_name = go_struct_name(enum["name"])
      values = Map.get(enum, "values", [])

      width =
        values
        |> Enum.map(fn v -> String.length("#{type_name}#{go_struct_name(v["name"])}") end)
        |> Enum.max(fn -> 0 end)

      [
        "// #{type_name} is a generated enum (repr #{enum["repr"]}).\n",
        "type #{type_name} #{go_type(%{"type" => enum["repr"]}, %{})}\n\n",
        "const (\n",
        Enum.map(values, fn v ->
          cname = "#{type_name}#{go_struct_name(v["name"])}"
          "\t#{String.pad_trailing(cname, width)} #{type_name} = #{v["value"]}\n"
        end),
        ")\n\n"
      ]
    end)
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

  @spec go_semantic_decode_file(schema(), boolean()) :: String.t()
  defp go_semantic_decode_file(schema, format_generated_go) do
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
    |> maybe_format_generated_go_file(format_generated_go)
  end

  @spec go_decode_helpers() :: String.t()
  defp go_decode_helpers do
    """
    // decodeRequireWindow bounds a section read against the section window end
    // (sectionStart + sectionLen) so a section decoder never reads past its own
    // section even when the underlying buffer carries more bytes.
    func decodeRequireWindow(windowEnd, needed int, label string) error {
    \tif needed > windowEnd {
    \t\treturn fmt.Errorf("short %s", label)
    \t}
    \treturn nil
    }

    // decodeString8Window/16/32 decode a length-prefixed UTF-8 string but bound
    // both the length header and the body against the section window end, so a
    // section decoder never reads past its own section.
    func decodeString8Window(data []byte, offset, windowEnd int) (string, int, error) {
    \tif err := decodeRequireWindow(windowEnd, offset+1, "string8 header"); err != nil {
    \t\treturn "", offset, err
    \t}
    \tl := int(data[offset])
    \toffset++
    \tif err := decodeRequireWindow(windowEnd, offset+l, "string8 body"); err != nil {
    \t\treturn "", offset, err
    \t}
    \ts := string(data[offset : offset+l])
    \treturn s, offset + l, nil
    }

    func decodeString16Window(data []byte, offset, windowEnd int) (string, int, error) {
    \tif err := decodeRequireWindow(windowEnd, offset+2, "string16 header"); err != nil {
    \t\treturn "", offset, err
    \t}
    \tl := int(decodeU16(data, offset))
    \toffset += 2
    \tif err := decodeRequireWindow(windowEnd, offset+l, "string16 body"); err != nil {
    \t\treturn "", offset, err
    \t}
    \ts := string(data[offset : offset+l])
    \treturn s, offset + l, nil
    }

    func decodeString32Window(data []byte, offset, windowEnd int) (string, int, error) {
    \tif err := decodeRequireWindow(windowEnd, offset+4, "string32 header"); err != nil {
    \t\treturn "", offset, err
    \t}
    \tl := int(decodeU32(data, offset))
    \toffset += 4
    \tif err := decodeRequireWindow(windowEnd, offset+l, "string32 body"); err != nil {
    \t\treturn "", offset, err
    \t}
    \ts := string(data[offset : offset+l])
    \treturn s, offset + l, nil
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
    """
  end

  @spec go_decode_structure(structure(), %{String.t() => structure()}) :: iodata()
  defp go_decode_structure(structure, smap) do
    struct_name = go_struct_name(structure["name"])
    go_record_decoder("Decode#{struct_name}", struct_name, structure, smap)
  end

  # Emit a Go decode function for any record (structure, inline section, or
  # command_fields). Every read bounds against `windowEnd` (sectionStart +
  # sectionLen). Callers without a real section window (structures, command_fields)
  # pass `len(data)`, so their bound is unchanged. Trailing fields marked
  # `optional = true` are read only when the window has room; otherwise they keep
  # their Go zero value and the tail stops.
  @spec go_record_decoder(String.t(), String.t(), map(), %{String.t() => structure()}) :: iodata()
  defp go_record_decoder(fn_name, struct_name, entry, smap) do
    zero = "#{struct_name}{}"
    fields = entry["fields"] || []
    {required, optional} = Enum.split_with(fields, &(not field_optional?(&1)))

    optional_decls =
      Enum.map(optional, fn field ->
        "\tvar #{go_local_name(field["name"])} #{go_type(field, smap)}\n"
      end)

    [
      "func #{fn_name}(data []byte, offset int, windowEnd int) (#{struct_name}, int, error) {\n",
      "\tpos := offset\n",
      Enum.map(required, &go_decode_field_statement(&1, smap, zero)),
      optional_decls,
      go_optional_cascade(optional, smap, "\t"),
      go_decode_conditional_tail_block(entry, smap, zero),
      "\treturn #{struct_name}{\n",
      Enum.map(entry_fields(entry), fn field ->
        "\t\t#{go_field_name(field["name"])}: #{go_local_name(field["name"])},\n"
      end),
      "\t}, pos, nil\n",
      "}\n\n"
    ]
  end

  # Optional trailing fields decode in order as a nested if-cascade: each field is
  # read only when the window has room, and a missing field stops the tail so it
  # and every field after it keep their pre-declared zero value. A string body
  # that would exceed the window also stops the tail (the field stays empty),
  # mirroring the hand-written `if psLen >= 10 { read title; if psLen >= 12+tLen {
  # read marked_count } }` ladder. Subsequent fields are emitted inside the
  # deepest success branch so they run only when this field fully decoded.
  @spec go_optional_cascade([map()], %{String.t() => structure()}, String.t()) :: iodata()
  defp go_optional_cascade([], _smap, _indent), do: []

  defp go_optional_cascade([%{"type" => str} = field | rest], smap, indent)
       when str in ["string8", "string16", "string32"] do
    local = go_local_name(field["name"])
    {count_read, count_size} = go_string_count_read(str)
    inner = indent <> "\t"
    inner2 = inner <> "\t"

    [
      "#{indent}if pos+#{count_size} <= windowEnd {\n",
      "#{inner}#{local}Len := int(#{count_read})\n",
      "#{inner}if pos+#{count_size}+#{local}Len <= windowEnd {\n",
      "#{inner2}#{local} = string(data[pos+#{count_size} : pos+#{count_size}+#{local}Len])\n",
      "#{inner2}pos += #{count_size} + #{local}Len\n",
      go_optional_cascade(rest, smap, inner2),
      "#{inner}}\n",
      "#{indent}}\n"
    ]
  end

  defp go_optional_cascade([%{"type" => "enum", "repr" => repr} = field | rest], smap, indent) do
    local = go_local_name(field["name"])
    size = @primitive_sizes[repr]
    inner = indent <> "\t"

    [
      "#{indent}if pos+#{size} <= windowEnd {\n",
      "#{inner}#{local} = #{go_struct_name(field["enum"])}(#{@go_primitive_reads[repr]})\n",
      go_pos_advance(size, inner),
      go_optional_cascade(rest, smap, inner),
      "#{indent}}\n"
    ]
  end

  defp go_optional_cascade([%{"type" => type} = field | rest], smap, indent)
       when is_map_key(@go_primitive_reads, type) do
    local = go_local_name(field["name"])
    size = @primitive_sizes[type]
    inner = indent <> "\t"

    [
      "#{indent}if pos+#{size} <= windowEnd {\n",
      "#{inner}#{local} = #{@go_primitive_reads[type]}\n",
      go_pos_advance(size, inner),
      go_optional_cascade(rest, smap, inner),
      "#{indent}}\n"
    ]
  end

  @spec go_string_count_read(String.t()) :: {String.t(), non_neg_integer()}
  defp go_string_count_read("string8"), do: {"data[pos]", 1}
  defp go_string_count_read("string16"), do: {"decodeU16(data, pos)", 2}
  defp go_string_count_read("string32"), do: {"decodeU32(data, pos)", 4}

  @spec go_decode_field_statement(map(), %{String.t() => structure()}, String.t()) :: iodata()
  defp go_decode_field_statement(
         %{"name" => name, "type" => "enum", "enum" => enum_name, "repr" => repr},
         _smap,
         zero
       ) do
    local = go_local_name(name)
    size = @primitive_sizes[repr]

    [
      "\tif err := decodeRequireWindow(windowEnd, pos+#{size}, \"#{name}\"); err != nil {\n",
      "\t\treturn #{zero}, offset, err\n",
      "\t}\n",
      "\t#{local} := #{go_struct_name(enum_name)}(#{@go_primitive_reads[repr]})\n",
      go_pos_advance(size, "\t")
    ]
  end

  defp go_decode_field_statement(%{"name" => name, "type" => type}, _smap, zero)
       when is_map_key(@go_primitive_reads, type) do
    local = go_local_name(name)
    size = @primitive_sizes[type]

    [
      "\tif err := decodeRequireWindow(windowEnd, pos+#{size}, \"#{name}\"); err != nil {\n",
      "\t\treturn #{zero}, offset, err\n",
      "\t}\n",
      "\t#{local} := #{@go_primitive_reads[type]}\n",
      go_pos_advance(size, "\t")
    ]
  end

  defp go_decode_field_statement(%{"name" => name, "type" => str}, _smap, zero)
       when is_map_key(@go_string_window_decoders, str) do
    local = go_local_name(name)

    [
      "\t#{local}, pos, err := #{@go_string_window_decoders[str]}(data, pos, windowEnd)\n",
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
      "\t#{local}, pos, err := Decode#{go_struct_name(element)}(data, pos, windowEnd)\n",
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

    stride_check =
      case element_fixed_byte_size(element, smap) do
        nil ->
          []

        stride ->
          [
            "\tif err := decodeRequireWindow(windowEnd, pos+#{local}Count*#{stride}, \"#{name}\"); err != nil {\n",
            "\t\treturn #{zero}, offset, err\n",
            "\t}\n"
          ]
      end

    [
      "\tif err := decodeRequireWindow(windowEnd, pos+#{count_size}, \"#{name} count\"); err != nil {\n",
      "\t\treturn #{zero}, offset, err\n",
      "\t}\n",
      "\t#{local}Count := int(#{count_read})\n",
      "\tpos += #{count_size}\n",
      stride_check,
      "\t#{local} := make([]#{go_type(element_field(element), smap)}, 0, #{go_prealloc("#{local}Count", element, smap)})\n",
      "\tfor i := 0; i < #{local}Count; i++ {\n",
      go_decode_array_element(element, local, "\t\t", zero),
      "\t}\n"
    ]
  end

  # Decode one counted_array element at `pos`, append it onto `vec`, advance
  # `pos`. Reads bound against `windowEnd`: struct elements thread it down, string
  # elements use the window-aware reader, primitives are stride-checked by the
  # caller's window guard.
  @spec go_decode_array_element(String.t(), String.t(), String.t(), String.t()) :: iodata()
  defp go_decode_array_element(element, vec, indent, zero) do
    case element_field(element) do
      %{"type" => "struct", "element" => el} ->
        go_decode_array_element_via(
          "Decode#{go_struct_name(el)}(data, pos, windowEnd)",
          vec,
          indent,
          zero
        )

      %{"type" => str} when is_map_key(@go_string_window_decoders, str) ->
        go_decode_array_element_via(
          "#{@go_string_window_decoders[str]}(data, pos, windowEnd)",
          vec,
          indent,
          zero
        )

      %{"type" => prim} ->
        [
          "#{indent}#{vec} = append(#{vec}, #{@go_primitive_reads[prim]})\n",
          "#{indent}pos += #{@primitive_sizes[prim]}\n"
        ]
    end
  end

  @spec go_decode_array_element_via(String.t(), String.t(), String.t(), String.t()) :: iodata()
  defp go_decode_array_element_via(call, vec, indent, zero) do
    [
      "#{indent}item, nextPos, err := #{call}\n",
      "#{indent}if err != nil {\n",
      "#{indent}\treturn #{zero}, offset, err\n",
      "#{indent}}\n",
      "#{indent}pos = nextPos\n",
      "#{indent}#{vec} = append(#{vec}, item)\n"
    ]
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
    fn_name = "Decode#{go_struct_name(section["opcode"])}#{go_struct_name(section["name"])}"
    go_record_decoder(fn_name, go_section_struct_name(section), section, smap)
  end

  @spec go_decode_counted_array_section(String.t(), section(), %{String.t() => structure()}) ::
          iodata()
  defp go_decode_counted_array_section(_opcode, section, smap) do
    element = section["element"]
    element_type = go_type(element_field(element), smap)
    fn_name = "Decode#{go_struct_name(section["opcode"])}#{go_struct_name(section["name"])}"
    count_type = section["count_type"] || "u16"
    {count_read, count_size} = go_count_read(count_type)

    stride_check =
      case element_fixed_byte_size(element, smap) do
        nil ->
          []

        stride ->
          [
            "\tif err := decodeRequireWindow(windowEnd, pos+count*#{stride}, \"#{section["name"]}\"); err != nil {\n",
            "\t\treturn nil, offset, err\n",
            "\t}\n"
          ]
      end

    [
      "func #{fn_name}(data []byte, offset int, windowEnd int) ([]#{element_type}, int, error) {\n",
      "\tpos := offset\n",
      "\tif err := decodeRequireWindow(windowEnd, pos+#{count_size}, \"#{section["name"]} count\"); err != nil {\n",
      "\t\treturn nil, offset, err\n",
      "\t}\n",
      "\tcount := int(#{count_read})\n",
      "\tpos += #{count_size}\n",
      stride_check,
      "\titems := make([]#{element_type}, 0, #{go_prealloc("count", element, smap)})\n",
      "\tfor i := 0; i < count; i++ {\n",
      go_decode_array_element(element, "items", "\t\t", "nil"),
      "\t}\n",
      "\treturn items, pos, nil\n",
      "}\n\n"
    ]
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

      [
        "// Command field decoder for #{cf["opcode"]}\n\n",
        go_record_decoder("Decode#{struct_name}", struct_name, cf, smap)
      ]
    end)
  end

  # ── Elixir: golden_fields.ex (golden fixture field metadata) ─────────────
  #
  # Emits a schema-derived description of every golden unit's field layout so the
  # Elixir golden-fixture builder can construct expected maps keyed by the exact
  # Go struct field names the generated decoders produce, without hand-mapping
  # snake_case to Go's PascalCase. Each field entry is
  # `{schema_name, go_name, shape}` where shape is one of:
  #   :scalar | :string
  #   {:struct, [field_entry]}            (nested fixed/section struct)
  #   {:array, element_shape}             (counted_array; element_shape is
  #                                        :scalar | :string | {:struct, [...]})
  # Counted-array elements that are bare wire types use :scalar/:string; struct
  # elements expand recursively. This is metadata only; the generated Go decoder
  # and the expected JSON are the two sides the golden test compares.

  @spec golden_fields_elixir_file(schema()) :: String.t()
  defp golden_fields_elixir_file(schema) do
    smap = structures_map(schema)
    units = golden_field_units(schema, smap)

    [
      "defmodule Minga.Protocol.GoldenFields do\n",
      "  @moduledoc \"\"\"\n",
      "  Generated golden-fixture field metadata.\n\n",
      "  Generated from `docs/protocol_schema.toml` by `mix protocol.gen`. Do not edit by hand.\n",
      "  \"\"\"\n\n",
      "  @units %{\n",
      Enum.map_join(units, "", fn {name, fields} ->
        "    #{inspect(name)} => #{golden_fields_inspect(fields)},\n"
      end),
      "  }\n\n",
      "  @doc \"Ordered `{schema_name, go_name, shape}` field list for a golden decoder unit.\"\n",
      "  @spec fields(String.t()) :: [tuple()] | nil\n",
      "  def fields(unit), do: Map.get(@units, unit)\n\n",
      "  @doc \"All golden decoder unit names.\"\n",
      "  @spec units() :: [String.t()]\n",
      "  def units, do: Map.keys(@units)\n",
      "end\n"
    ]
    |> IO.iodata_to_binary()
  end

  @spec golden_field_units(schema(), %{String.t() => structure()}) :: [{String.t(), [tuple()]}]
  defp golden_field_units(schema, smap) do
    section_units =
      schema
      |> sections_list()
      |> Enum.reject(&entry_custom_layout?/1)
      |> Enum.map(fn s ->
        name = "#{go_struct_name(s["opcode"])}#{go_struct_name(s["name"])}"
        {name, golden_unit_fields(s, smap)}
      end)

    command_field_units =
      schema
      |> command_fields_list()
      |> Enum.map(fn cf ->
        name = go_struct_name(cf["opcode"]) <> "Fields"
        {name, golden_unit_fields(cf, smap)}
      end)

    Enum.sort_by(section_units ++ command_field_units, fn {name, _} -> name end)
  end

  # A counted_array section (e.g. gui_picker.items) decodes to a bare slice, so
  # its "fields" are the single element's shape under the schema name "items".
  @spec golden_unit_fields(map(), %{String.t() => structure()}) :: [tuple()]
  defp golden_unit_fields(%{"layout" => "counted_array", "element" => element} = entry, smap) do
    [{entry["name"], go_field_name(entry["name"]), {:array, golden_element_shape(element, smap)}}]
  end

  defp golden_unit_fields(entry, smap) do
    Enum.map(entry_fields(entry), &golden_field_entry(&1, smap))
  end

  @spec golden_field_entry(map(), %{String.t() => structure()}) :: tuple()
  defp golden_field_entry(%{"name" => name} = field, smap) do
    {name, go_field_name(name), golden_field_shape(field, smap)}
  end

  @spec golden_field_shape(map(), %{String.t() => structure()}) :: term()
  defp golden_field_shape(%{"type" => type}, _smap)
       when type in ["string8", "string16", "string32"],
       do: :string

  defp golden_field_shape(%{"type" => "struct", "element" => element}, smap) do
    {:struct, golden_struct_fields(element, smap)}
  end

  defp golden_field_shape(%{"type" => "counted_array", "element" => element}, smap) do
    {:array, golden_element_shape(element, smap)}
  end

  defp golden_field_shape(_field, _smap), do: :scalar

  @spec golden_element_shape(String.t(), %{String.t() => structure()}) :: term()
  defp golden_element_shape(element, _smap) when element in ["string8", "string16", "string32"],
    do: :string

  defp golden_element_shape(element, _smap) when element in @element_wire_types, do: :scalar

  defp golden_element_shape(element, smap), do: {:struct, golden_struct_fields(element, smap)}

  @spec golden_struct_fields(String.t(), %{String.t() => structure()}) :: [tuple()]
  defp golden_struct_fields(element, smap) do
    case Map.get(smap, element) do
      nil -> []
      structure -> Enum.map(entry_fields(structure), &golden_field_entry(&1, smap))
    end
  end

  @spec golden_fields_inspect([tuple()]) :: String.t()
  defp golden_fields_inspect(fields), do: inspect(fields, limit: :infinity)

  # ── Go: golden_decode.go (cross-language golden test dispatcher) ──────────
  #
  # Emits a single `GoldenDecode(name, payload)` entry point that maps a golden
  # fixture's decoder name to the matching generated decoder and returns the
  # decoded value as `any`. The cross-language golden test (golden_cross_lang_test.go)
  # marshals that value to JSON and compares it to the expected JSON produced by
  # the Elixir fixture builder, so encoder/decoder field drift fails CI. The set
  # of dispatchable units is exactly the on-wire payload units a frontend decodes:
  # non-custom sections and command_fields entries. Custom-layout sections own
  # their framing and are excluded.

  @type golden_unit :: %{name: String.t(), fn: String.t()}

  @spec golden_units(schema()) :: [golden_unit()]
  defp golden_units(schema) do
    section_units =
      schema
      |> sections_list()
      |> Enum.reject(&entry_custom_layout?/1)
      |> Enum.map(fn s ->
        %{
          name: "#{go_struct_name(s["opcode"])}#{go_struct_name(s["name"])}",
          fn: "Decode#{go_struct_name(s["opcode"])}#{go_struct_name(s["name"])}"
        }
      end)

    command_field_units =
      schema
      |> command_fields_list()
      |> Enum.map(fn cf ->
        struct_name = go_struct_name(cf["opcode"]) <> "Fields"
        %{name: struct_name, fn: "Decode#{struct_name}"}
      end)

    Enum.sort_by(section_units ++ command_field_units, & &1.name)
  end

  @spec go_golden_decode_file(schema(), boolean()) :: String.t()
  defp go_golden_decode_file(schema, format_generated_go) do
    units = golden_units(schema)

    [
      "// Code generated by mix protocol.gen. DO NOT EDIT.\n\n",
      "package generated\n\n",
      "import \"fmt\"\n\n",
      "// GoldenDecode dispatches a cross-language golden fixture's decoder name to\n",
      "// the matching generated decoder and returns the decoded value. The golden\n",
      "// test marshals the result to JSON and compares it field-by-field against the\n",
      "// expected JSON the Elixir fixture builder produced from the same model.\n",
      "func GoldenDecode(name string, payload []byte) (any, int, error) {\n",
      "\tswitch name {\n",
      Enum.map(units, fn %{name: name, fn: fn_name} ->
        [
          "\tcase \"#{name}\":\n",
          "\t\tv, n, err := #{fn_name}(payload, 0, len(payload))\n",
          "\t\treturn v, n, err\n"
        ]
      end),
      "\tdefault:\n",
      "\t\treturn nil, 0, fmt.Errorf(\"unknown golden decoder %q\", name)\n",
      "\t}\n",
      "}\n"
    ]
    |> IO.iodata_to_binary()
    |> maybe_format_generated_go_file(format_generated_go)
  end

  # ── Swift: ProtocolSemanticDecode.generated.swift ────────────────────────
  #
  # Mirrors the Go semantic decoders (semantic_types.go + semantic_decode.go) for
  # the Swift frontend. Every generated record decoder is the structural twin of
  # its Go counterpart: same field order, same length guards, same big-endian
  # reads, same conditional-tail guard, same counted_array prealloc clamp. The two
  # languages therefore decode byte-identical wire payloads to the same field
  # values, which the swift_harness integration tests prove against the Elixir
  # encoder output.
  #
  # Everything is namespaced under the `GeneratedProtocol` caseless enum so the
  # generated struct/enum types (CompletionItem, GuiCompletionFields, …) never
  # collide with the hand-written `Wire` types or the production decoder's private
  # read helpers. The production decoder swaps a hand-written body for a call to
  # `GeneratedProtocol.decodeGui<Opcode>Fields(_:_:)` and maps the result into the
  # existing `RenderCommand` case, keeping the public decode surface unchanged.
  #
  # Enum representation: each schema enum becomes a Swift `enum Name: <repr>` whose
  # `decode(_:)` maps an unknown byte to the schema `default` value, exactly as the
  # Go side maps `byte -> typed constant`. The raw value round-trips to the same
  # integer the hand-written `UInt8` field carried, so the harness JSON projection
  # (`Int(item.kind)`) is unchanged.

  @swift_primitive_decode_types %{
    "u8" => "UInt8",
    "u16" => "UInt16",
    "u24" => "UInt32",
    "u32" => "UInt32",
    "u64" => "UInt64",
    "rgb" => "UInt32"
  }

  @swift_primitive_reads %{
    "u8" => "data[pos]",
    "u16" => "decodeU16(data, pos)",
    "u24" => "decodeU24(data, pos)",
    "rgb" => "decodeU24(data, pos)",
    "u32" => "decodeU32(data, pos)",
    "u64" => "decodeU64(data, pos)"
  }

  # Window-bounded Swift string readers, mirroring @go_string_window_decoders.
  @swift_string_window_decoders %{
    "string8" => "decodeString8Window",
    "string16" => "decodeString16Window",
    "string32" => "decodeString32Window"
  }

  @spec swift_semantic_decode_file(schema()) :: String.t()
  defp swift_semantic_decode_file(schema) do
    structures = Map.get(schema, "structures", [])
    sections = sections_list(schema)
    command_fields = command_fields_list(schema)
    smap = structures_map(schema)

    # Default-case lookup for enum zero values in conditional tails, captured here
    # so swift_zero_value/2 stays a pure name lookup without threading the enums
    # map through every type helper.
    enum_defaults =
      Map.new(enums_list(schema), fn enum ->
        {enum["name"], swift_enum_default_case(enum)}
      end)

    Process.put(:swift_enum_defaults, enum_defaults)

    try do
      swift_semantic_decode_iodata(structures, sections, command_fields, smap, enums_list(schema))
    after
      Process.delete(:swift_enum_defaults)
    end
  end

  @spec swift_semantic_decode_iodata([map()], [section()], [command_fields()], map(), [enum()]) ::
          String.t()
  defp swift_semantic_decode_iodata(structures, sections, command_fields, smap, enums) do
    [
      "// Generated protocol payload decoders.\n",
      "//\n",
      "// Generated from `docs/protocol_schema.toml` by `mix protocol.gen`. Do not edit by hand.\n",
      "//\n",
      "// Structural twin of the Go semantic decoders. The production ProtocolDecoder\n",
      "// calls these and maps the result into its `RenderCommand` cases.\n\n",
      "import Foundation\n",
      "import MingaProtocol\n\n",
      "/// Namespace for schema-generated payload decoders, enum types, and struct types.\n",
      "enum GeneratedProtocol {\n\n",
      swift_decode_error(),
      swift_decode_helpers(),
      swift_enum_definitions(enums),
      swift_struct_definitions(structures, smap),
      swift_section_struct_definitions(sections, smap),
      swift_command_fields_struct_definitions(command_fields, smap),
      "\n    // MARK: - Structure decoders\n\n",
      Enum.map(structures, &swift_decode_structure(&1, smap)),
      "    // MARK: - Section decoders\n\n",
      swift_decode_section_functions(sections, smap),
      "    // MARK: - Command field decoders\n\n",
      swift_decode_command_fields_functions(command_fields, smap),
      "}\n"
    ]
    |> IO.iodata_to_binary()
  end

  @spec swift_decode_error() :: String.t()
  defp swift_decode_error do
    """
        /// Raised when a payload is shorter than a field requires.
        enum DecodeError: Error, Equatable {
            case short(String)
        }

    """
  end

  @spec swift_decode_helpers() :: String.t()
  defp swift_decode_helpers do
    """
        // requireWindow bounds a section read against the section window end
        // (sectionStart + sectionLen) so a section decoder never reads past its
        // own section even when the buffer carries more bytes.
        @inline(__always)
        static func requireWindow(_ windowEnd: Int, _ needed: Int, _ label: String) throws {
            if needed > windowEnd { throw DecodeError.short(label) }
        }

        @inline(__always)
        static func decodeU16(_ data: Data, _ offset: Int) -> UInt16 {
            UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
        }

        @inline(__always)
        static func decodeU24(_ data: Data, _ offset: Int) -> UInt32 {
            UInt32(data[offset]) << 16 | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2])
        }

        @inline(__always)
        static func decodeU32(_ data: Data, _ offset: Int) -> UInt32 {
            UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16
                | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
        }

        @inline(__always)
        static func decodeU64(_ data: Data, _ offset: Int) -> UInt64 {
            let hi = UInt64(data[offset]) << 56 | UInt64(data[offset + 1]) << 48
                | UInt64(data[offset + 2]) << 40 | UInt64(data[offset + 3]) << 32
            let lo = UInt64(data[offset + 4]) << 24 | UInt64(data[offset + 5]) << 16
                | UInt64(data[offset + 6]) << 8 | UInt64(data[offset + 7])
            return hi | lo
        }

        // Window-bounded string readers: bound both the length header and the
        // body against the section window end so a section decoder never reads
        // past its own section.
        static func decodeString8Window(_ data: Data, _ offset: Int, _ windowEnd: Int) throws -> (String, Int) {
            try requireWindow(windowEnd, offset + 1, "string8 header")
            let l = Int(data[offset])
            let body = offset + 1
            try requireWindow(windowEnd, body + l, "string8 body")
            try FrameDecodeAccounting.reserve(.ownedUTF8Bytes, l)
            let s = String(data: data[body..<(body + l)], encoding: .utf8) ?? ""
            return (s, body + l)
        }

        static func decodeString16Window(_ data: Data, _ offset: Int, _ windowEnd: Int) throws -> (String, Int) {
            try requireWindow(windowEnd, offset + 2, "string16 header")
            let l = Int(decodeU16(data, offset))
            let body = offset + 2
            try requireWindow(windowEnd, body + l, "string16 body")
            try FrameDecodeAccounting.reserve(.ownedUTF8Bytes, l)
            let s = String(data: data[body..<(body + l)], encoding: .utf8) ?? ""
            return (s, body + l)
        }

        static func decodeString32Window(_ data: Data, _ offset: Int, _ windowEnd: Int) throws -> (String, Int) {
            try requireWindow(windowEnd, offset + 4, "string32 header")
            let l = Int(decodeU32(data, offset))
            let body = offset + 4
            try requireWindow(windowEnd, body + l, "string32 body")
            try FrameDecodeAccounting.reserve(.ownedUTF8Bytes, l)
            let s = String(data: data[body..<(body + l)], encoding: .utf8) ?? ""
            return (s, body + l)
        }

    """
  end

  # Emit one Swift enum per schema enum plus a `decode(_:)` that maps an unknown
  # byte to the schema `default` value, mirroring Go's byte -> typed constant
  # mapping. The raw value is the repr primitive so `.rawValue` round-trips to the
  # same integer the hand-written UInt8 field carried.
  @spec swift_enum_definitions([enum()]) :: iodata()
  defp swift_enum_definitions([]), do: []

  defp swift_enum_definitions(enums) do
    [
      "    // MARK: - Enum types\n\n",
      Enum.map(enums, fn enum ->
        type_name = swift_struct_name(enum["name"])
        repr_type = @swift_primitive_decode_types[enum["repr"]]
        values = Map.get(enum, "values", [])
        default_case = swift_enum_default_case(enum)

        [
          "    enum #{type_name}: #{repr_type}, Equatable {\n",
          Enum.map(values, fn v ->
            "        case #{swift_enum_case_name(v["name"])} = #{v["value"]}\n"
          end),
          "\n",
          "        static func decode(_ raw: #{repr_type}) -> #{type_name} {\n",
          "            #{type_name}(rawValue: raw) ?? .#{default_case}\n",
          "        }\n",
          "    }\n\n"
        ]
      end)
    ]
  end

  @spec swift_enum_default_case(enum()) :: String.t()
  defp swift_enum_default_case(%{"default" => default}) when is_binary(default),
    do: swift_enum_case_name(default)

  defp swift_enum_default_case(enum) do
    enum |> Map.get("values", []) |> List.first() |> Map.fetch!("name") |> swift_enum_case_name()
  end

  @spec swift_struct_definitions([structure()], %{String.t() => structure()}) :: iodata()
  defp swift_struct_definitions(structures, smap) do
    [
      "    // MARK: - Structure types\n\n",
      Enum.map(structures, fn s ->
        swift_struct_block(swift_struct_name(s["name"]), entry_fields(s), smap)
      end)
    ]
  end

  @spec swift_section_struct_definitions([section()], %{String.t() => structure()}) :: iodata()
  defp swift_section_struct_definitions(sections, smap) do
    blocks =
      sections
      |> Enum.reject(&entry_custom_layout?/1)
      |> Enum.filter(&(Map.has_key?(&1, "fields") or Map.has_key?(&1, "conditional_tail")))
      |> Enum.map(fn s ->
        swift_struct_block(swift_section_struct_name(s), entry_fields(s), smap)
      end)

    case blocks do
      [] -> []
      _ -> ["    // MARK: - Section types\n\n", blocks]
    end
  end

  @spec swift_command_fields_struct_definitions([command_fields()], %{String.t() => structure()}) ::
          iodata()
  defp swift_command_fields_struct_definitions([], _smap), do: []

  defp swift_command_fields_struct_definitions(command_fields, smap) do
    [
      "    // MARK: - Command field types\n\n",
      Enum.map(command_fields, fn cf ->
        swift_struct_block(swift_struct_name(cf["opcode"]) <> "Fields", entry_fields(cf), smap)
      end)
    ]
  end

  @spec swift_struct_block(String.t(), [map()], %{String.t() => structure()}) :: iodata()
  defp swift_struct_block(name, fields, smap) do
    [
      "    struct #{name}: Equatable {\n",
      Enum.map(fields, fn field ->
        "        let #{swift_field_name(field["name"])}: #{swift_type(field, smap)}\n"
      end),
      "    }\n\n"
    ]
  end

  @spec swift_decode_structure(structure(), %{String.t() => structure()}) :: iodata()
  defp swift_decode_structure(structure, smap) do
    struct_name = swift_struct_name(structure["name"])
    swift_record_decoder("decode#{struct_name}", struct_name, structure, smap)
  end

  # Emit a Swift decode function for any record (structure, inline section, or
  # command_fields). Mirrors go_record_decoder: take an explicit window end, bound
  # every read against it, decode required fields, then the optional-suffix
  # cascade and the conditional tail, then build the struct. Callers without a
  # real section window pass `data.count`, so their bound is unchanged.
  @spec swift_record_decoder(String.t(), String.t(), map(), %{String.t() => structure()}) ::
          iodata()
  defp swift_record_decoder(fn_name, struct_name, entry, smap) do
    fields = entry["fields"] || []
    {required, optional} = Enum.split_with(fields, &(not field_optional?(&1)))

    optional_decls =
      Enum.map(optional, fn field ->
        "        var #{swift_local_name(field["name"])}: #{swift_type(field, smap)} = #{swift_zero_value(field, smap)}\n"
      end)

    [
      "    static func #{fn_name}(_ data: Data, _ offset: Int, _ windowEnd: Int) throws -> (#{struct_name}, Int) {\n",
      "        var pos = offset\n",
      Enum.map(required, &swift_decode_field_statement(&1, smap)),
      optional_decls,
      swift_optional_cascade(optional, smap, "        "),
      swift_decode_conditional_tail_block(entry, smap),
      "        return (#{struct_name}(\n",
      swift_struct_initializer_args(entry_fields(entry)),
      "        ), pos)\n",
      "    }\n\n"
    ]
  end

  # Mirror of go_optional_cascade: nested if-room blocks that read each optional
  # field only when the window has space, stopping the tail on the first absent
  # field (its and later fields keep their pre-declared zero value). A string body
  # that would exceed the window also stops the tail.
  @spec swift_optional_cascade([map()], %{String.t() => structure()}, String.t()) :: iodata()
  defp swift_optional_cascade([], _smap, _indent), do: []

  defp swift_optional_cascade([%{"type" => str} = field | rest], smap, indent)
       when str in ["string8", "string16", "string32"] do
    local = swift_local_name(field["name"])
    {count_read, count_size} = swift_string_count_read(str)
    inner = indent <> "    "
    inner2 = inner <> "    "

    [
      "#{indent}if pos + #{count_size} <= windowEnd {\n",
      "#{inner}let #{local}Len = Int(#{count_read})\n",
      "#{inner}if pos + #{count_size} + #{local}Len <= windowEnd {\n",
      "#{inner2}#{local} = String(data: data[(pos + #{count_size})..<(pos + #{count_size} + #{local}Len)], encoding: .utf8) ?? \"\"\n",
      "#{inner2}pos += #{count_size} + #{local}Len\n",
      swift_optional_cascade(rest, smap, inner2),
      "#{inner}}\n",
      "#{indent}}\n"
    ]
  end

  defp swift_optional_cascade([%{"type" => "enum", "repr" => repr} = field | rest], smap, indent) do
    local = swift_local_name(field["name"])
    size = @primitive_sizes[repr]
    inner = indent <> "    "

    [
      "#{indent}if pos + #{size} <= windowEnd {\n",
      "#{inner}#{local} = #{swift_struct_name(field["enum"])}.decode(#{@swift_primitive_reads[repr]})\n",
      "#{inner}pos += #{size}\n",
      swift_optional_cascade(rest, smap, inner),
      "#{indent}}\n"
    ]
  end

  defp swift_optional_cascade([%{"type" => type} = field | rest], smap, indent)
       when is_map_key(@swift_primitive_reads, type) do
    local = swift_local_name(field["name"])
    size = @primitive_sizes[type]
    inner = indent <> "    "

    [
      "#{indent}if pos + #{size} <= windowEnd {\n",
      "#{inner}#{local} = #{@swift_primitive_reads[type]}\n",
      "#{inner}pos += #{size}\n",
      swift_optional_cascade(rest, smap, inner),
      "#{indent}}\n"
    ]
  end

  @spec swift_string_count_read(String.t()) :: {String.t(), non_neg_integer()}
  defp swift_string_count_read("string8"), do: {"data[pos]", 1}
  defp swift_string_count_read("string16"), do: {"decodeU16(data, pos)", 2}
  defp swift_string_count_read("string32"), do: {"decodeU32(data, pos)", 4}

  @spec swift_struct_initializer_args([map()]) :: iodata()
  defp swift_struct_initializer_args(fields) do
    last = Enum.count(fields) - 1

    fields
    |> Enum.with_index()
    |> Enum.map(fn {field, idx} ->
      name = swift_field_name(field["name"])
      comma = if idx == last, do: "", else: ","
      "            #{name}: #{swift_local_name(field["name"])}#{comma}\n"
    end)
  end

  # A field declared with `let` in the base scope; the conditional tail instead
  # pre-declares `var` locals and assigns them inside the guard, so they default
  # to a zero value when the tail is absent (mirroring Go's `var x T` zero value).
  @spec swift_decode_field_statement(map(), %{String.t() => structure()}) :: iodata()
  defp swift_decode_field_statement(field, smap),
    do: swift_decode_field(field, smap, :let, "        ")

  @spec swift_decode_conditional_tail_block(map(), %{String.t() => structure()}) :: iodata()
  defp swift_decode_conditional_tail_block(entry, smap) do
    case conditional_tail_fields(entry) do
      [] ->
        []

      tail_fields ->
        [
          Enum.map(tail_fields, fn field ->
            "        var #{swift_local_name(field["name"])}: #{swift_type(field, smap)} = #{swift_zero_value(field, smap)}\n"
          end),
          "        if #{swift_guard_expression(entry)} {\n",
          Enum.map(tail_fields, fn field ->
            swift_decode_field(field, smap, :assign, "            ")
          end),
          "        }\n"
        ]
    end
  end

  # Decode one field at `pos`, bind/assign it to its local, advance `pos`. `mode`
  # is `:let` for base fields (fresh binding) or `:assign` for conditional-tail
  # fields (pre-declared `var`). Mirrors go_decode_field_statement /
  # go_decode_field_assignment_statement.
  @spec swift_decode_field(map(), %{String.t() => structure()}, :let | :assign, String.t()) ::
          iodata()
  defp swift_decode_field(
         %{"name" => name, "type" => "enum", "enum" => enum_name, "repr" => repr},
         _smap,
         mode,
         ind
       ) do
    local = swift_local_name(name)
    size = @primitive_sizes[repr]
    bind = swift_bind_keyword(mode)

    [
      "#{ind}try requireWindow(windowEnd, pos + #{size}, \"#{name}\")\n",
      "#{ind}#{bind}#{local} = #{swift_struct_name(enum_name)}.decode(#{@swift_primitive_reads[repr]})\n",
      "#{ind}pos += #{size}\n"
    ]
  end

  defp swift_decode_field(%{"name" => name, "type" => type}, _smap, mode, ind)
       when is_map_key(@swift_primitive_reads, type) do
    local = swift_local_name(name)
    size = @primitive_sizes[type]
    bind = swift_bind_keyword(mode)

    [
      "#{ind}try requireWindow(windowEnd, pos + #{size}, \"#{name}\")\n",
      "#{ind}#{bind}#{local} = #{@swift_primitive_reads[type]}\n",
      "#{ind}pos += #{size}\n"
    ]
  end

  defp swift_decode_field(%{"name" => name, "type" => type}, _smap, mode, ind)
       when is_map_key(@swift_string_window_decoders, type) do
    local = swift_local_name(name)
    decoder = @swift_string_window_decoders[type]

    case mode do
      :let ->
        [
          "#{ind}let (#{local}, #{local}Pos) = try #{decoder}(data, pos, windowEnd)\n",
          "#{ind}pos = #{local}Pos\n"
        ]

      :assign ->
        [
          "#{ind}let (#{local}Val, #{local}Pos) = try #{decoder}(data, pos, windowEnd)\n",
          "#{ind}#{local} = #{local}Val\n",
          "#{ind}pos = #{local}Pos\n"
        ]
    end
  end

  defp swift_decode_field(
         %{"name" => name, "type" => "struct", "element" => element},
         _smap,
         mode,
         ind
       ) do
    local = swift_local_name(name)
    decoder = "decode#{swift_struct_name(element)}"

    case mode do
      :let ->
        [
          "#{ind}let (#{local}, #{local}Pos) = try #{decoder}(data, pos, windowEnd)\n",
          "#{ind}pos = #{local}Pos\n"
        ]

      :assign ->
        [
          "#{ind}let (#{local}Val, #{local}Pos) = try #{decoder}(data, pos, windowEnd)\n",
          "#{ind}#{local} = #{local}Val\n",
          "#{ind}pos = #{local}Pos\n"
        ]
    end
  end

  defp swift_decode_field(
         %{
           "name" => name,
           "type" => "counted_array",
           "count_type" => count_type,
           "element" => element
         },
         smap,
         mode,
         ind
       ) do
    local = swift_local_name(name)
    {count_read, count_size} = swift_count_read(count_type)
    bind = if mode == :let, do: "var ", else: ""

    stride_check =
      case element_fixed_byte_size(element, smap) do
        nil ->
          []

        stride ->
          ["#{ind}try requireWindow(windowEnd, pos + #{local}Count * #{stride}, \"#{name}\")\n"]
      end

    [
      "#{ind}try requireWindow(windowEnd, pos + #{count_size}, \"#{name} count\")\n",
      "#{ind}let #{local}Count = Int(#{count_read})\n",
      "#{ind}pos += #{count_size}\n",
      stride_check,
      "#{ind}try FrameDecodeAccounting.reserve(.arrayEntries, #{local}Count)\n",
      "#{ind}#{bind}#{local} = #{swift_array_type(element, smap)}()\n",
      "#{ind}#{local}.reserveCapacity(#{swift_prealloc("#{local}Count", element, smap)})\n",
      "#{ind}for _ in 0..<#{local}Count {\n",
      swift_decode_array_element(element, local, ind <> "    "),
      "#{ind}}\n"
    ]
  end

  # Decode one counted_array element at `pos`, append it onto `vec`, advance `pos`.
  # Mirrors go_decode_array_element: reads bound against `windowEnd`.
  @spec swift_decode_array_element(String.t(), String.t(), String.t()) :: iodata()
  defp swift_decode_array_element(element, vec, ind) do
    case element_field(element) do
      %{"type" => "struct", "element" => el} ->
        swift_decode_array_element_via(
          "decode#{swift_struct_name(el)}(data, pos, windowEnd)",
          vec,
          ind
        )

      %{"type" => str} when is_map_key(@swift_string_window_decoders, str) ->
        swift_decode_array_element_via(
          "#{@swift_string_window_decoders[str]}(data, pos, windowEnd)",
          vec,
          ind
        )

      %{"type" => prim} ->
        [
          "#{ind}try requireWindow(windowEnd, pos + #{@primitive_sizes[prim]}, \"element\")\n",
          "#{ind}#{vec}.append(#{@swift_primitive_reads[prim]})\n",
          "#{ind}pos += #{@primitive_sizes[prim]}\n"
        ]
    end
  end

  @spec swift_decode_array_element_via(String.t(), String.t(), String.t()) :: iodata()
  defp swift_decode_array_element_via(call, vec, ind) do
    [
      "#{ind}let (item, nextPos) = try #{call}\n",
      "#{ind}pos = nextPos\n",
      "#{ind}#{vec}.append(item)\n"
    ]
  end

  @spec swift_count_read(String.t()) :: {String.t(), non_neg_integer()}
  defp swift_count_read("u8"), do: {"data[pos]", 1}
  defp swift_count_read("u16"), do: {"decodeU16(data, pos)", 2}
  defp swift_count_read("u32"), do: {"decodeU32(data, pos)", 4}

  @spec swift_decode_section_functions([section()], %{String.t() => structure()}) :: iodata()
  defp swift_decode_section_functions(sections, smap) do
    sections
    |> Enum.group_by(& &1["opcode"])
    |> Enum.sort_by(fn {opcode, _} -> opcode end)
    |> Enum.map(fn {opcode, secs} ->
      swift_decode_opcode_sections(opcode, Enum.sort_by(secs, & &1["id"]), smap)
    end)
  end

  @spec swift_decode_opcode_sections(String.t(), [section()], %{String.t() => structure()}) ::
          iodata()
  defp swift_decode_opcode_sections(opcode, secs, smap) do
    Enum.map(secs, fn sec ->
      cond do
        entry_custom_layout?(sec) -> []
        sec["layout"] == "counted_array" -> swift_decode_counted_array_section(opcode, sec, smap)
        true -> swift_decode_inline_section(opcode, sec, smap)
      end
    end)
  end

  @spec swift_decode_inline_section(String.t(), section(), %{String.t() => structure()}) ::
          iodata()
  defp swift_decode_inline_section(_opcode, section, smap) do
    fn_name = "decode#{swift_struct_name(section["opcode"])}#{swift_struct_name(section["name"])}"
    swift_record_decoder(fn_name, swift_section_struct_name(section), section, smap)
  end

  @spec swift_decode_counted_array_section(String.t(), section(), %{String.t() => structure()}) ::
          iodata()
  defp swift_decode_counted_array_section(_opcode, section, smap) do
    element = section["element"]
    element_type = swift_type(element_field(element), smap)
    array_type = swift_array_type(element, smap)
    fn_name = "decode#{swift_struct_name(section["opcode"])}#{swift_struct_name(section["name"])}"
    count_type = section["count_type"] || "u16"
    {count_read, count_size} = swift_count_read(count_type)

    stride_check =
      case element_fixed_byte_size(element, smap) do
        nil ->
          []

        stride ->
          [
            "        try requireWindow(windowEnd, pos + count * #{stride}, \"#{section["name"]}\")\n"
          ]
      end

    [
      "    static func #{fn_name}(_ data: Data, _ offset: Int, _ windowEnd: Int) throws -> ([#{element_type}], Int) {\n",
      "        var pos = offset\n",
      "        try requireWindow(windowEnd, pos + #{count_size}, \"#{section["name"]} count\")\n",
      "        let count = Int(#{count_read})\n",
      "        pos += #{count_size}\n",
      stride_check,
      "        try FrameDecodeAccounting.reserve(.arrayEntries, count)\n",
      "        var items = #{array_type}()\n",
      "        items.reserveCapacity(#{swift_prealloc("count", element, smap)})\n",
      "        for _ in 0..<count {\n",
      swift_decode_array_element(element, "items", "            "),
      "        }\n",
      "        return (items, pos)\n",
      "    }\n\n"
    ]
  end

  @spec swift_decode_command_fields_functions([command_fields()], %{String.t() => structure()}) ::
          iodata()
  defp swift_decode_command_fields_functions(command_fields, smap) do
    Enum.map(command_fields, fn cf ->
      struct_name = swift_struct_name(cf["opcode"]) <> "Fields"
      swift_record_decoder("decode#{struct_name}", struct_name, cf, smap)
    end)
  end

  # ── Swift decode: type & name mapping ─────────────────────────────────────

  @spec swift_type(map(), %{String.t() => structure()}) :: String.t()
  defp swift_type(%{"type" => "enum", "enum" => name}, _smap), do: swift_struct_name(name)
  defp swift_type(%{"type" => "u8"}, _smap), do: "UInt8"
  defp swift_type(%{"type" => "u16"}, _smap), do: "UInt16"
  defp swift_type(%{"type" => "u24"}, _smap), do: "UInt32"
  defp swift_type(%{"type" => "u32"}, _smap), do: "UInt32"
  defp swift_type(%{"type" => "u64"}, _smap), do: "UInt64"
  defp swift_type(%{"type" => "rgb"}, _smap), do: "UInt32"
  defp swift_type(%{"type" => "string8"}, _smap), do: "String"
  defp swift_type(%{"type" => "string16"}, _smap), do: "String"
  defp swift_type(%{"type" => "string32"}, _smap), do: "String"

  defp swift_type(%{"type" => "struct", "element" => element}, _smap),
    do: swift_struct_name(element)

  defp swift_type(%{"type" => "counted_array", "element" => element}, smap),
    do: "[#{swift_type(element_field(element), smap)}]"

  @spec swift_array_type(String.t(), %{String.t() => structure()}) :: String.t()
  defp swift_array_type(element, smap), do: "[#{swift_type(element_field(element), smap)}]"

  # A zero value for a conditional-tail var declaration, mirroring Go's `var x T`.
  @spec swift_zero_value(map(), %{String.t() => structure()}) :: String.t()
  defp swift_zero_value(%{"type" => "enum", "enum" => name}, _smap),
    do: ".#{swift_enum_default_case_by_name(name)}"

  defp swift_zero_value(%{"type" => type}, _smap)
       when type in ["u8", "u16", "u24", "u32", "u64", "rgb"],
       do: "0"

  defp swift_zero_value(%{"type" => type}, _smap)
       when type in ["string8", "string16", "string32"],
       do: "\"\""

  defp swift_zero_value(%{"type" => "counted_array", "element" => element}, smap),
    do: "#{swift_array_type(element, smap)}()"

  defp swift_zero_value(%{"type" => "struct", "element" => _element}, _smap),
    do: "nil"

  # Resolve an enum's default case name from a field reference; the enums map is
  # captured at file build time so this stays a pure lookup by enum name.
  @spec swift_enum_default_case_by_name(String.t()) :: String.t()
  defp swift_enum_default_case_by_name(name) do
    case Process.get(:swift_enum_defaults) do
      %{} = defaults -> Map.get(defaults, name, "unknown")
      _ -> "unknown"
    end
  end

  @spec swift_bind_keyword(:let | :assign) :: String.t()
  defp swift_bind_keyword(:let), do: "let "
  defp swift_bind_keyword(:assign), do: ""

  # The conditional-tail guard with each base-field identifier rewritten to its
  # decoded Swift local, mirroring go_guard_expression. The legal guard grammar
  # (validate_conditional_tail_guards!) is the cross-language subset, so the
  # operators carry over verbatim.
  @spec swift_guard_expression(map()) :: String.t()
  defp swift_guard_expression(entry) do
    guard = conditional_tail_guard(entry) || "true"

    translate_guard(
      guard,
      Enum.map(Map.get(entry, "fields", []), fn field ->
        {field["name"], swift_local_name(field["name"])}
      end)
    )
  end

  @spec swift_prealloc(String.t(), String.t(), %{String.t() => structure()}) :: String.t()
  defp swift_prealloc(count_var, element, smap) do
    case element_fixed_byte_size(element, smap) do
      nil -> "min(#{count_var}, data.count - pos)"
      _ -> count_var
    end
  end

  @spec swift_struct_name(String.t()) :: String.t()
  defp swift_struct_name(name) do
    name
    |> String.split("_")
    |> Enum.map_join("", &String.capitalize/1)
  end

  @spec swift_section_struct_name(section()) :: String.t()
  defp swift_section_struct_name(section) do
    swift_struct_name(section["opcode"]) <> swift_struct_name(section["name"])
  end

  # Swift convention: lowerCamelCase fields. Acronyms stay uppercase only when the
  # whole word is the acronym; mirrors the Go acronym set so field intent reads the
  # same across languages.
  @spec swift_field_name(String.t()) :: String.t()
  defp swift_field_name(name), do: swift_lower_camel(name)

  @swift_reserved_locals ~w(pos offset data item nextPos count)
  @swift_keywords ~w(default case enum struct func let var if for in return guard try throw)
  @spec swift_local_name(String.t()) :: String.t()
  defp swift_local_name(name) do
    camel = swift_lower_camel(name)

    if camel in @swift_keywords or name in @swift_reserved_locals,
      do: camel <> "Value",
      else: camel
  end

  @swift_acronyms %{
    "id" => "ID",
    "fg" => "FG",
    "bg" => "BG",
    "url" => "URL",
    "ip" => "IP",
    "lsp" => "LSP"
  }

  @spec swift_lower_camel(String.t()) :: String.t()
  defp swift_lower_camel(name) do
    case String.split(name, "_") do
      [first | rest] ->
        first <>
          Enum.map_join(rest, "", fn part ->
            Map.get(@swift_acronyms, part, String.capitalize(part))
          end)

      _ ->
        name
    end
  end

  # An enum case name. Swift keywords (struct, enum, default, …) are legal case
  # names only when escaped with backticks, so they are quoted here and at every
  # `.case` reference site.
  @spec swift_enum_case_name(String.t()) :: String.t()
  defp swift_enum_case_name(name) do
    camel = swift_lower_camel(name)
    if camel in @swift_keywords, do: "`#{camel}`", else: camel
  end

  # ── Elixir: encode.ex (pure schema-derived encoders) ─────────────────────
  #
  # Emits one pure `encode_<unit>(model) :: iodata()` per wire record (structure,
  # non-custom section, command_fields) plus one `encode_<enum>(atom) :: byte`
  # clause set per enum. Each encoder is the structural inverse of the generated
  # Go decoder above: fixed primitives become big-endian bitstrings, strings a
  # length prefix + bytes, structs delegate to the element's encoder, counted
  # arrays a count prefix + mapped elements, conditional tails a guard on base
  # fields that emits the tail iodata or `[]`, and enum fields an atom -> byte
  # mapping with the schema `default` byte as the fallback (the inverse of the Go
  # byte -> typed constant mapping).
  #
  # The encoders are pure serialization only: no caching, no derivation, no
  # nil-handling. The adapter layer keeps the fingerprint/skip-if-unchanged shell
  # and the Layer 2 builders normalize the model (defaulting, derivation, clamps)
  # before calling these. Field values are read by schema name from the model
  # struct or map, matching the names the hand-written encoders consume today.

  @doc false
  @spec render_encode_module(schema(), module()) :: String.t()
  def render_encode_module(schema, module_name) when is_atom(module_name) do
    schema
    |> attach_enum_reprs()
    |> encode_elixir_file(module_name)
  end

  @spec encode_elixir_file(schema()) :: String.t()
  defp encode_elixir_file(schema), do: encode_elixir_file(schema, Minga.Protocol.Encode)

  @spec encode_elixir_file(schema(), module()) :: String.t()
  defp encode_elixir_file(schema, module_name) do
    smap = structures_map(schema)
    enums = enums_list(schema)
    structures = Map.get(schema, "structures", [])
    sections = sections_list(schema) |> Enum.reject(&entry_custom_layout?/1)
    command_fields = command_fields_list(schema)

    [
      "defmodule #{inspect(module_name)} do\n",
      "  @moduledoc \"\"\"\n",
      "  Generated pure protocol encoders.\n\n",
      "  Generated from `docs/protocol_schema.toml` by `mix protocol.gen`. Do not edit by hand.\n\n",
      "  Each `encode_*/1` validates schema-owned bounded fields immediately before\n",
      "  emitting them and returns the on-wire iodata for one schema record.\n",
      "  \"\"\"\n\n",
      "  alias Minga.Protocol.EncodingError\n\n",
      Enum.map(enums, &elixir_encode_enum/1),
      Enum.map(structures, fn entry ->
        elixir_record_encoder(
          encode_fn_name(entry["name"]),
          String.to_atom(entry["name"]),
          entry,
          smap
        )
      end),
      Enum.map(sections, fn entry ->
        elixir_record_encoder(
          section_encode_fn_name(entry),
          String.to_atom(entry["opcode"]),
          entry,
          smap
        )
      end),
      Enum.map(command_fields, fn entry ->
        elixir_record_encoder(
          command_fields_encode_fn_name(entry),
          String.to_atom(entry["opcode"]),
          entry,
          smap
        )
      end),
      elixir_validation_helpers(),
      "end\n"
    ]
    |> IO.iodata_to_binary()
  end

  @spec encode_fn_name(String.t()) :: String.t()
  defp encode_fn_name(name), do: "encode_#{name}"

  @spec section_encode_fn_name(section()) :: String.t()
  defp section_encode_fn_name(section) do
    "encode_#{section["opcode"]}_#{section["name"]}"
  end

  @spec command_fields_encode_fn_name(command_fields()) :: String.t()
  defp command_fields_encode_fn_name(cf), do: "encode_#{cf["opcode"]}"

  @spec elixir_encode_enum(enum()) :: iodata()
  defp elixir_encode_enum(%{"name" => name} = enum) do
    values = Map.get(enum, "values", [])
    default_byte = enum_default_byte(enum)
    fn_name = "encode_#{name}"

    [
      "  @spec #{fn_name}(atom()) :: non_neg_integer()\n",
      Enum.map(values, fn value ->
        "  def #{fn_name}(:#{value["name"]}), do: #{value["value"]}\n"
      end),
      "  def #{fn_name}(_), do: #{default_byte}\n\n"
    ]
  end

  @spec enum_default_byte(enum()) :: non_neg_integer()
  defp enum_default_byte(%{"default" => default} = enum) when is_binary(default) do
    enum
    |> Map.get("values", [])
    |> Enum.find(fn value -> value["name"] == default end)
    |> Map.fetch!("value")
  end

  defp enum_default_byte(_enum), do: 0

  @spec elixir_record_encoder(String.t(), atom(), map(), %{String.t() => structure()}) ::
          iodata()
  defp elixir_record_encoder(
         fn_name,
         command,
         %{"layout" => "counted_array", "element" => element} = entry,
         smap
       ) do
    count_type = entry["count_type"] || "u16"
    bits = @primitive_sizes[count_type] * 8
    max = integer_max(bits)
    root_path = inspect([String.to_atom(entry["name"])])
    element_encoder = elixir_array_element_encoder(element, smap, "command", "[index | path]")

    [
      "  @spec #{fn_name}([term()]) :: iodata()\n",
      "  def #{fn_name}(items) when is_list(items), do: #{fn_name}(items, #{inspect(command)}, #{root_path})\n\n",
      "  @spec #{fn_name}([term()], atom(), [atom() | non_neg_integer()]) :: iodata()\n",
      "  defp #{fn_name}(items, command, path) when is_list(items) do\n",
      "    count = Enum.count(items)\n",
      "    validate_uint!(command, path, count, #{max})\n",
      "    [<<count::#{bits}>> | Enum.map(Stream.with_index(items), #{element_encoder})]\n",
      "  end\n\n"
    ]
  end

  defp elixir_record_encoder(fn_name, command, entry, smap) do
    base_fields = Map.get(entry, "fields", [])
    root_path = elixir_entry_root_path(entry)

    [
      "  @spec #{fn_name}(map()) :: iodata()\n",
      "  def #{fn_name}(model), do: #{fn_name}(model, #{inspect(command)}, #{inspect(root_path)})\n\n",
      "  @spec #{fn_name}(map(), atom(), [atom() | non_neg_integer()]) :: iodata()\n",
      "  defp #{fn_name}(model, command, path) do\n",
      "    [\n",
      Enum.map(base_fields, fn field ->
        "      #{elixir_encode_field(field, "model", smap, "command", "path")},\n"
      end),
      elixir_encode_conditional_tail(entry, smap),
      "    ]\n",
      "  end\n\n"
    ]
  end

  @spec elixir_encode_conditional_tail(map(), %{String.t() => structure()}) :: iodata()
  defp elixir_encode_conditional_tail(entry, smap) do
    case conditional_tail_fields(entry) do
      [] ->
        []

      tail_fields ->
        [
          "      if #{elixir_guard_expression(entry)} do\n",
          "        [\n",
          Enum.map(tail_fields, fn field ->
            "          #{elixir_encode_field(field, "model", smap, "command", "path")},\n"
          end),
          "        ]\n",
          "      else\n",
          "        []\n",
          "      end\n"
        ]
    end
  end

  @spec elixir_guard_expression(map()) :: String.t()
  defp elixir_guard_expression(entry) do
    guard = conditional_tail_guard(entry) || "true"

    translate_guard(
      guard,
      Enum.map(Map.get(entry, "fields", []), fn field ->
        {field["name"], "Map.fetch!(model, :#{field["name"]})"}
      end)
    )
  end

  @spec elixir_encode_field(
          map(),
          String.t(),
          %{String.t() => structure()},
          String.t(),
          String.t()
        ) :: String.t()
  defp elixir_encode_field(
         %{"name" => name, "type" => "enum", "enum" => enum_name, "repr" => repr},
         source,
         _smap,
         command,
         path
       ) do
    bits = @primitive_sizes[repr] * 8
    value = "encode_#{enum_name}(#{field_read(source, name)})"
    elixir_encode_uint(value, bits, command, field_path(path, name))
  end

  defp elixir_encode_field(%{"name" => name, "type" => type}, source, _smap, command, path)
       when type in ["u8", "u16", "u24", "u32", "u64"] do
    bits = @primitive_sizes[type] * 8
    elixir_encode_uint(field_read(source, name), bits, command, field_path(path, name))
  end

  defp elixir_encode_field(%{"name" => name, "type" => "rgb"}, source, _smap, command, path) do
    elixir_encode_uint(field_read(source, name), 24, command, field_path(path, name))
  end

  defp elixir_encode_field(%{"name" => name, "type" => type}, source, _smap, command, path)
       when type in ["string8", "string16", "string32"] do
    bits = type |> String.replace_prefix("string", "") |> String.to_integer()
    elixir_encode_string(field_read(source, name), bits, command, field_path(path, name))
  end

  defp elixir_encode_field(
         %{"name" => name, "type" => "struct", "element" => element},
         source,
         _smap,
         command,
         path
       ) do
    "#{encode_fn_name(element)}(#{field_read(source, name)}, #{command}, #{field_path(path, name)})"
  end

  defp elixir_encode_field(
         %{
           "name" => name,
           "type" => "counted_array",
           "count_type" => count_type,
           "element" => element
         },
         source,
         smap,
         command,
         path
       ) do
    bits = @primitive_sizes[count_type] * 8
    max = integer_max(bits)
    list = field_read(source, name)
    array_path = field_path(path, name)

    element_encoder =
      elixir_array_element_encoder(element, smap, command, "[index | #{array_path}]")

    "(fn items -> count = Enum.count(items); validate_uint!(#{command}, #{array_path}, count, #{max}); " <>
      "[<<count::#{bits}>> | Enum.map(Stream.with_index(items), #{element_encoder})] end).(#{list})"
  end

  @spec elixir_array_element_encoder(
          String.t(),
          %{String.t() => structure()},
          String.t(),
          String.t()
        ) :: String.t()
  defp elixir_array_element_encoder(element, _smap, command, path)
       when element in ["u8", "u16", "u24", "u32", "u64"] do
    bits = @primitive_sizes[element] * 8
    "fn {value, index} -> #{elixir_encode_uint("value", bits, command, path)} end"
  end

  defp elixir_array_element_encoder("rgb", _smap, command, path) do
    "fn {value, index} -> #{elixir_encode_uint("value", 24, command, path)} end"
  end

  defp elixir_array_element_encoder(element, _smap, command, path)
       when element in ["string8", "string16", "string32"] do
    bits = element |> String.replace_prefix("string", "") |> String.to_integer()
    "fn {value, index} -> #{elixir_encode_string("value", bits, command, path)} end"
  end

  defp elixir_array_element_encoder(element, _smap, command, path) do
    "fn {value, index} -> #{encode_fn_name(element)}(value, #{command}, #{path}) end"
  end

  @spec elixir_encode_uint(String.t(), pos_integer(), String.t(), String.t()) :: String.t()
  defp elixir_encode_uint(expr, bits, command, path) do
    max = integer_max(bits)

    "(fn value -> validate_uint!(#{command}, #{path}, value, #{max}); " <>
      "<<value::#{bits}>> end).(#{expr})"
  end

  @spec elixir_encode_string(String.t(), pos_integer(), String.t(), String.t()) :: String.t()
  defp elixir_encode_string(expr, bits, command, path) do
    max = integer_max(bits)

    "(fn value -> bin = :erlang.iolist_to_binary([value]); " <>
      "validate_uint!(#{command}, #{path}, byte_size(bin), #{max}); " <>
      "<<byte_size(bin)::#{bits}, bin::binary>> end).(#{expr})"
  end

  @spec elixir_validation_helpers() :: iodata()
  defp elixir_validation_helpers do
    [
      "  @spec validate_uint!(atom(), [atom() | non_neg_integer()], term(), non_neg_integer()) :: :ok\n",
      "  defp validate_uint!(_command, _path, value, max)\n",
      "       when is_integer(value) and value >= 0 and value <= max,\n",
      "       do: :ok\n\n",
      "  defp validate_uint!(command, reverse_path, value, max) do\n",
      "    field_path = Enum.reverse(reverse_path)\n",
      "    raise EncodingError,\n",
      "      command: command,\n",
      "      field: Enum.find(reverse_path, &is_atom/1),\n",
      "      field_path: field_path,\n",
      "      actual: value,\n",
      "      min: 0,\n",
      "      max: max\n",
      "  end\n\n"
    ]
  end

  @spec elixir_entry_root_path(map()) :: [atom()]
  defp elixir_entry_root_path(%{"opcode" => _opcode, "name" => name}) do
    [String.to_atom(name)]
  end

  defp elixir_entry_root_path(_entry), do: []

  @spec field_path(String.t(), String.t()) :: String.t()
  defp field_path(path, name), do: "[:#{name} | #{path}]"

  @spec integer_max(pos_integer()) :: pos_integer()
  defp integer_max(bits), do: Bitwise.bsl(1, bits) - 1

  @spec field_read(String.t(), String.t()) :: String.t()
  defp field_read(source, name), do: "Map.fetch!(#{source}, :#{name})"

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
