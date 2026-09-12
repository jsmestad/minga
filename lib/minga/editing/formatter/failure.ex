defmodule Minga.Editing.Formatter.Failure do
  @moduledoc "Nonzero external formatter result with captured streams kept separate."

  @enforce_keys [:exit_code, :stdout, :stderr]
  defstruct [:exit_code, :stdout, :stderr]

  @type t :: %__MODULE__{
          exit_code: non_neg_integer(),
          stdout: String.t(),
          stderr: String.t()
        }

  @doc "Builds a nonzero formatter result from the exit status and captured streams."
  @spec new(non_neg_integer(), String.t(), String.t()) :: t()
  def new(exit_code, stdout, stderr)
      when is_integer(exit_code) and exit_code >= 0 and is_binary(stdout) and is_binary(stderr) do
    %__MODULE__{exit_code: exit_code, stdout: stdout, stderr: stderr}
  end

  @doc "Builds a useful user-facing message without combining the captured stream values."
  @spec message(t()) :: String.t()
  def message(%__MODULE__{} = failure) do
    "Formatter exited with code #{failure.exit_code}: #{detail(failure.stdout, failure.stderr)}"
  end

  @spec detail(String.t(), String.t()) :: String.t()
  defp detail(stdout, stderr) do
    trimmed_stdout = String.trim(stdout)
    trimmed_stderr = String.trim(stderr)

    case {trimmed_stdout, trimmed_stderr} do
      {"", ""} -> "no diagnostic output"
      {"", diagnostics} -> diagnostics
      {output, ""} -> output
      {output, diagnostics} -> diagnostics <> "\nstdout: " <> output
    end
  end
end
