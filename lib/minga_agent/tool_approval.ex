defmodule MingaAgent.ToolApproval do
  @moduledoc """
  Pending tool approval data.

  When a tool requires user confirmation before execution, this struct
  captures the tool call identity and the reply-to PID for the blocked
  Task process. Flows from `Agent.Session` through editor state, input
  handling, chat decorations, and GUI protocol encoding.
  """

  alias MingaAgent.ToolRouter

  @typedoc "Structured preview kind for an approval card."
  @type preview_kind :: :diff | :command | :target | :args

  @typedoc "A public, editor-safe approval preview."
  @type preview :: %{
          kind: preview_kind(),
          summary: String.t(),
          lines: [String.t()]
        }

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
            preview: %{kind: :args, summary: "", lines: []},
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
    cwd = Map.get(args, "cwd") || Map.get(args, "working_directory") || File.cwd!()

    %{
      kind: :command,
      summary: truncate(command, 120),
      lines: ["$ #{command}", "cwd: #{cwd}"]
    }
  end

  defp do_build_preview("write_file", %{"path" => path} = args) when is_binary(path) do
    content = Map.get(args, "content", "") |> to_string()
    before = read_existing(path)
    lines = diff_preview_lines(before, content)

    %{
      kind: :diff,
      summary: path,
      lines: ["file: #{path}" | lines]
    }
  end

  defp do_build_preview(name, %{"path" => path} = args)
       when name in ["edit_file", "multi_edit_file"] do
    %{
      kind: :target,
      summary: path,
      lines: ["file: #{path}", edit_summary(name, args)]
    }
  end

  defp do_build_preview(name, %{"paths" => paths})
       when is_list(paths) and name in ["git_stage"] do
    joined = Enum.map_join(paths, ", ", &to_string/1)

    %{
      kind: :target,
      summary: joined,
      lines: ["paths: #{joined}"]
    }
  end

  defp do_build_preview("git_commit", %{"message" => message}) do
    %{
      kind: :target,
      summary: message,
      lines: ["commit message: #{message}"]
    }
  end

  defp do_build_preview(_name, args) when map_size(args) == 0 do
    %{kind: :args, summary: "", lines: []}
  end

  defp do_build_preview(_name, args) do
    summary = inspect(args, limit: 20, printable_limit: 120)
    %{kind: :args, summary: summary, lines: [summary]}
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
    |> Enum.reject(&(&1 == "+" or &1 == "-"))
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
    old_text = Map.get(args, "old_text") || Map.get(args, "find") || ""
    new_text = Map.get(args, "new_text") || Map.get(args, "replace") || ""
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

  @spec truncate(String.t(), non_neg_integer()) :: String.t()
  defp truncate(text, max_len) when is_binary(text) do
    if String.length(text) > max_len do
      String.slice(text, 0, max_len - 3) <> "..."
    else
      text
    end
  end
end
