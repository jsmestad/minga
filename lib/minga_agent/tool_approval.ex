defmodule MingaAgent.ToolApproval do
  @moduledoc """
  Pending tool approval data.

  When a tool requires user confirmation before execution, this struct
  captures the tool call identity and the reply-to PID for the blocked
  Task process. Flows from `Agent.Session` through editor state, input
  handling, chat decorations, and GUI protocol encoding.
  """

  alias Minga.RenderModel.UI.AgentChat.ToolArgSummary
  alias MingaAgent.ToolApproval.Preview
  alias MingaAgent.ToolApproval.Public
  alias MingaAgent.ToolApproval.Target
  alias MingaAgent.ToolRouter

  @typedoc "Structured preview kind for an approval card."
  @type preview_kind :: Preview.kind()

  @typedoc "A public, editor-safe approval preview."
  @type preview :: Preview.t()

  # The most bytes of a command one preview line carries.
  @command_preview_bytes 16_000

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
      preview: build_preview(name, args, Keyword.get(opts, :working_directory)),
      reply_to: Keyword.get(opts, :reply_to)
    }
  end

  @doc "Builds a complete editor-safe approval bound to the displayed target."
  @spec public(t(), Target.t()) :: Public.t()
  def public(
        %__MODULE__{tool_call_id: tool_call_id} = approval,
        %Target{tool_call_id: tool_call_id} = target
      ) do
    Public.new(target, approval.name, approval.args, approval.preview)
  end

  @doc """
  Builds the structured preview shown in inline approval cards.

  `working_directory` is the session's folder, where a shell command runs. The command's arguments never name it: an argument the tool ignores must not decide what the person is shown.
  """
  @spec build_preview(String.t(), map(), String.t() | nil) :: preview()
  def build_preview(name, args, working_directory \\ nil) when is_binary(name) and is_map(args) do
    name
    |> do_build_preview(stringify_keys(args))
    |> with_working_directory(name, working_directory)
  end

  @spec with_working_directory(preview(), String.t(), String.t() | nil) :: preview()
  defp with_working_directory(%Preview{kind: :command} = preview, "shell", directory)
       when is_binary(directory),
       do: Preview.new(:command, preview.summary, preview.lines ++ ["cwd: #{directory}"])

  defp with_working_directory(preview, _name, _directory), do: preview

  @doc "Builds an IO-free structured preview for completed transcript tool-call cards."
  @spec build_transcript_preview(String.t(), map()) :: preview()
  def build_transcript_preview(name, args) when is_binary(name) and is_map(args) do
    do_build_transcript_preview(name, stringify_keys(args))
  end

  @doc "Builds an IO-free diff preview from explicit before/after file content."
  @spec build_file_diff_preview(String.t(), String.t(), String.t()) :: preview()
  def build_file_diff_preview(path, before_content, after_content)
      when is_binary(path) and is_binary(before_content) and is_binary(after_content) do
    Preview.new(
      :diff,
      path,
      preview_lines(["file: #{path}" | diff_preview_lines(before_content, after_content)])
    )
  end

  @spec do_build_preview(String.t(), map()) :: preview()
  defp do_build_preview("shell", %{"command" => command}) do
    command = stringify_value(command)
    Preview.new(:command, command, command_preview_lines(command))
  end

  defp do_build_preview("write_file", %{"path" => path} = args) when is_binary(path) do
    content = stringify_value(Map.get(args, "content", ""))
    before = read_existing(path)
    lines = diff_preview_lines(before, content)

    Preview.new(:diff, path, preview_lines(["file: #{path}" | lines]))
  end

  defp do_build_preview(name, args)
       when name in ["read_file", "grep", "find", "list_directory"] do
    read_only_preview(name, args)
  end

  defp do_build_preview("edit_file", %{"path" => path} = args) do
    path = stringify_value(path)
    lines = edit_diff_preview_lines(Map.get(args, "edits", []))

    Preview.new(:diff, path, preview_lines(["file: #{path}" | lines]))
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

  @spec do_build_transcript_preview(String.t(), map()) :: preview()
  # A finished step is context, not a decision: it keeps a bounded sample of its command.
  # Every shell row of a resident transcript carries this line, so it stays short.
  defp do_build_transcript_preview("shell", %{"command" => command}) do
    command = stringify_value(command)
    Preview.new(:command, command, preview_lines(["$ #{command}"]))
  end

  defp do_build_transcript_preview("write_file", %{"path" => path}) do
    path = stringify_value(path)
    Preview.new(:target, path, [])
  end

  defp do_build_transcript_preview(name, args)
       when name in ["read_file", "grep", "find", "list_directory"] do
    read_only_preview(name, args)
  end

  defp do_build_transcript_preview(name, args) do
    name
    |> do_build_preview(args)
    |> transcript_safe_preview()
  end

  @spec read_only_preview(String.t(), map()) :: preview()
  defp read_only_preview(name, args) do
    summary = name |> ToolArgSummary.summarize(args) |> stringify_value()
    Preview.new(:args, summary, [])
  end

  @spec transcript_safe_preview(preview()) :: preview()
  defp transcript_safe_preview(%Preview{kind: :args, summary: summary}),
    do: Preview.new(:args, summary, [])

  defp transcript_safe_preview(%Preview{} = preview), do: preview

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

  @spec edit_diff_preview_lines(term()) :: [String.t()]
  defp edit_diff_preview_lines(edits) when is_list(edits) do
    edits
    |> Enum.flat_map(&edit_entry_diff_preview_lines/1)
    |> Enum.reject(&(&1 == "No textual changes detected"))
    |> case do
      [] -> ["No textual changes detected"]
      lines -> Enum.take(lines, 20)
    end
  end

  defp edit_diff_preview_lines(_edits), do: ["No textual changes detected"]

  @spec edit_entry_diff_preview_lines(term()) :: [String.t()]
  defp edit_entry_diff_preview_lines(edit) when is_map(edit) do
    edit = stringify_keys(edit)
    old_text = stringify_value(Map.get(edit, "old_text", ""))
    new_text = stringify_value(Map.get(edit, "new_text", ""))
    diff_preview_lines(old_text, new_text)
  end

  defp edit_entry_diff_preview_lines(_edit), do: []

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

  # A command is the decision itself, so its preview is the whole command, never a sample.
  # The bound keeps one preview line inside the wire's 16-bit string; a command over it says how much it leaves out.
  @spec command_preview_lines(String.t()) :: [String.t()]
  defp command_preview_lines(command) when byte_size(command) <= @command_preview_bytes,
    do: ["$ " <> command]

  defp command_preview_lines(command) do
    shown = command |> binary_part(0, @command_preview_bytes) |> valid_prefix()
    rest = binary_part(command, byte_size(shown), byte_size(command) - byte_size(shown))
    ["$ " <> shown, "… #{String.length(rest)} more characters are not shown"]
  end

  # The longest prefix that is whole characters: a cut at a byte count can land inside one.
  @spec valid_prefix(binary()) :: String.t()
  defp valid_prefix(bytes) do
    case :unicode.characters_to_binary(bytes) do
      valid when is_binary(valid) -> valid
      {_incomplete_or_error, valid, _rest} -> valid
    end
  end

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
