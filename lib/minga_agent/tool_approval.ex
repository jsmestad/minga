defmodule MingaAgent.ToolApproval do
  @moduledoc """
  Pending tool approval data.

  When a tool requires user confirmation before execution, this struct
  captures the tool call identity and the reply-to PID for the blocked
  Task process. Flows from `Agent.Session` through editor state, input
  handling, chat decorations, and GUI protocol encoding.
  """

  alias MingaAgent.ToolApproval.Preview
  alias MingaAgent.ToolRouter

  @typedoc "Structured preview kind for an approval card."
  @type preview_kind :: Preview.kind()

  @typedoc "A public, editor-safe approval preview."
  @type preview :: Preview.t()

  @typedoc "A pending tool approval."
  @type t :: %__MODULE__{
          tool_call_id: String.t(),
          name: String.t(),
          args: map(),
          preview: preview(),
          reply_to: pid() | nil
        }

  @enforce_keys [:tool_call_id, :name, :preview]
  defstruct tool_call_id: nil,
            name: nil,
            args: %{},
            preview: %Preview{kind: :args, summary: "", lines: []},
            reply_to: nil

  @doc "Creates a pending approval with a structured preview card."
  @spec new(keyword()) :: t()
  def new(opts) do
    name = Keyword.fetch!(opts, :name)
    args = Keyword.get(opts, :args, %{})

    %__MODULE__{
      tool_call_id: Keyword.fetch!(opts, :tool_call_id),
      name: name,
      args: args,
      preview: build_preview(name, args),
      reply_to: Keyword.get(opts, :reply_to)
    }
  end

  @doc "Returns an editor-safe map without the private reply PID."
  @spec public(t()) :: map()
  def public(%__MODULE__{} = approval) do
    %{
      tool_call_id: approval.tool_call_id,
      name: approval.name,
      args: approval.args,
      preview: approval.preview
    }
  end

  @doc "Builds the structured preview shown in inline approval cards."
  @spec build_preview(String.t(), map()) :: preview()
  def build_preview(name, args) when is_binary(name) and is_map(args) do
    do_build_preview(name, stringify_keys(args))
  end

  @spec do_build_preview(String.t(), map()) :: preview()
  defp do_build_preview("shell", %{"command" => command} = args) do
    command = stringify_value(command)

    cwd =
      stringify_value(Map.get(args, "cwd") || Map.get(args, "working_directory") || File.cwd!())

    Preview.new(:command, command, preview_lines(["$ #{command}", "cwd: #{cwd}"]))
  end

  defp do_build_preview("write_file", %{"path" => path} = args) when is_binary(path) do
    content = stringify_value(Map.get(args, "content", ""))
    before = read_existing(path)
    lines = diff_preview_lines(before, content)

    Preview.new(:diff, path, preview_lines(["file: #{path}" | lines]))
  end

  defp do_build_preview(name, %{"path" => path} = args)
       when name in ["edit_file", "multi_edit_file"] do
    path = stringify_value(path)

    Preview.new(:target, path, preview_lines(["file: #{path}", edit_summary(name, args)]))
  end

  defp do_build_preview(name, %{"paths" => paths})
       when is_list(paths) and name in ["git_stage"] do
    joined = Enum.map_join(paths, ", ", &stringify_value/1)

    Preview.new(:target, joined, preview_lines(["paths: #{joined}"]))
  end

  defp do_build_preview("git_commit", %{"message" => message}) do
    message = stringify_value(message)

    Preview.new(:target, message, preview_lines(["commit message: #{message}"]))
  end

  defp do_build_preview(_name, args) when map_size(args) == 0 do
    Preview.new(:args, "", [])
  end

  defp do_build_preview(_name, args) do
    summary = inspect(args, limit: 20, printable_limit: 120)
    Preview.new(:args, summary, [summary])
  end

  @spec read_existing(String.t()) :: String.t()
  defp read_existing(path) do
    case ToolRouter.read_file(ToolRouter.context(nil, nil), path) do
      {:ok, content} -> content
      _ -> ""
    end
  end

  @spec diff_preview_lines(String.t(), String.t()) :: [String.t()]
  defp diff_preview_lines(before, after_text) do
    before_lines = String.split(before, "\n")
    after_lines = String.split(after_text, "\n")

    before_lines
    |> List.myers_difference(after_lines)
    |> Enum.flat_map(&diff_op_preview_lines/1)
    |> Enum.take(20)
    |> case do
      [] -> ["No textual changes detected"]
      lines -> lines
    end
  end

  @spec diff_op_preview_lines({:eq | :ins | :del, [String.t()]}) :: [String.t()]
  defp diff_op_preview_lines({:eq, _lines}), do: []
  defp diff_op_preview_lines({:ins, lines}), do: Enum.map(lines, &("+" <> &1))
  defp diff_op_preview_lines({:del, lines}), do: Enum.map(lines, &("-" <> &1))

  @spec edit_summary(String.t(), map()) :: String.t()
  defp edit_summary("edit_file", args) do
    old_text = stringify_value(Map.get(args, "old_text") || Map.get(args, "find") || "")
    new_text = stringify_value(Map.get(args, "new_text") || Map.get(args, "replace") || "")
    "replace #{inspect(truncate(old_text, 40))} with #{inspect(truncate(new_text, 40))}"
  end

  defp edit_summary("multi_edit_file", args) do
    edits = Map.get(args, "edits", [])
    count = if is_list(edits), do: length(edits), else: 0
    "#{count} edit(s)"
  end

  @spec stringify_keys(map()) :: map()
  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  @spec stringify_value(term()) :: String.t()
  defp stringify_value(value) when is_binary(value), do: value
  defp stringify_value(value), do: inspect(value, printable_limit: 120)

  @spec preview_lines([String.t()]) :: [String.t()]
  defp preview_lines(lines), do: Enum.map(lines, &truncate(&1, 300))

  @spec truncate(String.t(), non_neg_integer()) :: String.t()
  defp truncate(text, max_len) when is_binary(text) do
    if String.length(text) > max_len do
      String.slice(text, 0, max_len - 3) <> "..."
    else
      text
    end
  end
end
