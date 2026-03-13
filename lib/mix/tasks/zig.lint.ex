defmodule Mix.Tasks.Zig.Lint do
  @moduledoc """
  Runs Zig formatting and test checks.

  Equivalent to:

      zig fmt --check zig/src/
      zig build test

  Exits non-zero if formatting is off or tests fail.
  """

  use Mix.Task

  @shortdoc "Check Zig formatting and run Zig tests"

  @impl Mix.Task
  @spec run(list()) :: :ok
  def run(_args) do
    zig_root = Path.join(Mix.Project.project_file() |> Path.dirname(), "zig")

    unless File.dir?(zig_root) do
      Mix.raise("Zig directory not found at #{zig_root}")
    end

    run_step("zig fmt --check", zig_root, ["fmt", "--check", "src/"])
    run_step("zig build test", zig_root, ["build", "test"])

    Mix.shell().info([:green, "Zig lint passed.", :reset])
  end

  @spec run_step(String.t(), String.t(), [String.t()]) :: :ok
  defp run_step(label, cwd, args) do
    Mix.shell().info([:cyan, "Running #{label}...", :reset])

    case System.cmd("zig", args, cd: cwd, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, code} ->
        Mix.shell().error(output)
        Mix.raise("#{label} failed (exit #{code})")
    end
  end
end
