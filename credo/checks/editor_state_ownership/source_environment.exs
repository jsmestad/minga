defmodule Minga.Credo.EditorStateOwnership.SourceEnvironment do
  @moduledoc """
  Lexical, source-ordered alias and import environment for EX9012.

  Environments are immutable scope values. A nested module, function, or branch
  receives the current environment, while declarations made there are discarded
  when traversal returns to the enclosing scope.
  """

  @ast_forms ~w(. __block__ __aliases__ alias import require use def defp defmacro defmacrop defmodule @ = |>)a
  @unrestricted_import_functions %{
    "Map" => Map.__info__(:functions),
    "Registry" => Registry.__info__(:functions)
  }

  @enforce_keys [:module, :function, :aliases, :imports]
  defstruct module: nil, function: nil, aliases: %{}, imports: []

  @type import_entry :: %{
          module: String.t(),
          only: [{atom(), non_neg_integer()}] | nil,
          except: [{atom(), non_neg_integer()}]
        }

  @type t :: %__MODULE__{
          module: String.t() | nil,
          function: String.t() | nil,
          aliases: %{optional(atom()) => String.t()},
          imports: [import_entry()]
        }

  @doc "Returns an empty top-level source environment."
  @spec new() :: t()
  def new, do: %__MODULE__{module: nil, function: nil, aliases: %{}, imports: []}

  @doc "Enters a module scope while inheriting declarations visible at its definition."
  @spec enter_module(t(), String.t()) :: t()
  def enter_module(%__MODULE__{} = env, module) do
    %{env | module: module, function: nil}
  end

  @doc "Enters a function scope while inheriting module-level aliases and imports."
  @spec enter_function(t(), String.t()) :: t()
  def enter_function(%__MODULE__{} = env, function), do: %{env | function: function}

  @doc "Applies one alias or import declaration to the current lexical scope."
  @spec apply_directive(t(), Macro.t()) :: t()
  def apply_directive(%__MODULE__{} = env, {:alias, _, [module_ast]}) do
    put_aliases(env, module_ast, nil)
  end

  def apply_directive(%__MODULE__{} = env, {:alias, _, [module_ast, opts]})
      when is_list(opts) do
    put_aliases(env, module_ast, Keyword.get(opts, :as))
  end

  def apply_directive(%__MODULE__{} = env, {:import, _, [module_ast]}) do
    put_import(env, module_ast, [])
  end

  def apply_directive(%__MODULE__{} = env, {:import, _, [module_ast, opts]})
      when is_list(opts) do
    put_import(env, module_ast, opts)
  end

  def apply_directive(%__MODULE__{} = env, _ast), do: env

  @doc "Returns whether an AST node changes the lexical source environment."
  @spec directive?(Macro.t()) :: boolean()
  def directive?({kind, _, _args}) when kind in [:alias, :import], do: true
  def directive?(_ast), do: false

  @doc "Resolves a module expression using aliases visible at this source position."
  @spec module_name(Macro.t(), t()) :: String.t() | nil
  def module_name({:__MODULE__, _, _}, %__MODULE__{} = env), do: env.module

  def module_name({:__aliases__, _, [{:__MODULE__, _, _} | parts]}, %__MODULE__{} = env) do
    if env.module && Enum.all?(parts, &is_atom/1) do
      Enum.join([env.module | Enum.map(parts, &Atom.to_string/1)], ".")
    end
  end

  def module_name({:__aliases__, _, parts}, %__MODULE__{} = env) do
    resolve_alias_parts(parts, env)
  end

  def module_name(atom, %__MODULE__{}) when is_atom(atom), do: inspect(atom)
  def module_name(_ast, %__MODULE__{}), do: nil

  @doc "Resolves a defmodule name relative to its enclosing module scope."
  @spec declared_module(Macro.t(), t()) :: String.t() | nil
  def declared_module({:__aliases__, _, [:"Elixir" | parts]}, %__MODULE__{}) do
    join_atom_parts(parts)
  end

  def declared_module({:__aliases__, _, [first | _rest] = parts} = ast, %__MODULE__{} = env)
      when is_atom(first) do
    resolved = module_name(ast, env)
    aliased? = Map.has_key?(env.aliases, first)

    if env.module && not aliased?,
      do: Enum.join([env.module, join_atom_parts(parts)], "."),
      else: resolved
  end

  def declared_module(ast, %__MODULE__{} = env), do: module_name(ast, env)

  @doc "Resolves an imported function at this exact lexical source position."
  @spec imported_module(t(), atom(), non_neg_integer()) :: String.t() | nil
  def imported_module(%__MODULE__{}, function, _arity) when function in @ast_forms, do: nil

  def imported_module(%__MODULE__{imports: imports}, function, arity) do
    Enum.find_value(imports, fn import ->
      imported? =
        (is_nil(import.only) or {function, arity} in import.only) and
          {function, arity} not in import.except

      if imported?, do: import.module
    end)
  end

  @doc "Returns the first source module without collecting declarations globally."
  @spec source_module(Macro.t()) :: String.t() | nil
  def source_module(ast), do: find_source_module(ast, new())

  @spec find_source_module(Macro.t(), t()) :: String.t() | nil
  defp find_source_module({:defmodule, _, [module_ast, _blocks]}, env) do
    declared_module(module_ast, env)
  end

  defp find_source_module({:__block__, _, forms}, env) when is_list(forms) do
    Enum.find_value(forms, &find_source_module(&1, env))
  end

  defp find_source_module(_ast, _env), do: nil

  @spec put_aliases(t(), Macro.t(), Macro.t() | nil) :: t()
  defp put_aliases(%__MODULE__{} = env, module_ast, as_ast) do
    entries = alias_entries(module_ast, as_ast, env)

    %{
      env
      | aliases:
          Enum.reduce(entries, env.aliases, fn {short, full}, acc -> Map.put(acc, short, full) end)
    }
  end

  @spec alias_entries(Macro.t(), Macro.t() | nil, t()) :: [{atom(), String.t()}]
  defp alias_entries(
         {{:., _, [base_ast, :{}]}, _, grouped},
         nil,
         %__MODULE__{} = env
       )
       when is_list(grouped) do
    case module_name(base_ast, env) do
      nil -> []
      base -> Enum.flat_map(grouped, &grouped_alias_entry(base, &1))
    end
  end

  defp alias_entries(module_ast, as_ast, %__MODULE__{} = env) do
    with module when is_binary(module) <- module_name(module_ast, env),
         short when is_atom(short) <- alias_short_name(module_ast, as_ast) do
      [{short, module}]
    else
      _unknown -> []
    end
  end

  @spec grouped_alias_entry(String.t(), Macro.t()) :: [{atom(), String.t()}]
  defp grouped_alias_entry(base, {:__aliases__, _, parts}) do
    case join_atom_parts(parts) do
      nil -> []
      suffix -> [{List.last(parts), base <> "." <> suffix}]
    end
  end

  defp grouped_alias_entry(_base, _ast), do: []

  @spec alias_short_name(Macro.t(), Macro.t() | nil) :: atom() | nil
  defp alias_short_name(_module_ast, {:__aliases__, _, parts}), do: List.last(parts)
  defp alias_short_name({:__aliases__, _, parts}, nil), do: List.last(parts)
  defp alias_short_name(_module_ast, _as_ast), do: nil

  @spec put_import(t(), Macro.t(), keyword()) :: t()
  defp put_import(%__MODULE__{} = env, module_ast, opts) do
    case module_name(module_ast, env) do
      nil ->
        env

      module ->
        only = import_selection(Keyword.get(opts, :only), :only)

        import = %{
          module: module,
          only: only || Map.get(@unrestricted_import_functions, module),
          except: import_selection(Keyword.get(opts, :except), :except)
        }

        %{env | imports: [import | env.imports]}
    end
  end

  @spec import_selection(term(), atom()) :: [{atom(), non_neg_integer()}] | nil
  defp import_selection(nil, :only), do: nil
  defp import_selection(nil, :except), do: []
  defp import_selection(:functions, _kind), do: nil
  defp import_selection(:macros, _kind), do: []

  defp import_selection(selection, _kind) when is_list(selection) do
    Enum.filter(selection, fn
      {name, arity} when is_atom(name) and is_integer(arity) -> true
      _entry -> false
    end)
  end

  defp import_selection(_selection, :only), do: []
  defp import_selection(_selection, :except), do: []

  @spec resolve_alias_parts([term()], t()) :: String.t() | nil
  defp resolve_alias_parts([:"Elixir" | parts], _env), do: join_atom_parts(parts)

  defp resolve_alias_parts([first | rest] = parts, %__MODULE__{} = env) when is_atom(first) do
    case Map.get(env.aliases, first) do
      nil -> join_atom_parts(parts)
      expanded -> Enum.join([expanded | Enum.map(rest, &Atom.to_string/1)], ".")
    end
  end

  defp resolve_alias_parts(_parts, _env), do: nil

  @spec join_atom_parts([term()]) :: String.t() | nil
  defp join_atom_parts(parts) do
    if parts != [] and Enum.all?(parts, &is_atom/1),
      do: Enum.map_join(parts, ".", &Atom.to_string/1)
  end
end
