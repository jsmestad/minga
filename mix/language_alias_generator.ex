defmodule Minga.Mix.LanguageAliasGenerator do
  @moduledoc """
  Generates language-alias lookup tables for Elixir and Zig from `config/language_aliases.json`.
  """

  @source_path "config/language_aliases.json"
  @elixir_path ".generated/language_aliases/elixir/lib/minga/language/generated_aliases.ex"
  @zig_path "zig/src/generated/language_aliases.zig"
  @label_pattern ~r/^[a-z0-9_+.#-]+$/

  @type alias_entry :: %{from: String.t(), to: String.t()}
  @type output :: {String.t(), String.t()}

  @spec run([String.t()]) :: :ok
  def run(args) do
    root = repo_root()
    aliases = load_aliases!(root)
    outputs = outputs(aliases)

    if "--check" in args do
      check_outputs!(root, outputs)
    else
      write_outputs!(root, outputs)
    end
  end

  @spec source_path() :: String.t()
  def source_path, do: @source_path

  @spec generated_paths() :: [String.t()]
  def generated_paths, do: [@elixir_path, @zig_path]

  @spec repo_root() :: String.t()
  defp repo_root, do: File.cwd!()

  @spec load_aliases!(String.t()) :: [alias_entry()]
  defp load_aliases!(root) do
    path = Path.join(root, @source_path)

    with {:ok, contents} <- File.read(path),
         {:ok, %{"aliases" => raw_aliases}} <- JSON.decode(contents) do
      validate_aliases!(raw_aliases, root)
    else
      {:error, %JSON.DecodeError{} = error} ->
        Mix.raise("Invalid #{@source_path}: #{Exception.message(error)}")

      {:error, reason} ->
        Mix.raise("Could not read #{@source_path}: #{inspect(reason)}")

      _other ->
        Mix.raise("Invalid #{@source_path}: expected an object with an aliases array")
    end
  end

  @spec validate_aliases!([term()], String.t()) :: [alias_entry()]
  defp validate_aliases!(raw_aliases, root) when is_list(raw_aliases) do
    canonical_targets = canonical_language_targets(root)

    {aliases, _seen} =
      Enum.reduce(raw_aliases, {[], MapSet.new()}, fn raw_alias, {aliases, seen} ->
        alias_entry = validate_alias!(raw_alias, canonical_targets)

        if MapSet.member?(seen, alias_entry.from) do
          Mix.raise("Duplicate language alias #{inspect(alias_entry.from)} in #{@source_path}")
        end

        {[alias_entry | aliases], MapSet.put(seen, alias_entry.from)}
      end)

    Enum.reverse(aliases)
  end

  defp validate_aliases!(_raw_aliases, _root) do
    Mix.raise("Invalid #{@source_path}: aliases must be a list")
  end

  @spec validate_alias!(term(), MapSet.t(String.t())) :: alias_entry()
  defp validate_alias!(%{"from" => from, "to" => to}, canonical_targets)
       when is_binary(from) and is_binary(to) do
    validate_label!("from", from)
    validate_label!("to", to)
    validate_target!(from, to, canonical_targets)

    if from == to do
      Mix.raise("Language alias #{inspect(from)} maps to itself in #{@source_path}")
    end

    %{from: from, to: to}
  end

  defp validate_alias!(_raw_alias, _canonical_targets) do
    Mix.raise("Invalid #{@source_path}: each alias must have string from/to fields")
  end

  @spec validate_target!(String.t(), String.t(), MapSet.t(String.t())) :: :ok
  defp validate_target!(from, to, canonical_targets) do
    if MapSet.member?(canonical_targets, to) do
      :ok
    else
      Mix.raise(
        "Language alias #{inspect(from)} targets unknown canonical grammar #{inspect(to)} in #{@source_path}"
      )
    end
  end

  @spec canonical_language_targets(String.t()) :: MapSet.t(String.t())
  defp canonical_language_targets(root) do
    root
    |> language_source_targets()
    |> fallback_language_targets()
    |> MapSet.new()
  end

  @spec language_source_targets(String.t()) :: [String.t()]
  defp language_source_targets(root) do
    root
    |> Path.join("lib/minga/language/*.ex")
    |> Path.wildcard()
    |> Enum.flat_map(&language_targets_from_source/1)
  end

  @spec language_targets_from_source(Path.t()) :: [String.t()]
  defp language_targets_from_source(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted!(file: path)
    |> collect_language_targets()
  rescue
    error in [SyntaxError, TokenMissingError] ->
      Mix.raise("Invalid language source #{path}: #{Exception.message(error)}")
  end

  @spec collect_language_targets(Macro.t()) :: [String.t()]
  defp collect_language_targets(ast) do
    {_ast, targets} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:%, _, [struct_alias, {:%{}, _, fields}]} = node, acc ->
          if language_struct_alias?(struct_alias) do
            {node, MapSet.union(acc, MapSet.new(struct_field_targets(fields)))}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    MapSet.to_list(targets)
  end

  @spec language_struct_alias?(Macro.t()) :: boolean()
  defp language_struct_alias?({:__aliases__, _, [:Minga, :Language]}), do: true
  defp language_struct_alias?({:__aliases__, _, [:Language]}), do: true
  defp language_struct_alias?(_), do: false

  @spec struct_field_targets([{atom(), term()}]) :: [String.t()]
  defp struct_field_targets(fields) do
    Enum.flat_map(fields, fn
      {:grammar, value} when is_binary(value) -> [value]
      _ -> []
    end)
  end

  @spec fallback_language_targets([String.t()]) :: [String.t()]
  defp fallback_language_targets([]), do: ~w(javascript cpp)
  defp fallback_language_targets(targets), do: targets

  @spec validate_label!(String.t(), String.t()) :: :ok
  defp validate_label!(field, label) do
    if label == String.downcase(label) and Regex.match?(@label_pattern, label) do
      :ok
    else
      Mix.raise("Invalid language alias #{field} label #{inspect(label)} in #{@source_path}")
    end
  end

  @spec outputs([alias_entry()]) :: [output()]
  defp outputs(aliases) do
    [
      {@elixir_path, elixir_output(aliases)},
      {@zig_path, zig_output(aliases)}
    ]
  end

  @spec check_outputs!(String.t(), [output()]) :: :ok
  defp check_outputs!(root, outputs) do
    stale_paths =
      outputs
      |> Enum.reject(fn {rel_path, expected} ->
        path = Path.join(root, rel_path)
        File.exists?(path) and File.read!(path) == expected
      end)
      |> Enum.map(&elem(&1, 0))

    case stale_paths do
      [] ->
        :ok

      paths ->
        formatted = Enum.map_join(paths, "\n", &"  - #{&1}")

        Mix.raise(
          "Generated language alias artifacts are out of date. Run `mix language_aliases.gen` to regenerate build artifacts.\n#{formatted}"
        )
    end
  end

  @spec write_outputs!(String.t(), [output()]) :: :ok
  defp write_outputs!(root, outputs) do
    Enum.each(outputs, fn {rel_path, contents} ->
      path = Path.join(root, rel_path)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end)
  end

  @spec elixir_output([alias_entry()]) :: String.t()
  defp elixir_output(aliases) do
    entries =
      aliases
      |> Enum.map_join(",\n", fn %{from: from, to: to} ->
        "    #{inspect(from)} => #{inspect(to)}"
      end)

    """
    # Code generated by mix language_aliases.gen. DO NOT EDIT.

    defmodule Minga.Language.GeneratedAliases do
      @moduledoc false

      @aliases %{
    #{entries}
      }

      @spec grammar_aliases() :: %{String.t() => String.t()}
      def grammar_aliases, do: @aliases
    end
    """
  end

  @spec zig_output([alias_entry()]) :: String.t()
  defp zig_output(aliases) do
    alias_entries =
      aliases
      |> Enum.map_join("\n", fn %{from: from, to: to} ->
        "    .{ .from = #{zig_string(from)}, .to = #{zig_string(to)} },"
      end)

    targets =
      aliases
      |> Enum.map(& &1.to)
      |> Enum.uniq()
      |> Enum.map_join("\n", fn target -> "    #{zig_string(target)}," end)

    """
    //! Generated from `config/language_aliases.json` by `mix language_aliases.gen`. Do not edit by hand.

    pub const Alias = struct { from: []const u8, to: []const u8 };

    pub const aliases = [_]Alias{
    #{alias_entries}
    };

    pub const targets = [_][]const u8{
    #{targets}
    };
    """
  end

  @spec zig_string(String.t()) :: String.t()
  defp zig_string(value) do
    if String.contains?(value, ["\\", "\"", "\n", "\r", "\t"]) do
      Mix.raise("Cannot generate Zig string for unsupported alias label #{inspect(value)}")
    end

    ~s("#{value}")
  end
end
