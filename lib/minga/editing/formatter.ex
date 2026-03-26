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
  alias Minga.Language.Registry, as: LangRegistry

  @typedoc "A shell command string, optionally containing `{file}`."
  @type formatter_spec :: String.t()

  @doc "Returns the default formatter map (filetype atom to command string)."
  @spec default_formatters() :: %{atom() => formatter_spec()}
  def default_formatters do
    LangRegistry.all()
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
      case LangRegistry.get(filetype) do
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
  shell redirection. Returns `{:ok, formatted_content}` on success
  (exit code 0) or `{:error, reason}` on failure.
  """
  @spec format(String.t(), formatter_spec()) :: {:ok, String.t()} | {:error, String.t()}
  def format(content, command_string) when is_binary(content) and is_binary(command_string) do
    tmp_path = temp_path()
    File.write!(tmp_path, content)

    try do
      run_formatter(command_string, tmp_path)
    after
      File.rm(tmp_path)
    end
  rescue
    e ->
      {:error, "formatter error: #{Exception.message(e)}"}
  end

  @spec run_formatter(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp run_formatter(command_string, tmp_path) do
    shell_cmd = "#{command_string} < #{escape_path(tmp_path)}"

    case System.shell(shell_cmd, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, output}

      {output, exit_code} ->
        trimmed = String.trim(output)
        {:error, "formatter exited with code #{exit_code}: #{trimmed}"}
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
  option values from `Buffer.Server.get_option/2`.
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
    content
    |> String.split("\n")
    |> Enum.map_join("\n", &String.trim_trailing/1)
  end

  defp maybe_trim_trailing_whitespace(content, _), do: content

  @spec maybe_insert_final_newline(String.t(), boolean()) :: String.t()
  defp maybe_insert_final_newline(content, true) do
    if String.ends_with?(content, "\n"), do: content, else: content <> "\n"
  end

  defp maybe_insert_final_newline(content, _), do: content

  @spec temp_path() :: String.t()
  defp temp_path do
    id = System.unique_integer([:positive])
    Path.join(System.tmp_dir!(), "minga_fmt_#{id}")
  end

  @spec escape_path(String.t()) :: String.t()
  defp escape_path(path) do
    "'" <> String.replace(path, "'", "'\\''") <> "'"
  end
end
