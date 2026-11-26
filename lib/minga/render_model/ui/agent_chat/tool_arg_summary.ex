defmodule Minga.RenderModel.UI.AgentChat.ToolArgSummary do
  @moduledoc """
  Shared one-line summaries for agent tool arguments.

  Builders resolve tool calls into semantic `AgentChat.ToolCallView` structs before encoding. Keeping argument summaries here prevents the builder and adapter encoder from growing parallel tool-name tables.
  """

  @doc "A one-line summary of a tool's arguments, always text: a model can send any JSON for an argument, and a value that is not text names nothing."
  @spec summarize(String.t(), map()) :: String.t()
  def summarize(name, args) do
    case raw_summary(name, args) do
      text when is_binary(text) -> text
      _other -> ""
    end
  end

  @spec raw_summary(String.t(), map()) :: term()
  defp raw_summary("ask_user", _args), do: "Clarification"
  defp raw_summary("shell", %{"command" => cmd}), do: cmd
  defp raw_summary("shell", %{command: cmd}), do: cmd
  defp raw_summary("read_file", %{"path" => path}), do: path
  defp raw_summary("read_file", %{path: path}), do: path
  defp raw_summary("list_directory", %{"path" => path}), do: path
  defp raw_summary("list_directory", %{path: path}), do: path
  defp raw_summary("write_file", %{"path" => path}), do: path
  defp raw_summary("write_file", %{path: path}), do: path
  defp raw_summary("edit_file", %{"path" => path}), do: path
  defp raw_summary("edit_file", %{path: path}), do: path
  defp raw_summary("delete_file", %{"path" => path}), do: path
  defp raw_summary("delete_file", %{path: path}), do: path

  defp raw_summary("find", %{"name" => name, "path" => path}), do: located(name, path)
  defp raw_summary("find", %{name: name, path: path}), do: located(name, path)
  defp raw_summary("find", %{"pattern" => pattern, "path" => path}), do: located(pattern, path)
  defp raw_summary("find", %{pattern: pattern, path: path}), do: located(pattern, path)
  defp raw_summary("find", %{"pattern" => pattern}), do: pattern
  defp raw_summary("find", %{pattern: pattern}), do: pattern
  defp raw_summary("find", %{"name" => name}), do: name
  defp raw_summary("find", %{name: name}), do: name
  defp raw_summary("find", %{"path" => path}), do: path
  defp raw_summary("find", %{path: path}), do: path

  defp raw_summary("grep", %{"pattern" => pattern, "path" => path}), do: located(pattern, path)
  defp raw_summary("grep", %{pattern: pattern, path: path}), do: located(pattern, path)
  defp raw_summary("grep", %{"query" => query, "path" => path}), do: located(query, path)
  defp raw_summary("grep", %{query: query, path: path}), do: located(query, path)
  defp raw_summary("grep", %{"pattern" => pattern}), do: pattern
  defp raw_summary("grep", %{pattern: pattern}), do: pattern
  defp raw_summary("grep", %{"query" => query}), do: query
  defp raw_summary("grep", %{query: query}), do: query

  defp raw_summary("subagent", %{"task" => task}), do: task
  defp raw_summary("subagent", %{task: task}), do: task

  defp raw_summary("git_stage", %{"paths" => paths}) when is_list(paths), do: listed(paths)
  defp raw_summary("git_stage", %{paths: paths}) when is_list(paths), do: listed(paths)

  defp raw_summary("git_commit", %{"message" => msg}), do: msg
  defp raw_summary("git_commit", %{message: msg}), do: msg
  defp raw_summary(_name, args) when map_size(args) == 0, do: ""

  # Any other tool reads as its plain arguments, never as an Elixir map: one
  # argument is its value, several are `key: value` pairs. Nested values are left out.
  defp raw_summary(_name, args) do
    case args |> Enum.sort_by(&to_string(elem(&1, 0))) |> Enum.flat_map(&plain_arg/1) do
      [{_key, value}] -> value
      pairs -> Enum.map_join(pairs, ", ", fn {key, value} -> "#{key}: #{value}" end)
    end
  end

  # What was looked for and where. A place that is not text is left out; a
  # subject that is not text names nothing.
  @spec located(term(), term()) :: String.t() | nil
  defp located(what, where) when is_binary(what) and is_binary(where), do: what <> " in " <> where
  defp located(what, _where) when is_binary(what), do: what
  defp located(_what, _where), do: nil

  @spec listed([term()]) :: String.t() | nil
  defp listed(items) do
    if Enum.all?(items, &is_binary/1), do: Enum.join(items, ", ")
  end

  @spec plain_arg({atom() | String.t(), term()}) :: [{String.t(), String.t()}]
  defp plain_arg({_key, nil}), do: []
  defp plain_arg({key, value}) when is_binary(value), do: [{to_string(key), value}]

  defp plain_arg({key, value}) when is_number(value) or is_boolean(value) or is_atom(value),
    do: [{to_string(key), to_string(value)}]

  defp plain_arg({key, values}) when is_list(values) do
    if values != [] and Enum.all?(values, &is_binary/1),
      do: [{to_string(key), Enum.join(values, ", ")}],
      else: []
  end

  defp plain_arg(_nested), do: []
end
