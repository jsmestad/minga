defmodule MingaEditor.UI.Prompt.ProjectAdd do
  @moduledoc """
  Prompt handler for adding a directory to the known-projects list.

  Opens a text input defaulting to the current working directory. Supports
  shell-style Tab completion for directory paths and `~` expansion.
  """

  @behaviour MingaEditor.UI.Prompt.Handler

  alias MingaEditor.State, as: EditorState
  alias Minga.Project

  @impl true
  @spec label() :: String.t()
  def label, do: "Add project: "

  @impl true
  @spec on_submit(String.t(), EditorState.t()) :: EditorState.t()
  def on_submit(text, state) do
    path = text |> String.trim() |> expand_home() |> Path.expand()

    cond do
      path == "" ->
        EditorState.set_status(state, "No path given")

      not File.dir?(path) ->
        EditorState.set_status(state, "Not a directory: #{path}")

      true ->
        Project.add(path)
        EditorState.set_status(state, "Added project: #{path}")
    end
  end

  @impl true
  @spec on_cancel(EditorState.t()) :: EditorState.t()
  def on_cancel(state), do: state

  @impl true
  @spec on_tab(String.t()) :: String.t()
  def on_tab(text) do
    expanded = expand_home(text)
    dir = Path.dirname(expanded)
    prefix = Path.basename(expanded)

    if expanded == "" or String.ends_with?(expanded, "/") do
      complete_in_dir(expanded, "")
    else
      complete_in_dir(dir, prefix)
    end
    |> collapse_home()
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  @spec complete_in_dir(String.t(), String.t()) :: String.t()
  defp complete_in_dir(dir, prefix) do
    abs_dir = Path.expand(dir)

    case File.ls(abs_dir) do
      {:ok, entries} ->
        matches =
          entries
          |> Enum.filter(&String.starts_with?(&1, prefix))
          |> Enum.map(&Path.join(abs_dir, &1))
          |> Enum.filter(&File.dir?/1)

        case matches do
          [single] -> single <> "/"
          [_ | _] -> longest_common_prefix(matches)
          [] -> Path.join(abs_dir, prefix)
        end

      {:error, _} ->
        Path.join(dir, prefix)
    end
  end

  @spec longest_common_prefix([String.t()]) :: String.t()
  defp longest_common_prefix([first | rest]) do
    Enum.reduce(rest, first, fn str, acc ->
      acc
      |> String.graphemes()
      |> Enum.zip(String.graphemes(str))
      |> Enum.take_while(fn {a, b} -> a == b end)
      |> Enum.map_join(&elem(&1, 0))
    end)
  end

  @spec expand_home(String.t()) :: String.t()
  defp expand_home("~" <> rest), do: Path.expand("~") <> rest
  defp expand_home(path), do: path

  @spec collapse_home(String.t()) :: String.t()
  defp collapse_home(path) do
    home = Path.expand("~")

    if String.starts_with?(path, home <> "/") do
      "~" <> String.trim_leading(path, home)
    else
      path
    end
  end
end
