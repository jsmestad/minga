defmodule MingaEditor.Commands.Provider do
  @moduledoc """
  Compile-time DSL for editor command provider modules.

  `use MingaEditor.Commands.Provider` keeps the existing `Minga.Command.Provider` contract while replacing repeated `%Minga.Command{}` boilerplate with concise declarations. The DSL only generates command metadata and `__commands__/0`; command behavior stays in normal Elixir functions.
  """

  @command_keys [:execute, :option_toggle, :requires_buffer, :scope]
  @numbered_keys [:argument | @command_keys]

  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      @behaviour Minga.Command.Provider
      import unquote(__MODULE__),
        only: [command: 2, command: 3, commands: 1, numbered_commands: 3, numbered_commands: 4]

      Module.register_attribute(__MODULE__, :minga_commands, accumulate: true)
      @before_compile unquote(__MODULE__)
    end
  end

  @spec command(Macro.t(), Macro.t()) :: Macro.t()
  @spec command(Macro.t(), Macro.t(), Macro.t()) :: Macro.t()
  defmacro command(name_ast, description_ast, opts_ast \\ []) do
    define(command_definition!(name_ast, description_ast, opts_ast, __CALLER__))
  end

  @spec commands(Macro.t()) :: Macro.t()
  defmacro commands(specs_ast) do
    quote do
      for spec <- unquote(specs_ast) do
        @minga_commands unquote(__MODULE__).__command_definition_from_spec__(spec, __ENV__)
      end
    end
  end

  @spec numbered_commands(Macro.t(), Macro.t(), Macro.t()) :: Macro.t()
  @spec numbered_commands(Macro.t(), Macro.t(), Macro.t(), Macro.t()) :: Macro.t()
  defmacro numbered_commands(prefix_ast, range_ast, description_ast, opts_ast \\ []) do
    env = __CALLER__
    prefix = atom!(prefix_ast, env, "numbered command prefix")
    range = range!(range_ast, env)
    description = description!(description_ast, prefix, env)
    opts = numbered_opts!(prefix, opts_ast, env)

    range
    |> Enum.map(&numbered_definition(prefix, &1, description, opts))
    |> Enum.map(&define/1)
    |> then(&{:__block__, [], &1})
  end

  @doc false
  @spec __command_definition_from_spec__(term(), Macro.Env.t()) :: {atom(), String.t(), keyword()}
  def __command_definition_from_spec__({name, description, requires_buffer}, env) do
    name = atom!(name, env, "command name")
    description = description!(description, name, env)
    bool!(requires_buffer, name, env)
    {name, description, [requires_buffer: requires_buffer, execute: default_execute_ast(name)]}
  end

  def __command_definition_from_spec__(spec, env) do
    fail!(
      env,
      "invalid command spec in #{inspect(env.module)}: expected {name, description, requires_buffer}, got #{inspect(spec)}"
    )
  end

  @spec __before_compile__(Macro.Env.t()) :: Macro.t()
  defmacro __before_compile__(env) do
    definitions = env.module |> Module.get_attribute(:minga_commands) |> Enum.reverse()
    validate_unique_names!(definitions, env)
    commands = Enum.map(definitions, &command_ast/1)

    quote do
      @impl Minga.Command.Provider
      @spec __commands__() :: [Minga.Command.t()]
      def __commands__, do: [unquote_splicing(commands)]
    end
  end

  defp define(definition) do
    quote bind_quoted: [definition: Macro.escape(definition)] do
      @minga_commands definition
    end
  end

  defp command_definition!(name_ast, description_ast, opts_ast, env) do
    name = atom!(name_ast, env, "command name")
    description = description!(description_ast, name, env)
    opts = command_opts!(name, opts_ast, env)
    {name, description, opts}
  end

  defp numbered_definition(prefix, n, description, opts) do
    name = String.to_atom("#{prefix}_#{n}")
    argument = numbered_argument(Keyword.get(opts, :argument, :name), name, n)
    opts = Keyword.delete(opts, :argument)

    opts =
      case Keyword.fetch(opts, :execute) do
        {:ok, execute_ast} ->
          Keyword.put(opts, :execute, numbered_execute_ast(execute_ast, argument))

        :error ->
          Keyword.put(opts, :execute, default_execute_ast(name))
      end

    {name, "#{description} #{n}", opts}
  end

  defp command_ast({name, description, opts}) do
    quote do
      %Minga.Command{
        name: unquote(name),
        description: unquote(description),
        requires_buffer: unquote(Keyword.get(opts, :requires_buffer, false)),
        execute: unquote(Keyword.fetch!(opts, :execute)),
        option_toggle: unquote(Keyword.get(opts, :option_toggle, nil)),
        scope: unquote(Keyword.get(opts, :scope, nil))
      }
    end
  end

  defp default_execute_ast(name), do: quote(do: fn state -> execute(state, unquote(name)) end)

  defp numbered_execute_ast(execute_ast, argument),
    do: quote(do: fn state -> unquote(execute_ast).(state, unquote(argument)) end)

  defp numbered_argument(:name, name, _n), do: name
  defp numbered_argument(:number, _name, n), do: n

  defp atom!(value, _env, _label) when is_atom(value) and not is_nil(value), do: value

  defp atom!(value, env, label),
    do: fail!(env, "invalid #{label}: expected a non-nil atom, got #{inspect(value)}")

  defp description!(value, _name, _env) when is_binary(value) and byte_size(value) > 0, do: value

  defp description!(value, name, env),
    do:
      fail!(
        env,
        "invalid description for command #{inspect(name)}: expected a non-empty string, got #{inspect(value)}"
      )

  defp range!({:.., _meta, [first, last]}, _env) when is_integer(first) and is_integer(last),
    do: first..last

  defp range!({:..//, _meta, [first, last, step]}, _env)
       when is_integer(first) and is_integer(last) and is_integer(step), do: first..last//step

  defp range!(value, env),
    do:
      fail!(
        env,
        "invalid range for numbered commands: expected a literal range, got #{Macro.to_string(value)}"
      )

  defp command_opts!(name, opts, env) do
    opts = opts!(name, opts, @command_keys, env)
    bool!(Keyword.get(opts, :requires_buffer, false), name, env)
    scope!(Keyword.get(opts, :scope, nil), name, env)
    option_toggle!(Keyword.get(opts, :option_toggle, nil), name, env)
    execute!(Keyword.get(opts, :execute, nil), name, env)
    Keyword.put_new(opts, :execute, default_execute_ast(name))
  end

  defp numbered_opts!(prefix, opts, env) do
    opts = opts!(prefix, opts, @numbered_keys, env)
    bool!(Keyword.get(opts, :requires_buffer, false), prefix, env)
    scope!(Keyword.get(opts, :scope, nil), prefix, env)
    argument!(Keyword.get(opts, :argument, :name), prefix, env)
    option_toggle!(Keyword.get(opts, :option_toggle, nil), prefix, env)
    numbered_execute!(Keyword.get(opts, :execute, nil), prefix, env)
    opts
  end

  defp opts!(name, opts, valid_keys, env) when is_list(opts) do
    if Keyword.keyword?(opts) do
      invalid = Keyword.keys(opts) -- valid_keys

      if invalid != [],
        do:
          fail!(
            env,
            "invalid options for command #{inspect(name)}: unknown keys #{inspect(invalid)}"
          )

      opts
    else
      fail!(env, "invalid options for command #{inspect(name)}: expected a keyword list")
    end
  end

  defp opts!(name, opts, _valid_keys, env),
    do:
      fail!(
        env,
        "invalid options for command #{inspect(name)}: expected a keyword list, got #{Macro.to_string(opts)}"
      )

  defp bool!(value, _name, _env) when is_boolean(value), do: :ok

  defp bool!(value, name, env),
    do:
      fail!(
        env,
        "invalid requires_buffer for command #{inspect(name)}: expected true or false, got #{inspect(value)}"
      )

  defp option_toggle!(nil, _name, _env), do: :ok
  defp option_toggle!(value, _name, _env) when is_atom(value), do: :ok

  defp option_toggle!({name, fun}, command_name, env) when is_atom(name) do
    if one_arity_function_ast?(fun) do
      :ok
    else
      fail!(
        env,
        "invalid option_toggle for command #{inspect(command_name)}: expected nil, an atom, or {atom, one-arity function/capture}, got #{inspect({name, fun})}"
      )
    end
  end

  defp option_toggle!(value, name, env),
    do:
      fail!(
        env,
        "invalid option_toggle for command #{inspect(name)}: expected nil, an atom, or {atom, one-arity function/capture}, got #{inspect(value)}"
      )

  defp scope!(nil, _name, _env), do: :ok
  defp scope!(value, _name, _env) when is_atom(value), do: :ok

  defp scope!(value, name, env),
    do:
      fail!(
        env,
        "invalid scope for command #{inspect(name)}: expected an atom, got #{inspect(value)}"
      )

  defp argument!(value, _prefix, _env) when value in [:name, :number], do: :ok

  defp argument!(value, prefix, env),
    do:
      fail!(
        env,
        "invalid argument for numbered command #{inspect(prefix)}: expected :name or :number, got #{inspect(value)}"
      )

  defp execute!(nil, _name, _env), do: :ok

  defp execute!(execute, name, env) do
    if one_arity_function_ast?(execute) do
      :ok
    else
      invalid_execute!(name, execute, env)
    end
  end

  defp numbered_execute!(nil, _prefix, _env), do: :ok
  defp numbered_execute!({:&, _meta, [{:/, _slash_meta, [_call, 2]}]}, _prefix, _env), do: :ok

  defp numbered_execute!(execute, prefix, env),
    do:
      fail!(
        env,
        "invalid execute callback for numbered command #{inspect(prefix)}: expected a two-arity function capture or omit execute for default execute/2 routing; got #{Macro.to_string(execute)}"
      )

  defp one_arity_function_ast?(ast) do
    one_arity_capture?(ast) or one_arity_fn?(ast)
  end

  defp one_arity_capture?({:&, _meta, [{:/, _slash_meta, [_call, 1]}]}), do: true

  defp one_arity_capture?({:&, _meta, [body]}) do
    indexes = body |> capture_placeholder_indexes() |> Enum.uniq()
    indexes != [] and Enum.max(indexes) == 1
  end

  defp one_arity_capture?(_), do: false

  defp one_arity_fn?({:fn, _meta, clauses}) when is_list(clauses),
    do: Enum.all?(clauses, &one_arity_clause?/1)

  defp one_arity_fn?(_), do: false

  defp capture_placeholder_indexes(ast) do
    {_ast, indexes} =
      Macro.prewalk(ast, [], fn
        {:&, _meta, [index]} = node, indexes when is_integer(index) -> {node, [index | indexes]}
        node, indexes -> {node, indexes}
      end)

    indexes
  end

  defp one_arity_clause?({:->, _meta, [args, _body]}) when is_list(args), do: length(args) == 1
  defp one_arity_clause?(_clause), do: false

  @spec invalid_execute!(atom(), Macro.t(), Macro.Env.t()) :: no_return()
  defp invalid_execute!(name, execute, env),
    do:
      fail!(
        env,
        "invalid execute callback for command #{inspect(name)}: expected a one-arity function capture, one-arity fn, or omit execute for default execute/2 routing; got #{Macro.to_string(execute)}"
      )

  defp validate_unique_names!(definitions, env) do
    names = Enum.map(definitions, fn {name, _description, _opts} -> name end)
    duplicates = names -- Enum.uniq(names)

    if duplicates != [],
      do:
        fail!(
          env,
          "duplicate command names in #{inspect(env.module)}: #{inspect(Enum.uniq(duplicates))}"
        )
  end

  @spec fail!(Macro.Env.t(), String.t()) :: no_return()
  defp fail!(env, description),
    do: raise(CompileError, file: env.file, line: env.line, description: description)
end
