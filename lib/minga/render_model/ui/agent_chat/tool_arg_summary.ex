defmodule Minga.RenderModel.UI.AgentChat.ToolArgSummary do
  @moduledoc """
  Shared one-line summaries for agent tool arguments.

  Builders resolve tool calls into semantic `AgentChat.ToolCallView` structs before encoding. Keeping argument summaries here prevents the builder and adapter encoder from growing parallel tool-name tables.
  """

  @spec summarize(String.t(), map()) :: String.t()
  def summarize("shell", %{"command" => cmd}), do: cmd
  def summarize("shell", %{command: cmd}), do: cmd
  def summarize("read_file", %{"path" => path}), do: path
  def summarize("read_file", %{path: path}), do: path
  def summarize("list_directory", %{"path" => path}), do: path
  def summarize("list_directory", %{path: path}), do: path
  def summarize("write_file", %{"path" => path}), do: path
  def summarize("write_file", %{path: path}), do: path
  def summarize("edit_file", %{"path" => path}), do: path
  def summarize("edit_file", %{path: path}), do: path
  def summarize("multi_edit_file", %{"path" => path}), do: path
  def summarize("multi_edit_file", %{path: path}), do: path
  def summarize("apply_diff", %{"path" => path}), do: path
  def summarize("apply_diff", %{path: path}), do: path
  def summarize("delete_file", %{"path" => path}), do: path
  def summarize("delete_file", %{path: path}), do: path

  def summarize("find", %{"name" => name, "path" => path}), do: "#{name} in #{path}"
  def summarize("find", %{name: name, path: path}), do: "#{name} in #{path}"
  def summarize("find", %{"pattern" => pattern, "path" => path}), do: "#{pattern} in #{path}"
  def summarize("find", %{pattern: pattern, path: path}), do: "#{pattern} in #{path}"
  def summarize("find", %{"path" => path}), do: path
  def summarize("find", %{path: path}), do: path

  def summarize("grep", %{"pattern" => pattern, "path" => path}), do: "#{pattern} in #{path}"
  def summarize("grep", %{pattern: pattern, path: path}), do: "#{pattern} in #{path}"
  def summarize("grep", %{"query" => query, "path" => path}), do: "#{query} in #{path}"
  def summarize("grep", %{query: query, path: path}), do: "#{query} in #{path}"

  def summarize("git_stage", %{"paths" => paths}) when is_list(paths),
    do: Enum.join(paths, ", ")

  def summarize("git_stage", %{paths: paths}) when is_list(paths),
    do: Enum.join(paths, ", ")

  def summarize("git_commit", %{"message" => msg}), do: msg
  def summarize("git_commit", %{message: msg}), do: msg
  def summarize(_name, args) when map_size(args) == 0, do: ""
  def summarize(_name, args), do: inspect(args, limit: 80)
end
