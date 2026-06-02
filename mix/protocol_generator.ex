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
      {@generated_swift_command_size_path, swift_command_size_file(schema)}
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

    "// Code generated by mix protocol.gen. DO NOT EDIT.\n\n" <>
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
      go_command_size_helpers()
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
