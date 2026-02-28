defmodule Mix.Tasks.Compile.MingaZig do
  @moduledoc """
  Custom Mix compiler that builds the Zig renderer binary.

  Registered as `:minga_zig` in the project's compiler list.
  Runs `zig build` in the `zig/` directory when Zig source files
  are present.
  """

  use Mix.Task.Compiler

  @zig_dir "zig"

  @impl true
  @spec run(keyword()) :: {:ok, []} | {:error, []}
  def run(_opts) do
    if File.dir?(@zig_dir) do
      compile_zig()
    else
      {:ok, []}
    end
  end

  @spec compile_zig() :: {:ok, []} | {:error, []}
  defp compile_zig do
    Mix.shell().info("Compiling Zig renderer...")

    case System.cmd("zig", ["build"], cd: @zig_dir, stderr_to_stdout: true) do
      {_output, 0} ->
        Mix.shell().info("Zig renderer compiled successfully")
        {:ok, []}

      {output, _code} ->
        Mix.shell().error("Zig compilation failed:\n#{output}")
        {:error, []}
    end
  end

  @impl true
  @spec manifests() :: [String.t()]
  def manifests, do: []

  @impl true
  @spec clean() :: :ok
  def clean do
    if File.dir?(@zig_dir) do
      System.cmd("zig", ["build", "--clean"], cd: @zig_dir, stderr_to_stdout: true)
    end

    :ok
  end
end
