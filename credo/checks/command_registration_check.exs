defmodule Minga.Credo.CommandRegistrationCheck do
  @moduledoc """
  Cross-checks ex-command parser, type, registry, and dispatch registration.

  Ex commands are easy to break because the parser, `parsed` type union, command registry providers, and tuple dispatcher live in different files. This check keeps those sites honest by deriving the command atom sets from source and flagging mismatches during `mix credo`.
  """

  use Credo.Check,
    id: "EX9007",
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Every ex-command atom parsed by `Minga.Command.Parser` must be represented in the `parsed` type and must have either a direct `execute_ex_command` dispatcher or a registered provider command. Every provider module under `lib/minga_editor/commands/` must also be listed in `Minga.Command.Registry`.
      """
    ]

  @non_command_parser_atoms ~w(absolute current_line last_line no_range visual whole_buffer)a

  @impl Credo.Check
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(%SourceFile{} = source_file, params) do
    if target_file?(source_file.filename, params) do
      issue_meta = IssueMeta.for(source_file, params)
      root = root_path(params)

      root
      |> collect_sites()
      |> issues_for_sites(issue_meta)
    else
      []
    end
  end

  @spec target_file?(String.t(), keyword()) :: boolean()
  defp target_file?(filename, params) do
    target = params |> root_path() |> Path.join(parser_path(params)) |> Path.expand()

    filename
    |> Path.expand()
    |> String.ends_with?(target)
  end

  @spec collect_sites(String.t()) :: map()
  defp collect_sites(root) do
    parser = read_file(root, parser_path([]))
    commands = read_file(root, "lib/minga_editor/commands.ex")
    buffer_management = read_file(root, "lib/minga_editor/commands/buffer_management.ex")
    registry = read_file(root, "lib/minga/command/registry.ex")
    provider_sources = provider_sources(root)

    registered_modules = registered_modules(registry)
    provider_modules = provider_modules(provider_sources)

    %{
      parser_atoms: parser_atoms(parser),
      type_atoms: type_atoms(parser),
      dispatch_atoms:
        dispatch_atoms(commands, buffer_management, provider_sources, registered_modules),
      registered_modules: registered_modules,
      provider_modules: provider_modules
    }
  end

  @spec issues_for_sites(map(), Credo.IssueMeta.t()) :: [Credo.Issue.t()]
  defp issues_for_sites(sites, issue_meta) do
    []
    |> add_atom_difference_issue(
      sites.parser_atoms,
      sites.type_atoms,
      issue_meta,
      "Parser returns ex-command atoms missing from `@type parsed`:"
    )
    |> add_atom_difference_issue(
      sites.type_atoms,
      sites.parser_atoms,
      issue_meta,
      "`@type parsed` contains ex-command atoms that the parser never returns:"
    )
    |> add_atom_difference_issue(
      sites.parser_atoms,
      sites.dispatch_atoms,
      issue_meta,
      "Parser returns ex-command atoms with no direct dispatcher or registered provider command:"
    )
    |> add_module_difference_issue(
      sites.provider_modules,
      sites.registered_modules,
      issue_meta,
      "Command provider modules missing from `Minga.Command.Registry @command_modules`:"
    )
    |> add_module_difference_issue(
      sites.registered_modules,
      sites.provider_modules,
      issue_meta,
      "Registry lists modules that do not declare `Minga.Command.Provider`:"
    )
  end

  @spec add_atom_difference_issue(
          [Credo.Issue.t()],
          MapSet.t(atom()),
          MapSet.t(atom()),
          Credo.IssueMeta.t(),
          String.t()
        ) :: [Credo.Issue.t()]
  defp add_atom_difference_issue(issues, left, right, issue_meta, message) do
    left
    |> MapSet.difference(right)
    |> MapSet.to_list()
    |> Enum.sort()
    |> add_difference_issue(issues, issue_meta, message)
  end

  @spec add_module_difference_issue(
          [Credo.Issue.t()],
          MapSet.t(String.t()),
          MapSet.t(String.t()),
          Credo.IssueMeta.t(),
          String.t()
        ) :: [Credo.Issue.t()]
  defp add_module_difference_issue(issues, left, right, issue_meta, message) do
    left
    |> MapSet.difference(right)
    |> MapSet.to_list()
    |> Enum.sort()
    |> add_difference_issue(issues, issue_meta, message)
  end

  @spec add_difference_issue(
          [atom()] | [String.t()],
          [Credo.Issue.t()],
          Credo.IssueMeta.t(),
          String.t()
        ) :: [Credo.Issue.t()]
  defp add_difference_issue([], issues, _issue_meta, _message), do: issues

  defp add_difference_issue(values, issues, issue_meta, message) do
    trigger = Enum.map_join(values, ", ", &to_string/1)

    issue =
      format_issue(issue_meta,
        message: "#{message} #{trigger}",
        trigger: trigger,
        line_no: 1
      )

    [issue | issues]
  end

  @spec parser_atoms(String.t()) :: MapSet.t(atom())
  defp parser_atoms(parser) do
    parser
    |> parser_without_parsed_type()
    |> tuple_command_atoms()
    |> MapSet.difference(MapSet.new(@non_command_parser_atoms))
  end

  @spec type_atoms(String.t()) :: MapSet.t(atom())
  defp type_atoms(parser) do
    parser
    |> parsed_type_block()
    |> tuple_command_atoms()
  end

  @spec tuple_command_atoms(String.t()) :: MapSet.t(atom())
  defp tuple_command_atoms(source) do
    ~r/\{:(?<name>[a-zA-Z_][a-zA-Z0-9_]*)(?:,|\})/
    |> Regex.scan(source, capture: ["name"])
    |> Enum.map(fn [name] -> String.to_atom(name) end)
    |> MapSet.new()
  end

  @spec parsed_type_block(String.t()) :: String.t()
  defp parsed_type_block(parser) do
    case Regex.run(parsed_type_regex(), parser, capture: ["body"]) do
      [body] -> body
      nil -> ""
    end
  end

  @spec parser_without_parsed_type(String.t()) :: String.t()
  defp parser_without_parsed_type(parser) do
    Regex.replace(parsed_type_regex(), parser, "")
  end

  @spec parsed_type_regex() :: Regex.t()
  defp parsed_type_regex do
    ~r/@type parsed ::(?<body>.*?)(?=\n\s*@(?:type|typedoc|doc|spec)\b|\n\s*defp?\s)/s
  end

  @spec dispatch_atoms(String.t(), String.t(), [{String.t(), String.t()}], MapSet.t(String.t())) ::
          MapSet.t(atom())
  defp dispatch_atoms(commands, buffer_management, provider_sources, registered_modules) do
    commands
    |> direct_execute_ex_atoms(buffer_management)
    |> MapSet.union(ex_tuple_dispatch_atoms(commands))
    |> MapSet.union(registered_provider_command_atoms(provider_sources, registered_modules))
  end

  @spec direct_execute_ex_atoms(String.t(), String.t()) :: MapSet.t(atom())
  defp direct_execute_ex_atoms(commands, buffer_management) do
    ~r/\{:execute_ex_command,\s*\{:(?<name>[a-zA-Z_][a-zA-Z0-9_]*)(?:,|\})/s
    |> Regex.scan(commands <> "\n" <> buffer_management, capture: ["name"])
    |> Enum.map(fn [name] -> String.to_atom(name) end)
    |> MapSet.new()
  end

  @spec ex_tuple_dispatch_atoms(String.t()) :: MapSet.t(atom())
  defp ex_tuple_dispatch_atoms(commands) do
    case Regex.run(~r/@ex_tuple_dispatch_commands\s+\[(?<body>.*?)\]/s, commands,
           capture: ["body"]
         ) do
      [body] -> atom_literals(body)
      nil -> MapSet.new()
    end
  end

  @spec registered_provider_command_atoms([{String.t(), String.t()}], MapSet.t(String.t())) ::
          MapSet.t(atom())
  defp registered_provider_command_atoms(provider_sources, registered_modules) do
    provider_sources
    |> Enum.filter(fn {module, _source} -> MapSet.member?(registered_modules, module) end)
    |> Enum.reduce(MapSet.new(), fn {_module, source}, acc ->
      MapSet.union(acc, provider_command_atoms(source))
    end)
  end

  @spec provider_command_atoms(String.t()) :: MapSet.t(atom())
  defp provider_command_atoms(source) do
    []
    |> MapSet.new()
    |> MapSet.union(command_macro_atoms(source))
    |> MapSet.union(command_struct_atoms(source))
    |> MapSet.union(command_list_attr_atoms(source))
  end

  @spec command_macro_atoms(String.t()) :: MapSet.t(atom())
  defp command_macro_atoms(source) do
    ~r/\bcommand\(:(?<name>[a-zA-Z_][a-zA-Z0-9_]*)/
    |> Regex.scan(source, capture: ["name"])
    |> Enum.map(fn [name] -> String.to_atom(name) end)
    |> MapSet.new()
  end

  @spec command_struct_atoms(String.t()) :: MapSet.t(atom())
  defp command_struct_atoms(source) do
    ~r/%(?:Minga\.)?Command\{[^}]*name:\s*:(?<name>[a-zA-Z_][a-zA-Z0-9_]*)/s
    |> Regex.scan(source, capture: ["name"])
    |> Enum.map(fn [name] -> String.to_atom(name) end)
    |> MapSet.new()
  end

  @spec command_list_attr_atoms(String.t()) :: MapSet.t(atom())
  defp command_list_attr_atoms(source) do
    source
    |> referenced_command_list_attrs()
    |> Enum.reduce(MapSet.new(), fn attr_name, acc ->
      MapSet.union(acc, command_list_attr_atoms_for(source, attr_name))
    end)
  end

  @spec referenced_command_list_attrs(String.t()) :: MapSet.t(String.t())
  defp referenced_command_list_attrs(source) do
    command_list_attr_reference_regexes()
    |> Enum.reduce(MapSet.new(), fn regex, acc ->
      regex
      |> Regex.scan(source, capture: ["name"])
      |> Enum.map(fn [name] -> name end)
      |> MapSet.new()
      |> MapSet.union(acc)
    end)
  end

  @spec command_list_attr_reference_regexes() :: [Regex.t()]
  defp command_list_attr_reference_regexes do
    [
      ~r/\bcommands\s*\(@(?<name>[a-zA-Z_][a-zA-Z0-9_]*)\b/,
      ~r/\bnumbered_commands\s*\(@(?<name>[a-zA-Z_][a-zA-Z0-9_]*)\b/,
      ~r/\bEnum\.(?:map|flat_map|reduce|reduce_while)\s*\(@(?<name>[a-zA-Z_][a-zA-Z0-9_]*)\b/
    ]
  end

  @spec command_list_attr_atoms_for(String.t(), String.t()) :: MapSet.t(atom())
  defp command_list_attr_atoms_for(source, attr_name) do
    case Regex.run(command_list_attr_regex(attr_name), source, capture: ["body"]) do
      [body] ->
        ~r/\{:(?<name>[a-zA-Z_][a-zA-Z0-9_]*),\s*/
        |> Regex.scan(body, capture: ["name"])
        |> Enum.map(fn [name] -> String.to_atom(name) end)
        |> MapSet.new()

      nil ->
        MapSet.new()
    end
  end

  @spec command_list_attr_regex(String.t()) :: Regex.t()
  defp command_list_attr_regex(attr_name) do
    Regex.compile!("@#{attr_name}\\s+\\[(?<body>.*?)\\]", "s")
  end

  @spec registered_modules(String.t()) :: MapSet.t(String.t())
  defp registered_modules(registry) do
    registry
    |> command_modules_block()
    |> module_names()
  end

  @spec command_modules_block(String.t()) :: String.t()
  defp command_modules_block(registry) do
    case Regex.run(~r/@command_modules\s+\[(?<body>.*?)\]/s, registry, capture: ["body"]) do
      [body] -> body
      nil -> ""
    end
  end

  @spec provider_modules([{String.t(), String.t()}]) :: MapSet.t(String.t())
  defp provider_modules(provider_sources) do
    provider_sources
    |> Enum.filter(fn {_module, source} -> provider_source?(source) end)
    |> Enum.map(fn {module, _source} -> module end)
    |> Enum.reject(&(&1 == "MingaEditor.Commands.Provider"))
    |> MapSet.new()
  end

  @spec provider_source?(String.t()) :: boolean()
  defp provider_source?(source) do
    String.contains?(source, "use MingaEditor.Commands.Provider") or
      String.contains?(source, "@behaviour Minga.Command.Provider")
  end

  @spec provider_sources(String.t()) :: [{String.t(), String.t()}]
  defp provider_sources(root) do
    root
    |> Path.join("lib/minga_editor/commands/*.ex")
    |> Path.wildcard()
    |> Enum.map(&source_with_module/1)
  end

  @spec source_with_module(String.t()) :: {String.t(), String.t()}
  defp source_with_module(path) do
    source = File.read!(path)
    {module_name(source), source}
  end

  @spec module_name(String.t()) :: String.t()
  defp module_name(source) do
    case Regex.run(~r/defmodule\s+(?<name>[A-Za-z0-9_.]+)/, source, capture: ["name"]) do
      [name] -> name
      nil -> ""
    end
  end

  @spec module_names(String.t()) :: MapSet.t(String.t())
  defp module_names(source) do
    ~r/MingaEditor\.Commands\.[A-Za-z0-9_.]+/
    |> Regex.scan(source)
    |> Enum.map(fn [name] -> name end)
    |> MapSet.new()
  end

  @spec atom_literals(String.t()) :: MapSet.t(atom())
  defp atom_literals(source) do
    ~r/:(?<name>[a-zA-Z_][a-zA-Z0-9_]*)/
    |> Regex.scan(source, capture: ["name"])
    |> Enum.map(fn [name] -> String.to_atom(name) end)
    |> MapSet.new()
  end

  @spec read_file(String.t(), String.t()) :: String.t()
  defp read_file(root, path) do
    root
    |> Path.join(path)
    |> File.read!()
  end

  @spec root_path(keyword()) :: String.t()
  defp root_path(params), do: params |> Keyword.get(:root_path, File.cwd!()) |> Path.expand()

  @spec parser_path(keyword()) :: String.t()
  defp parser_path(params), do: Keyword.get(params, :parser_path, "lib/minga/command/parser.ex")
end
