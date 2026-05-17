defmodule Minga.Config.Completion do
  @moduledoc """
  Generates completion items for the Minga config DSL.

  Pure calculation module with no state. Produces `Completion.item()` maps
  from the `Config.Options` registry for use in the completion popup when
  editing `config.exs` or `.minga.exs`.

  Three categories of completions:

  1. **Option names** (`set :tab_width, ...`) with type and default as detail
  2. **Option values** (`set :theme, :doom_one`) for enum, boolean, and theme types
  3. **Filetype atoms** (`for_filetype :elixir, ...`) from `Minga.Language.Filetype`
  """

  alias Minga.Config.Options
  alias Minga.Language

  @typedoc "A completion item compatible with `Minga.Editing.Completion.item()`."
  @type item :: %{
          label: String.t(),
          kind: atom(),
          insert_text: String.t(),
          filter_text: String.t(),
          detail: String.t(),
          documentation: String.t(),
          sort_text: String.t(),
          text_edit: nil,
          raw: nil
        }

  @doc """
  Returns completion items for all config option names.

  Each item's label is the atom name (e.g., `:tab_width`), detail shows
  the type and default, and documentation provides a human-readable
  description of the option.
  """
  @spec option_name_items() :: [item()]
  def option_name_items do
    Options.option_specs()
    |> Enum.map(fn {name, type, default, description} ->
      name_str = Atom.to_string(name)

      %{
        label: ":#{name_str}",
        kind: :property,
        insert_text: ":#{name_str}",
        filter_text: name_str,
        detail: format_type(type),
        documentation: option_documentation(name, type, default, description),
        sort_text: name_str,
        text_edit: nil,
        raw: nil
      }
    end)
    |> Enum.sort_by(& &1.sort_text)
  end

  @doc """
  Returns completion items for valid values of the given option.

  Returns a non-empty list for enum types, booleans, and theme options.
  Returns `[]` for types without enumerable values (strings, integers).
  """
  @spec option_value_items(Options.option_name()) :: [item()]
  def option_value_items(option_name) when is_atom(option_name) do
    case Options.type_for(option_name) do
      {:enum, values} ->
        Enum.map(values, fn val ->
          val_str = Atom.to_string(val)
          default = Options.default(option_name)
          is_default = val == default

          %{
            label: ":#{val_str}",
            kind: :enum_member,
            insert_text: ":#{val_str}",
            filter_text: val_str,
            detail: if(is_default, do: "(default)", else: ""),
            documentation: "",
            sort_text: val_str,
            text_edit: nil,
            raw: nil
          }
        end)

      :boolean ->
        default = Options.default(option_name)

        Enum.map([true, false], fn val ->
          val_str = Atom.to_string(val)
          is_default = val == default

          %{
            label: val_str,
            kind: :value,
            insert_text: val_str,
            filter_text: val_str,
            detail: if(is_default, do: "(default)", else: ""),
            documentation: "",
            sort_text: val_str,
            text_edit: nil,
            raw: nil
          }
        end)

      :theme_atom ->
        default = Options.default(option_name)

        Minga.Config.ThemeRegistry.available()
        |> Enum.map(fn theme ->
          theme_str = Atom.to_string(theme)
          is_default = theme == default

          %{
            label: ":#{theme_str}",
            kind: :color,
            insert_text: ":#{theme_str}",
            filter_text: theme_str,
            detail: if(is_default, do: "(default)", else: ""),
            documentation: "",
            sort_text: theme_str,
            text_edit: nil,
            raw: nil
          }
        end)

      _ ->
        []
    end
  end

  def option_value_items(_unknown), do: []

  @doc """
  Returns completion items for known filetype atoms.

  Used when the cursor is after `for_filetype :` to suggest available
  filetypes like `:elixir`, `:go`, `:python`, etc.
  """
  @spec filetype_items() :: [item()]
  def filetype_items do
    filetypes =
      Language.all()
      |> Enum.map(& &1.name)
      |> Enum.sort()

    Enum.map(filetypes, fn ft ->
      ft_str = Atom.to_string(ft)
      extensions = extensions_for_filetype(ft)

      %{
        label: ":#{ft_str}",
        kind: :enum_member,
        insert_text: ":#{ft_str}",
        filter_text: ft_str,
        detail: extensions,
        documentation: "",
        sort_text: ft_str,
        text_edit: nil,
        raw: nil
      }
    end)
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  @spec format_type(Options.type_descriptor()) :: String.t()
  defp format_type(:pos_integer), do: "positive integer"
  defp format_type(:non_neg_integer), do: "non-negative integer"
  defp format_type(:integer), do: "integer"
  defp format_type(:boolean), do: "boolean"
  defp format_type(:atom), do: "atom"
  defp format_type(:string), do: "string"
  defp format_type(:string_or_nil), do: "string or nil"
  defp format_type(:string_list), do: "list of strings"
  defp format_type(:atom_list), do: "list of atoms"
  defp format_type(:map_or_nil), do: "map or nil"
  defp format_type(:map_list), do: "list of maps"
  defp format_type(:float_or_nil), do: "float or nil"
  defp format_type(:theme_atom), do: "theme"
  defp format_type(:any), do: "any"
  defp format_type({:enum, values}), do: Enum.map_join(values, " | ", &inspect/1)

  @spec option_documentation(atom(), Options.type_descriptor(), term(), String.t()) :: String.t()
  defp option_documentation(_name, type, default, description) do
    type_line = "**Type:** #{format_type(type)}"
    default_line = "**Default:** `#{inspect(default)}`"

    lines = [description, "", type_line, default_line]
    Enum.join(lines, "\n")
  end

  @spec extensions_for_filetype(atom()) :: String.t()
  defp extensions_for_filetype(filetype) do
    case Language.get(filetype) do
      nil ->
        ""

      lang ->
        lang.extensions
        |> Enum.map(&".#{&1}")
        |> Enum.sort()
        |> Enum.take(4)
        |> Enum.join(", ")
    end
  end
end
