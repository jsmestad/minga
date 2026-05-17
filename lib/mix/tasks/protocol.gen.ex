defmodule Mix.Tasks.Protocol.Gen do
  @moduledoc """
  Generates protocol opcode constants from `docs/protocol_schema.toml`.

  The generated sections are committed to the repository. Use `mix protocol.gen --check` in CI to verify the committed files match the schema.
  """

  use Mix.Task

  @shortdoc "Generates protocol opcode constants"

  @schema_path "docs/protocol_schema.toml"
  @begin_marker "BEGIN GENERATED (mix protocol.gen)"
  @end_marker "END GENERATED"
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

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, _argv, _invalid} = OptionParser.parse(args, strict: [check: :boolean])
    schema = load_schema!()
    files = generated_files(schema)

    case Keyword.get(opts, :check, false) do
      true -> check_files!(files)
      false -> write_files!(files)
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
      replace_block_file(
        "lib/minga_editor/frontend/protocol.ex",
        elixir_opcodes_block(schema, ["input", "render", "config"], [], ["log_message"])
      ),
      replace_block_file(
        "lib/minga/parser/protocol.ex",
        elixir_opcodes_block(
          schema,
          ["parser_commands", "parser_responses"],
          ["log_message"],
          ["measure_text", "text_width"]
        )
      ),
      replace_block_file(
        "lib/minga_editor/frontend/protocol/gui.ex",
        elixir_gui_block(schema)
      ),
      replace_block_file(
        "lib/minga_editor/frontend/protocol/gui_window_content.ex",
        elixir_opcodes_block(schema, [], ["gui_window_content"], [])
      ),
      {"macos/Sources/Protocol/ProtocolOpcodes.generated.swift", swift_file(schema)},
      replace_block_file("zig/src/protocol.zig", zig_reexports_block(schema)),
      {"zig/src/protocol_opcodes.zig", zig_opcodes_file(schema)},
      {"zig/src/protocol_schema_test.zig", zig_schema_test_file(schema)}
    ]
  end

  @spec replace_block_file(Path.t(), String.t()) :: generated_file()
  defp replace_block_file(path, block) do
    source = File.read!(path)
    {path, replace_generated_block!(source, path, block)}
  end

  @spec replace_generated_block!(String.t(), Path.t(), String.t()) :: String.t()
  defp replace_generated_block!(source, path, block) do
    begin_marker = Regex.escape("--- #{@begin_marker} ---")
    end_marker = Regex.escape("--- #{@end_marker} ---")

    pattern =
      Regex.compile!(
        "([ \\t]*(?:#|//) #{begin_marker}\\n).*?([ \\t]*(?:#|//) #{end_marker})",
        "s"
      )

    case Regex.run(pattern, source, capture: :all_but_first) do
      [begin_line, end_line] -> Regex.replace(pattern, source, begin_line <> block <> end_line)
      nil -> Mix.raise("Missing generated block markers in #{path}")
    end
  end

  @spec write_files!([generated_file()]) :: :ok
  defp write_files!(files) do
    Enum.each(files, fn {path, content} ->
      path |> Path.dirname() |> File.mkdir_p!()
      File.write!(path, content)
    end)
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

  @spec outdated_message([generated_file()]) :: String.t()
  defp outdated_message(stale) do
    paths = Enum.map_join(stale, "\n", fn {path, _content} -> "  - #{path}" end)

    "Generated protocol files are out of date. Run `mix protocol.gen` and commit the result.\n#{paths}"
  end

  @spec elixir_gui_block(schema()) :: String.t()
  defp elixir_gui_block(schema) do
    opcodes =
      opcodes_by_categories(schema, ["gui_chrome", "gui_semantic"], [], ["gui_window_content"])

    actions = Map.fetch!(schema, "gui_actions")

    [
      generated_header("  #"),
      elixir_opcodes(opcodes),
      "\n  # GUI action sub-opcodes (Frontend → BEAM)\n",
      elixir_gui_actions(actions)
    ]
    |> IO.iodata_to_binary()
  end

  @spec elixir_opcodes_block(schema(), [String.t()], [String.t()], [String.t()]) :: String.t()
  defp elixir_opcodes_block(schema, categories, include_names, exclude_names) do
    schema
    |> opcodes_by_categories(categories, include_names, exclude_names)
    |> then(fn opcodes -> [generated_header("  #"), elixir_opcodes(opcodes)] end)
    |> IO.iodata_to_binary()
  end

  @spec generated_header(String.t()) :: String.t()
  defp generated_header(comment_prefix) do
    "#{comment_prefix} Generated from #{@schema_path}. Do not edit by hand.\n"
  end

  @spec elixir_opcodes([opcode()]) :: iodata()
  defp elixir_opcodes(opcodes) do
    opcodes
    |> group_by_category()
    |> Enum.map(fn {category, entries} ->
      ["\n  # ", category_title(category), "\n", Enum.map(entries, &elixir_opcode_line/1)]
    end)
  end

  @spec elixir_opcode_line(opcode()) :: String.t()
  defp elixir_opcode_line(%{"name" => name, "value" => value}) do
    "  @op_#{name} #{hex(value)}\n"
  end

  @spec elixir_gui_actions([gui_action()]) :: iodata()
  defp elixir_gui_actions(actions) do
    Enum.map(actions, fn %{"name" => name, "value" => value} ->
      "  @gui_action_#{name} #{hex(value)}\n"
    end)
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

  @spec zig_reexports_block(schema()) :: String.t()
  defp zig_reexports_block(schema) do
    opcodes = Map.fetch!(schema, "opcodes")
    actions = Map.fetch!(schema, "gui_actions")

    [
      "const opcodes = @import(\"protocol_opcodes.zig\");\n",
      generated_header("//"),
      "\n",
      Enum.map(opcodes, &zig_opcode_reexport_line/1),
      "\n",
      Enum.map(actions, &zig_gui_action_reexport_line/1)
    ]
    |> IO.iodata_to_binary()
  end

  @spec zig_opcode_reexport_line(opcode()) :: String.t()
  defp zig_opcode_reexport_line(%{"name" => name}) do
    constant = constant_name(name)
    "pub const OP_#{constant} = opcodes.OP_#{constant};\n"
  end

  @spec zig_gui_action_reexport_line(gui_action()) :: String.t()
  defp zig_gui_action_reexport_line(%{"name" => name}) do
    constant = constant_name(name)
    "pub const GUI_ACTION_#{constant} = opcodes.GUI_ACTION_#{constant};\n"
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
      "const protocol = @import(\"protocol.zig\");\n",
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

  @spec opcodes_by_categories(schema(), [String.t()], [String.t()], [String.t()]) :: [opcode()]
  defp opcodes_by_categories(schema, categories, include_names, exclude_names) do
    schema
    |> Map.fetch!("opcodes")
    |> Enum.filter(&opcode_selected?(&1, categories, include_names, exclude_names))
  end

  @spec opcode_selected?(opcode(), [String.t()], [String.t()], [String.t()]) :: boolean()
  defp opcode_selected?(
         %{"category" => category, "name" => name},
         categories,
         include_names,
         exclude_names
       ) do
    (category in categories or name in include_names) and name not in exclude_names
  end

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
