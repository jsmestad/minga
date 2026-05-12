defmodule MingaEditor.UI.Picker.HelpSource do
  @moduledoc """
  Picker source for looking up loaded module and function documentation.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Help.Docs
  alias MingaEditor.Commands.Help
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  @type arity_t :: non_neg_integer()
  @type module_exports :: {module(), [{atom(), arity_t()}]}

  @cache_key {__MODULE__, :candidates}

  @impl true
  @spec title() :: String.t()
  def title, do: "Describe function"

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{}) do
    entries = module_exports()
    cached_candidates(entries)
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: {:module, module}}, state) when is_atom(module) do
    Help.show_in_help_buffer(state, Docs.format_module(module), filetype: :markdown)
  end

  def on_select(%Item{id: {:function, module, function, arity}}, state)
      when is_atom(module) and is_atom(function) and is_integer(arity) and arity >= 0 do
    Help.show_in_help_buffer(state, Docs.format_function(module, function, arity),
      filetype: :markdown
    )
  end

  def on_select(_item, state), do: state

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state

  @spec cached_candidates([module_exports()]) :: [Item.t()]
  defp cached_candidates(entries) do
    case :persistent_term.get(@cache_key, :missing) do
      {^entries, candidates} -> candidates
      _missing_or_stale -> build_and_cache_candidates(entries)
    end
  end

  @spec build_and_cache_candidates([module_exports()]) :: [Item.t()]
  defp build_and_cache_candidates(entries) do
    candidates = build_candidates(entries)
    :persistent_term.put(@cache_key, {entries, candidates})
    candidates
  end

  @spec build_candidates([module_exports()]) :: [Item.t()]
  defp build_candidates(entries) do
    entries
    |> Enum.flat_map(&module_items/1)
    |> Enum.sort_by(& &1.label)
  end

  @spec module_exports() :: [module_exports()]
  defp module_exports do
    loaded_modules = Enum.map(:code.all_loaded(), fn {module, _path} -> module end)
    app_modules = Application.spec(:minga, :modules) || []

    (loaded_modules ++ app_modules)
    |> Enum.uniq()
    |> Enum.filter(fn module -> public_elixir_module?(module) and Code.ensure_loaded?(module) end)
    |> Enum.sort_by(&Atom.to_string/1)
    |> Enum.map(fn module -> {module, public_functions(module)} end)
  end

  @spec public_elixir_module?(module()) :: boolean()
  defp public_elixir_module?(module) when is_atom(module) do
    name = Atom.to_string(module)

    String.starts_with?(name, "Elixir.") and not generated_or_internal_module?(name)
  end

  @spec generated_or_internal_module?(String.t()) :: boolean()
  defp generated_or_internal_module?(name) do
    String.contains?(name, [".$", ".-", ".__", ".Protocol."]) or
      String.starts_with?(name, "Elixir.JSON.Encoder.") or
      String.starts_with?(name, "Elixir.Jason.Encoder.") or
      String.starts_with?(name, "Elixir.Inspect.") or
      String.starts_with?(name, "Elixir.Collectable.") or
      String.starts_with?(name, "Elixir.Enumerable.") or
      String.starts_with?(name, "Elixir.String.Chars.")
  end

  @spec module_items(module_exports()) :: [Item.t()]
  defp module_items({module, functions}) do
    [module_item(module) | function_items(module, functions)]
  end

  @spec module_item(module()) :: Item.t()
  defp module_item(module) do
    %Item{
      id: {:module, module},
      label: inspect(module),
      description: "Module documentation",
      annotation: "module"
    }
  end

  @spec public_functions(module()) :: [{atom(), arity_t()}]
  defp public_functions(module) do
    module.__info__(:functions)
    |> Enum.reject(&internal_function?/1)
    |> Enum.sort()
  end

  @spec function_items(module(), [{atom(), arity_t()}]) :: [Item.t()]
  defp function_items(module, functions) do
    Enum.map(functions, fn {function, arity} -> function_item(module, function, arity) end)
  end

  @spec internal_function?({atom(), arity_t()}) :: boolean()
  defp internal_function?({function, _arity}) do
    function
    |> Atom.to_string()
    |> String.starts_with?("__")
  end

  @spec function_item(module(), atom(), arity_t()) :: Item.t()
  defp function_item(module, function, arity) do
    %Item{
      id: {:function, module, function, arity},
      label: "#{inspect(module)}.#{function}/#{arity}",
      description: "Function documentation",
      annotation: "function"
    }
  end
end
