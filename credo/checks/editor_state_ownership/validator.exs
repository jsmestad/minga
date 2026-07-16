defmodule Minga.Credo.EditorStateOwnership.Validator do
  @moduledoc """
  Validates EX9012 policy and returns a typed scanner value.

  Validation is all-or-nothing: any malformed parameter produces configuration
  issues and source analysis is skipped for that file.
  """

  alias Minga.Credo.EditorStateOwnership.Config
  alias Minga.Credo.EditorStateOwnership.Ownership
  alias Minga.Credo.EditorStateOwnership.Policy

  @typedoc "A human-readable configuration error."
  @type error :: String.t()
  @type result :: {:ok, Policy.t()} | {:error, [error()]}

  @doc "Validates raw Credo parameters into a typed ownership policy."
  @spec validate(term(), term(), term()) :: result()
  def validate(ownerships, pure_modules, allowlist) do
    ownership_errors = validate_ownerships(ownerships)
    pure_module_errors = validate_pure_modules(pure_modules)

    ownership_owner_errors =
      case {ownership_errors, pure_module_errors} do
        {[], []} -> validate_pure_module_owners(ownerships, pure_modules)
        {_ownership_errors, _pure_module_errors} -> []
      end

    errors =
      ownership_errors ++
        pure_module_errors ++
        ownership_owner_errors ++
        validate_allowlist(allowlist)

    case errors do
      [] -> {:ok, build_policy(ownerships, pure_modules)}
      errors -> {:error, errors}
    end
  end

  @spec build_policy([keyword()], :owners | [String.t()]) :: Policy.t()
  defp build_policy(ownerships, pure_modules) do
    ownerships = Enum.map(ownerships, &build_ownership/1)

    pure_modules =
      case pure_modules do
        :owners ->
          ownerships
          |> Enum.filter(& &1.pure?)
          |> Enum.flat_map(& &1.owners)

        modules ->
          modules
      end

    %Policy{
      ownerships: ownerships,
      pure_modules: MapSet.new(pure_modules),
      process_modules: MapSet.new(Config.process_modules()),
      boundary_prefixes: Config.boundary_prefixes(),
      boundary_segments: MapSet.new(Config.boundary_segments()),
      value_modules: MapSet.new(Config.value_modules())
    }
  end

  @spec build_ownership(keyword()) :: Ownership.t()
  defp build_ownership(ownership) do
    %Ownership{
      struct: Keyword.fetch!(ownership, :struct),
      owners: Keyword.fetch!(ownership, :owners),
      paths: Keyword.fetch!(ownership, :paths),
      pure?: Keyword.get(ownership, :pure, true),
      generic_api?: Keyword.get(ownership, :generic_api, true),
      boundary: Keyword.fetch!(ownership, :boundary),
      workflow: Keyword.fetch!(ownership, :workflow)
    }
  end

  @spec validate_ownerships(term()) :: [error()]
  defp validate_ownerships(ownerships) when is_list(ownerships) do
    Enum.flat_map(ownerships, &validate_ownership/1) ++ duplicate_errors(ownerships)
  end

  defp validate_ownerships(_ownerships), do: ["ownerships must be a list"]

  @spec validate_ownership(term()) :: [error()]
  defp validate_ownership(ownership) when is_list(ownership) do
    required = [:struct, :owners, :paths, :boundary, :workflow]

    if Keyword.keyword?(ownership) and Enum.all?(required, &Keyword.has_key?(ownership, &1)) and
         exact_module?(Keyword.get(ownership, :struct)) and
         valid_owner_list?(Keyword.get(ownership, :owners)) and
         valid_paths?(Keyword.get(ownership, :paths)) and
         Keyword.get(ownership, :pure, true) == true and
         optional_boolean?(Keyword.get(ownership, :generic_api, true)) and
         documented?(Keyword.get(ownership, :boundary)) and
         documented?(Keyword.get(ownership, :workflow)) do
      []
    else
      [
        "ownership entries require an exact struct, non-empty owners, bounded atom paths, boundary, and workflow; owner purity cannot be disabled"
      ]
    end
  end

  defp validate_ownership(_ownership), do: ["ownership entries must be keyword lists"]

  @spec duplicate_errors([term()]) :: [error()]
  defp duplicate_errors(ownerships) do
    ownerships
    |> Enum.filter(&Keyword.keyword?/1)
    |> Enum.map(&Keyword.get(&1, :struct))
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.flat_map(fn
      {_struct, 1} -> []
      {struct, _count} -> ["ownership struct #{struct} is declared more than once"]
    end)
  end

  @spec validate_pure_modules(term()) :: [error()]
  defp validate_pure_modules(:owners), do: []

  defp validate_pure_modules(modules) when is_list(modules) do
    if Enum.all?(modules, &exact_module?/1) and length(modules) == length(Enum.uniq(modules)),
      do: [],
      else: ["pure_modules must contain unique exact module names"]
  end

  defp validate_pure_modules(_modules),
    do: ["pure_modules must be :owners or a list of exact module names"]

  @spec validate_pure_module_owners([keyword()], :owners | [String.t()]) :: [error()]
  defp validate_pure_module_owners(_ownerships, :owners), do: []

  defp validate_pure_module_owners(ownerships, modules) do
    declared_owners =
      ownerships
      |> Enum.flat_map(&Keyword.fetch!(&1, :owners))
      |> MapSet.new()

    configured_modules = MapSet.new(modules)

    undeclared_errors =
      modules
      |> Enum.reject(&MapSet.member?(declared_owners, &1))
      |> Enum.map(fn module ->
        "pure_modules entry #{module} is not a declared ownership owner; add it to an ownership :owners list or remove it from pure_modules"
      end)

    omitted_errors =
      declared_owners
      |> MapSet.difference(configured_modules)
      |> Enum.sort()
      |> Enum.map(fn module ->
        "declared ownership owner #{module} is missing from pure_modules; use :owners or include every declared owner"
      end)

    undeclared_errors ++ omitted_errors
  end

  @spec validate_allowlist(term()) :: [error()]
  defp validate_allowlist([]), do: []

  defp validate_allowlist(_allowlist),
    do: ["ownership exceptions are forbidden; the EX9012 allowlist must remain empty"]

  @spec valid_owner_list?(term()) :: boolean()
  defp valid_owner_list?(owners) when is_list(owners) and owners != [],
    do: Enum.all?(owners, &exact_module?/1) and length(owners) == length(Enum.uniq(owners))

  defp valid_owner_list?(_owners), do: false

  @spec valid_paths?(term()) :: boolean()
  defp valid_paths?(paths) when is_list(paths) do
    Enum.all?(paths, fn path ->
      is_list(path) and path != [] and length(path) <= 8 and Enum.all?(path, &is_atom/1)
    end) and length(paths) == length(Enum.uniq(paths))
  end

  defp valid_paths?(_paths), do: false

  @spec optional_boolean?(term()) :: boolean()
  defp optional_boolean?(value), do: is_boolean(value)

  @spec exact_module?(term()) :: boolean()
  defp exact_module?(value) when is_binary(value) do
    Regex.match?(~r/^[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*$/, value)
  end

  defp exact_module?(_value), do: false

  @spec documented?(term()) :: boolean()
  defp documented?(value) when is_binary(value), do: String.length(String.trim(value)) >= 12
  defp documented?(_value), do: false
end
