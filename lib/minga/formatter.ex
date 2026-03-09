defmodule Minga.Formatter do
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

  alias Minga.Config.Options

  @typedoc "A shell command string, optionally containing `{file}`."
  @type formatter_spec :: String.t()

  @default_formatters %{
    elixir: "mix format --stdin-filename {file} -",
    go: "gofmt",
    rust: "rustfmt --edition 2021",
    python: "python3 -m black --quiet -",
    zig: "zig fmt --stdin",
    c: "clang-format",
    cpp: "clang-format",
    javascript: "prettier --stdin-filepath {file}",
    typescript: "prettier --stdin-filepath {file}",
    javascript_react: "prettier --stdin-filepath {file}",
    typescript_react: "prettier --stdin-filepath {file}"
  }

  @doc "Returns the default formatter map (filetype atom to command string)."
  @spec default_formatters() :: %{atom() => formatter_spec()}
  def default_formatters, do: @default_formatters

  @doc """
  Resolves the formatter command for a filetype.

  Checks user config (`:formatter` option with filetype override) first,
  then falls back to the built-in default. Returns `nil` if no formatter
  is configured for the filetype.
  """
  @spec resolve_formatter(atom(), String.t() | nil) :: formatter_spec() | nil
  def resolve_formatter(filetype, file_path \\ nil) do
    user_formatter = Options.get_for_filetype(:formatter, filetype)

    spec = user_formatter || Map.get(@default_formatters, filetype)

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
  Applies whitespace cleanup to content before saving.

  Handles `trim_trailing_whitespace` and `insert_final_newline` based on
  the options for the given filetype.
  """
  @spec apply_save_transforms(String.t(), atom()) :: String.t()
  def apply_save_transforms(content, filetype) do
    content
    |> maybe_trim_trailing_whitespace(filetype)
    |> maybe_insert_final_newline(filetype)
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec maybe_trim_trailing_whitespace(String.t(), atom()) :: String.t()
  defp maybe_trim_trailing_whitespace(content, filetype) do
    if Options.get_for_filetype(:trim_trailing_whitespace, filetype) do
      content
      |> String.split("\n")
      |> Enum.map_join("\n", &String.trim_trailing/1)
    else
      content
    end
  end

  @spec maybe_insert_final_newline(String.t(), atom()) :: String.t()
  defp maybe_insert_final_newline(content, filetype) do
    if Options.get_for_filetype(:insert_final_newline, filetype) do
      if String.ends_with?(content, "\n") do
        content
      else
        content <> "\n"
      end
    else
      content
    end
  end

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
