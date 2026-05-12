defmodule Minga.Help.Docs do
  @moduledoc """
  Formats loaded module and function documentation as markdown for the help buffer.
  """

  @type arity_t :: non_neg_integer()
  @type docs_result :: {:ok, docs_payload()} | :error
  @type docs_payload :: %{
          required(:format) => String.t(),
          required(:moduledoc) => doc_content(),
          required(:docs) => [doc_entry()]
        }
  @type doc_content :: map() | String.t() | :none | :hidden | nil
  @type doc_entry :: {doc_id(), term(), [String.t()], doc_content(), map()}
  @type doc_id :: {:function | :macro | :callback | :macrocallback, atom(), arity_t()}
  @type spec_entry :: {{atom(), arity_t()}, [tuple()]}

  @no_docs "No documentation available"

  @doc "Formats the moduledoc for `module` as markdown."
  @spec format_module(module()) :: String.t()
  def format_module(module) when is_atom(module) do
    with {:ok, %{format: "text/markdown", moduledoc: moduledoc}} <- fetch_docs(module),
         {:ok, doc} <- doc_text(moduledoc) do
      ["# #{inspect(module)}", "", doc]
      |> Enum.join("\n")
      |> ensure_trailing_newline()
    else
      _ -> @no_docs
    end
  end

  @doc "Formats the docs, signature, and specs for `module.function/arity` as markdown."
  @spec format_function(module(), atom(), arity_t()) :: String.t()
  def format_function(module, function, arity)
      when is_atom(module) and is_atom(function) and is_integer(arity) and arity >= 0 do
    with {:ok, %{format: "text/markdown", docs: docs}} <- fetch_docs(module),
         {:ok, {_id, _line, signatures, doc, _metadata}} <-
           find_function_doc(docs, function, arity),
         {:ok, doc_text} <- doc_text(doc) do
      [
        "# #{inspect(module)}.#{function}/#{arity}",
        "",
        signature_block(module, function, signatures),
        "",
        spec_block(module, function, arity),
        "",
        doc_text
      ]
      |> Enum.join("\n")
      |> ensure_trailing_newline()
    else
      _ -> @no_docs
    end
  end

  @spec fetch_docs(module()) :: docs_result()
  defp fetch_docs(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _anno, _language, format, moduledoc, _metadata, docs} ->
        {:ok, %{format: format, moduledoc: moduledoc, docs: docs}}

      _ ->
        :error
    end
  end

  @spec find_function_doc([doc_entry()], atom(), arity_t()) :: {:ok, doc_entry()} | :error
  defp find_function_doc(docs, function, arity) do
    case Enum.find(docs, &function_doc?(&1, function, arity)) do
      nil -> :error
      doc -> {:ok, doc}
    end
  end

  @spec function_doc?(doc_entry(), atom(), arity_t()) :: boolean()
  defp function_doc?(
         {{:function, function, arity}, _line, _signatures, _doc, _metadata},
         function,
         arity
       ),
       do: true

  defp function_doc?(_entry, _function, _arity), do: false

  @spec doc_text(doc_content()) :: {:ok, String.t()} | :error
  defp doc_text(%{"en" => doc}) when is_binary(doc), do: {:ok, doc}
  defp doc_text(doc) when is_binary(doc), do: {:ok, doc}
  defp doc_text(_doc), do: :error

  @spec signature_block(module(), atom(), [String.t()]) :: String.t()
  defp signature_block(module, function, signatures) do
    signatures
    |> module_qualified_signatures(module, function)
    |> fenced_elixir()
  end

  @spec module_qualified_signatures([String.t()], module(), atom()) :: [String.t()]
  defp module_qualified_signatures([], module, function),
    do: ["#{inspect(module)}.#{function}(...)"]

  defp module_qualified_signatures(signatures, module, _function) do
    Enum.map(signatures, fn signature -> "#{inspect(module)}.#{signature}" end)
  end

  @spec spec_block(module(), atom(), arity_t()) :: String.t()
  defp spec_block(module, function, arity) do
    case specs(module, function, arity) do
      [] -> "No @spec available"
      specs -> fenced_elixir(specs)
    end
  end

  @spec specs(module(), atom(), arity_t()) :: [String.t()]
  defp specs(module, function, arity) do
    case Code.Typespec.fetch_specs(module) do
      {:ok, specs} -> format_matching_specs(specs, function, arity)
      _ -> []
    end
  end

  @spec format_matching_specs([spec_entry()], atom(), arity_t()) :: [String.t()]
  defp format_matching_specs(specs, function, arity) do
    specs
    |> Enum.filter(fn {{name, spec_arity}, _specs} ->
      name == function and spec_arity == arity
    end)
    |> Enum.flat_map(fn {{name, _spec_arity}, spec_list} ->
      Enum.map(spec_list, fn spec ->
        "@spec #{Macro.to_string(Code.Typespec.spec_to_quoted(name, spec))}"
      end)
    end)
  end

  @spec fenced_elixir([String.t()]) :: String.t()
  defp fenced_elixir(lines) do
    ["```elixir", Enum.join(lines, "\n"), "```"]
    |> Enum.join("\n")
  end

  @spec ensure_trailing_newline(String.t()) :: String.t()
  defp ensure_trailing_newline(content) do
    if String.ends_with?(content, "\n"), do: content, else: content <> "\n"
  end
end
