defmodule MingaAgent.Tools.DirectoryListing do
  @moduledoc """
  Formats bounded directory listings for agent tools.
  """

  alias MingaAgent.Tools.PathIgnore

  @max_entries 500

  @type entry :: %{name: String.t(), type: :directory | :file}

  @doc "Formats filesystem entries under `path` using bounded agent-friendly defaults."
  @spec from_filesystem(String.t(), [String.t()]) :: String.t()
  def from_filesystem(path, entries) when is_binary(path) and is_list(entries) do
    if ignored_root?(path) do
      ""
    else
      path
      |> PathIgnore.filter_child_names(entries)
      |> Enum.map(&filesystem_entry(path, &1))
      |> format_entries()
    end
  end

  @doc "Formats already-typed entries using bounded agent-friendly defaults."
  @spec format_entries([entry()]) :: String.t()
  def format_entries(entries) when is_list(entries) do
    entries
    |> Enum.reject(&PathIgnore.ignored_name?(&1.name))
    |> format_visible_entries()
  end

  @doc "Formats already-typed entries under `path` using static and project ignore rules."
  @spec format_entries(String.t(), [entry()]) :: String.t()
  def format_entries(path, entries) when is_binary(path) and is_list(entries) do
    if ignored_root?(path) do
      ""
    else
      visible_names =
        path |> PathIgnore.filter_child_names(Enum.map(entries, & &1.name)) |> MapSet.new()

      entries |> Enum.filter(&MapSet.member?(visible_names, &1.name)) |> format_visible_entries()
    end
  end

  @doc "Returns true when a path basename should be hidden from broad agent listings."
  @spec ignored_name?(String.t()) :: boolean()
  def ignored_name?(name) when is_binary(name), do: PathIgnore.ignored_name?(name)

  @doc "Returns basenames that broad agent filesystem tools should omit by default."
  @spec ignored_names() :: [String.t()]
  def ignored_names, do: PathIgnore.ignored_names()

  @spec ignored_root?(String.t()) :: boolean()
  defp ignored_root?(path) do
    PathIgnore.ignored_path?(path)
  end

  @spec filesystem_entry(String.t(), String.t()) :: entry()
  defp filesystem_entry(path, name) do
    type = if File.dir?(Path.join(path, name)), do: :directory, else: :file
    %{name: name, type: type}
  end

  @spec format_visible_entries([entry()]) :: String.t()
  defp format_visible_entries(entries) do
    {visible, hidden_count} =
      entries
      |> sort_entries()
      |> cap_entries()

    lines = Enum.map(visible, &format_entry/1)

    lines =
      if hidden_count > 0,
        do: Enum.concat(lines, ["... (truncated, #{hidden_count} more entries)"]),
        else: lines

    Enum.join(lines, "\n")
  end

  @spec sort_entries([entry()]) :: [entry()]
  defp sort_entries(entries) do
    Enum.sort_by(entries, fn %{name: name, type: type} ->
      {if(type == :directory, do: 0, else: 1), name}
    end)
  end

  @spec cap_entries([entry()]) :: {[entry()], non_neg_integer()}
  defp cap_entries(entries) do
    visible = Enum.take(entries, @max_entries)
    {visible, max(Enum.count(entries) - Enum.count(visible), 0)}
  end

  @spec format_entry(entry()) :: String.t()
  defp format_entry(%{name: name, type: :directory}), do: name <> "/"
  defp format_entry(%{name: name}), do: name
end
