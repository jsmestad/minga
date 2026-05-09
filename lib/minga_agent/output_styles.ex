defmodule MingaAgent.OutputStyles do
  @moduledoc """
  Discovers and formats agent output style files.

  Style files live in `~/.config/minga/output-styles/` and `.minga/output-styles/` under the project root. Each regular file is a style; its name is the filename stem and its entire trimmed contents are prepended to the agent system prompt when selected. Project styles override global styles with the same filename stem.
  """

  alias MingaAgent.OutputStyle

  @global_output_styles_dir "~/.config/minga/output-styles"
  @project_output_styles_dir ".minga/output-styles"

  @typedoc "Discovery options."
  @type discover_opt :: {:global_dir, String.t()}

  @doc "Discovers output styles, with project styles overriding global styles of the same name."
  @spec discover(String.t() | nil, [discover_opt()]) :: [OutputStyle.t()]
  def discover(project_root \\ nil, opts \\ []) do
    global_dir = Keyword.get(opts, :global_dir, expand_global_dir())
    global = discover_in(global_dir, :global)

    project =
      if project_root do
        discover_in(Path.join(project_root, @project_output_styles_dir), :project)
      else
        []
      end

    (global ++ project)
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {_name, styles} -> List.last(styles) end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Finds a style by name in a previously discovered list."
  @spec find([OutputStyle.t()], String.t()) :: {:ok, OutputStyle.t()} | :not_found
  def find(styles, name) when is_list(styles) and is_binary(name) do
    case Enum.find(styles, &(&1.name == name)) do
      nil -> :not_found
      %OutputStyle{} = style -> {:ok, style}
    end
  end

  @doc "Formats the selected style for prepending to the system prompt."
  @spec format_for_prompt(OutputStyle.t() | nil) :: String.t() | nil
  def format_for_prompt(nil), do: nil

  def format_for_prompt(%OutputStyle{name: name, body: body}) do
    "## Output Style: #{name}\n\n#{String.trim(body)}"
  end

  @doc "Returns a human-readable list of available styles and the current selection."
  @spec summary([OutputStyle.t()], String.t() | nil) :: String.t()
  def summary(styles, current_name) do
    current = current_name || "none"

    if styles == [] do
      "Current style: #{current}\n\nNo output styles found. Create files in ~/.config/minga/output-styles/ or .minga/output-styles/."
    else
      lines = Enum.map_join(styles, "\n", &format_style_line(&1, current_name))

      "Current style: #{current}\n\nAvailable styles:\n#{lines}\n\nUse /style <name> to select one, or /style none to clear."
    end
  end

  @doc "Formats style names for error messages."
  @spec available_names([OutputStyle.t()]) :: String.t()
  def available_names([]), do: "none"

  def available_names(styles) do
    Enum.map_join(styles, ", ", & &1.name)
  end

  @spec discover_in(String.t(), OutputStyle.source()) :: [OutputStyle.t()]
  defp discover_in(dir, source) do
    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.flat_map(&try_load_style(dir, &1, source))
    else
      []
    end
  end

  @spec try_load_style(String.t(), String.t(), OutputStyle.source()) :: [OutputStyle.t()]
  defp try_load_style(dir, entry, source) do
    path = Path.join(dir, entry)

    if File.regular?(path) do
      case File.read(path) do
        {:ok, body} -> build_style(path, body, source)
        {:error, _reason} -> []
      end
    else
      []
    end
  end

  @spec build_style(String.t(), String.t(), OutputStyle.source()) :: [OutputStyle.t()]
  defp build_style(path, body, source) do
    trimmed = String.trim(body)

    if trimmed == "" do
      []
    else
      [
        %OutputStyle{
          name: style_name(path),
          body: trimmed,
          path: path,
          source: source
        }
      ]
    end
  end

  @spec style_name(String.t()) :: String.t()
  defp style_name(path) do
    path
    |> Path.basename()
    |> Path.rootname()
  end

  @spec format_style_line(OutputStyle.t(), String.t() | nil) :: String.t()
  defp format_style_line(%OutputStyle{} = style, current_name) do
    source_tag = if style.source == :project, do: " [project]", else: " [global]"
    current_tag = if style.name == current_name, do: " (current)", else: ""
    "  #{style.name}#{source_tag}#{current_tag}"
  end

  @spec expand_global_dir() :: String.t()
  defp expand_global_dir do
    Path.expand(@global_output_styles_dir)
  end
end
