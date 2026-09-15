defmodule Minga.Editing.Formatter do
  @moduledoc """
  Pipes buffer content through external formatters.

  Resolves the formatter command for a filetype (user config overrides
  defaults), runs the command with the buffer content on stdin, and
  returns the formatted output. If the command fails, returns an error
  without modifying the buffer.

  ## Formatter spec

  A formatter spec is a shell command string. The placeholder `{file}`
  is replaced with the buffer's file path (useful for formatters that
  need to know the filename for config resolution).

  ## Default formatters

      :elixir   → "mix format --stdin-filename {file} -"
      :go       → "gofmt"
      :rust     → "rustfmt --edition 2021"
      :python   → "python3 -m black --quiet -"
      :zig      → "zig fmt --stdin"
      :c / :cpp → "clang-format"
      :javascript / :typescript / :jsx / :tsx → "prettier --stdin-filepath {file}"
  """

  alias Minga.Config
  alias Minga.Editing.Formatter.Failure
  alias Minga.Editing.Formatter.Result
  alias Minga.Language

  @typedoc "A shell command string, optionally containing `{file}`."
  @type formatter_spec :: String.t()
  @type failure :: Failure.t() | {:subprocess, String.t()}

  @typep cleanup_owner :: {pid(), reference()}

  @line_separator ~r/(\r\n|\n)/

  @doc "Returns the default formatter map (filetype atom to command string)."
  @spec default_formatters() :: %{atom() => formatter_spec()}
  def default_formatters do
    Language.all()
    |> Enum.filter(fn lang -> lang.formatter != nil end)
    |> Map.new(fn lang -> {lang.name, lang.formatter} end)
  end

  @doc """
  Resolves the formatter command for a filetype.

  Checks user config (`:formatter` option with filetype override) first,
  then falls back to the built-in default. Returns `nil` if no formatter
  is configured for the filetype.
  """
  @spec resolve_formatter(atom(), String.t() | nil) :: formatter_spec() | nil
  def resolve_formatter(filetype, file_path \\ nil) do
    user_formatter = Config.get_for_filetype(:formatter, filetype)

    default =
      case Language.get(filetype) do
        %{formatter: fmt} when is_binary(fmt) -> fmt
        _ -> nil
      end

    spec = user_formatter || default

    if spec && file_path do
      String.replace(spec, "{file}", file_path)
    else
      spec
    end
  end

  @doc """
  Formats content by piping it through the given command.

  Writes the content to a temporary file and pipes it to the command via
  shell redirection. Standard output is the formatted document and standard error
  is retained separately as diagnostics. Returns `{:ok, result}` on success
  (exit code 0) or `{:error, reason}` on failure.
  """
  @spec format(String.t(), formatter_spec()) :: {:ok, Result.t()} | {:error, failure()}
  def format(content, command_string) when is_binary(content) and is_binary(command_string) do
    workspace = temp_path()

    case start_cleanup_owner(workspace) do
      {:ok, cleanup_owner} ->
        run_in_workspace(content, command_string, workspace, cleanup_owner)

      {:error, reason} ->
        {:error, {:subprocess, "formatter error: #{format_file_error(reason)}"}}
    end
  rescue
    e ->
      {:error, {:subprocess, "formatter error: #{Exception.message(e)}"}}
  end

  @spec run_in_workspace(String.t(), String.t(), String.t(), cleanup_owner()) ::
          {:ok, Result.t()} | {:error, failure()}
  defp run_in_workspace(content, command_string, workspace, cleanup_owner) do
    input_path = Path.join(workspace, "input")
    stdout_path = Path.join(workspace, "stdout")
    stderr_path = Path.join(workspace, "stderr")

    try do
      File.write!(input_path, content)
      File.write!(stdout_path, "")
      File.write!(stderr_path, "")
      run_formatter(command_string, input_path, stdout_path, stderr_path)
    after
      cleanup_workspace(cleanup_owner, workspace)
    end
  end

  @spec run_formatter(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, Result.t()} | {:error, failure()}
  defp run_formatter(command_string, input_path, stdout_path, stderr_path) do
    shell_cmd =
      "(#{command_string}\n) < #{escape_path(input_path)} > #{escape_path(stdout_path)} 2> #{escape_path(stderr_path)}"

    {_shell_output, exit_code} = System.shell(shell_cmd)
    stdout = File.read!(stdout_path)
    stderr = File.read!(stderr_path)

    case exit_code do
      0 ->
        {:ok, Result.new(stdout, stderr)}

      status ->
        {:error, Failure.new(status, stdout, stderr)}
    end
  end

  @doc """
  Applies whitespace transforms using the filetype to resolve options.

  Reads `trim_trailing_whitespace` and `insert_final_newline` from
  `Config.Options` for the given filetype. Prefer the 3-arity version
  with explicit booleans when you already have the option values (e.g.,
  from buffer-local options).
  """
  @spec apply_save_transforms(String.t(), atom()) :: String.t()
  def apply_save_transforms(content, filetype) when is_atom(filetype) do
    trim = Config.get_for_filetype(:trim_trailing_whitespace, filetype)
    final_nl = Config.get_for_filetype(:insert_final_newline, filetype)
    apply_save_transforms(content, trim, final_nl)
  end

  @doc """
  Applies whitespace transforms with explicit boolean flags.

  Used by buffer-local option callers that have already resolved the
  option values from `Buffer.get_option/2`. Trimming preserves every
  existing LF or CRLF separator. A missing final newline uses the last
  complete separator in the content, including for mixed-ending files,
  and defaults to LF when the non-empty content has no separator.
  """
  @spec apply_save_transforms(String.t(), boolean(), boolean()) :: String.t()
  def apply_save_transforms(content, trim_trailing, insert_final_newline) do
    content
    |> maybe_trim_trailing_whitespace(trim_trailing)
    |> maybe_insert_final_newline(insert_final_newline)
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec maybe_trim_trailing_whitespace(String.t(), boolean()) :: String.t()
  defp maybe_trim_trailing_whitespace(content, true) do
    @line_separator
    |> Regex.split(content, include_captures: true, trim: false)
    |> trim_line_parts()
    |> IO.iodata_to_binary()
  end

  defp maybe_trim_trailing_whitespace(content, _), do: content

  @spec maybe_insert_final_newline(String.t(), boolean()) :: String.t()
  defp maybe_insert_final_newline("", true), do: ""

  defp maybe_insert_final_newline(content, true),
    do: maybe_append_final_newline(content, String.ends_with?(content, "\n"))

  defp maybe_insert_final_newline(content, _), do: content

  @spec trim_line_parts([String.t()]) :: iodata()
  defp trim_line_parts([line, separator | rest]),
    do: [String.trim_trailing(line), separator | trim_line_parts(rest)]

  defp trim_line_parts([line]), do: [String.trim_trailing(line)]
  defp trim_line_parts([]), do: []

  @spec maybe_append_final_newline(String.t(), boolean()) :: String.t()
  defp maybe_append_final_newline(content, true), do: content
  defp maybe_append_final_newline(content, false), do: content <> last_line_separator(content)

  @spec last_line_separator(String.t()) :: String.t()
  defp last_line_separator(content) do
    content
    |> :binary.matches("\n")
    |> List.last()
    |> separator_at(content)
  end

  @spec separator_at({non_neg_integer(), 1} | nil, String.t()) :: String.t()
  defp separator_at(nil, _content), do: "\n"
  defp separator_at({0, 1}, _content), do: "\n"

  defp separator_at({index, 1}, content) do
    case :binary.at(content, index - 1) do
      ?\r -> "\r\n"
      _other -> "\n"
    end
  end

  @spec temp_path() :: String.t()
  defp temp_path do
    id = System.unique_integer([:positive])
    Path.join(System.tmp_dir!(), "minga_fmt_#{id}")
  end

  @spec start_cleanup_owner(String.t()) :: {:ok, cleanup_owner()} | {:error, File.posix()}
  defp start_cleanup_owner(workspace) do
    caller = self()
    cleanup_ref = make_ref()

    owner =
      spawn(fn ->
        caller_monitor = Process.monitor(caller)

        case File.mkdir(workspace) do
          :ok ->
            send(caller, {:formatter_workspace_ready, cleanup_ref})
            await_cleanup(caller, caller_monitor, cleanup_ref, workspace)

          {:error, reason} ->
            send(caller, {:formatter_workspace_error, cleanup_ref, reason})
        end
      end)

    receive do
      {:formatter_workspace_ready, ^cleanup_ref} -> {:ok, {owner, cleanup_ref}}
      {:formatter_workspace_error, ^cleanup_ref, reason} -> {:error, reason}
    end
  end

  @spec await_cleanup(pid(), reference(), reference(), String.t()) :: :ok
  defp await_cleanup(caller, caller_monitor, cleanup_ref, workspace) do
    receive do
      {:cleanup_formatter_workspace, ^caller, ^cleanup_ref} ->
        remove_workspace(workspace)
        Process.demonitor(caller_monitor, [:flush])
        send(caller, {:formatter_workspace_removed, cleanup_ref})

      {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
        remove_workspace(workspace)
    end
  end

  @spec cleanup_workspace(cleanup_owner(), String.t()) :: :ok
  defp cleanup_workspace({owner, cleanup_ref}, workspace) do
    monitor = Process.monitor(owner)
    send(owner, {:cleanup_formatter_workspace, self(), cleanup_ref})

    receive do
      {:formatter_workspace_removed, ^cleanup_ref} ->
        Process.demonitor(monitor, [:flush])
        :ok

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        remove_workspace(workspace)
    after
      1_000 ->
        Process.demonitor(monitor, [:flush])
        remove_workspace(workspace)
    end
  end

  @spec remove_workspace(String.t()) :: :ok
  defp remove_workspace(workspace) do
    _ = File.rm_rf(workspace)
    :ok
  end

  @spec format_file_error(File.posix()) :: String.t()
  defp format_file_error(reason), do: reason |> :file.format_error() |> IO.iodata_to_binary()

  @spec escape_path(String.t()) :: String.t()
  defp escape_path(path) do
    "'" <> String.replace(path, "'", "'\\''") <> "'"
  end
end
