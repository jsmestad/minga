defmodule Minga.Mix.ProtocolGenerator do
  @moduledoc """
  Generates protocol opcode artifacts from `docs/protocol_schema.toml`.

  The schema is the source of truth. Generated protocol artifacts are written under `.generated/protocol/` for Elixir, `macos/.generated/protocol/` for Swift, and `zig/src/generated/` for Zig. The generated Zig public export block in `zig/src/protocol.zig` is also refreshed from the schema.
  """

  @schema_path "docs/protocol_schema.toml"
  @generated_root ".generated/protocol"
  @generated_elixir_path Path.join([@generated_root, "elixir/lib/minga/protocol/opcodes.ex"])
  @generated_swift_path "macos/.generated/protocol/ProtocolOpcodes.generated.swift"
  @generated_zig_opcodes_path "zig/src/generated/protocol_opcodes.zig"
  @generated_zig_schema_test_path "zig/src/generated/protocol_schema_test.zig"
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
    schema
  end

  @spec generated_files(schema()) :: [generated_file()]
  defp generated_files(schema) do
    [
      {@generated_elixir_path, elixir_file(schema)},
      {@generated_swift_path, swift_file(schema)},
      {@generated_zig_opcodes_path, zig_opcodes_file(schema)},
      {@generated_zig_schema_test_path, zig_schema_test_file(schema)}
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

    [
      "/// Generated protocol opcode constants.\n",
      "///\n",
      "/// Generated from `docs/protocol_schema.toml` by `mix protocol.gen`. Do not edit by hand.\n\n",
      swift_opcodes(opcodes),
      "\n// MARK: - GUI action sub-opcodes\n\n",
      Enum.map(actions, &swift_gui_action_line/1)
    ]
    |> IO.iodata_to_binary()
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

  @spec constant_name(String.t()) :: String.t()
  defp constant_name(name), do: String.upcase(name)

  @spec hex(non_neg_integer()) :: String.t()
  defp hex(value),
    do: "0x" <> (value |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(2, "0"))
end
