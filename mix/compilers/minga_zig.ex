defmodule Mix.Tasks.Compile.MingaZig do
  @moduledoc """
  Opt-in Mix task that builds the Zig parser support binaries.

  Since the Zig renderer was removed in #2223, this builds only the tree-sitter
  parser (`minga-parser`) and the hook runner (`minga-hook-runner`).

  This task is intentionally not registered in the project's compiler list. Native binaries are built by explicit Makefile and CI steps, not by every `mix compile`.

  Production builds use ReleaseSafe, which keeps runtime safety checks without Debug's allocator overhead. Each invocation passes its requested optimization mode to Zig's build cache instead of reusing output based only on modification times.
  """

  use Mix.Task.Compiler

  @zig_dir "zig"
  @priv_dir "priv"
  @parser_name "minga-parser"
  @hook_runner_name "minga-hook-runner"
  @optimize if Mix.env() == :prod, do: "ReleaseSafe", else: "Debug"

  @impl true
  @spec run(keyword()) :: {:ok, []} | {:error, []}
  def run(_opts) do
    Mix.Task.run("language_aliases.gen", [])
    Mix.Task.run("protocol.gen", [])

    if File.dir?(@zig_dir) do
      compile_zig_backend()
    else
      {:ok, []}
    end
  end

  @spec compile_zig_backend() :: {:ok, []} | {:error, []}
  defp compile_zig_backend do
    Mix.shell().info("Compiling Zig parser binaries (#{@optimize})...")

    args = ["build", "-Doptimize=#{@optimize}"] ++ zig_target_args()

    case System.cmd("zig", args, cd: @zig_dir, stderr_to_stdout: true) do
      {_output, 0} ->
        Mix.shell().info("Zig parser binaries compiled successfully")
        Enum.each([@parser_name, @hook_runner_name], &copy_to_priv/1)
        {:ok, []}

      {output, _code} ->
        Mix.shell().error("Zig compilation failed:\n#{output}")
        {:error, []}
    end
  end

  @spec zig_target_args() :: [String.t()]
  defp zig_target_args do
    case {:os.type(), :erlang.system_info(:system_architecture) |> List.to_string()} do
      {{:unix, :darwin}, "aarch64" <> _rest} -> ["-Dtarget=aarch64-macos.15.0"]
      {{:unix, :darwin}, "x86_64" <> _rest} -> ["-Dtarget=x86_64-macos.15.0"]
      _other -> []
    end
  end

  @spec copy_to_priv(String.t()) :: :ok
  defp copy_to_priv(name) do
    src = Path.join([@zig_dir, "zig-out", "bin", name])
    File.mkdir_p!(@priv_dir)
    dest = Path.join(@priv_dir, name)

    temporary = "#{dest}.#{System.pid()}-#{System.unique_integer([:positive])}.tmp"

    try do
      File.cp!(src, temporary)
      File.chmod!(temporary, 0o755)
      codesign_if_macos(temporary, name)
      File.rename!(temporary, dest)
      Mix.shell().info("Copied #{name} to #{dest}")
    after
      File.rm(temporary)
    end

    :ok
  end

  # On macOS, Zig's ad-hoc linker signature is rejected by Apple System Policy
  # (Gatekeeper), resulting in SIGKILL (exit 137). Re-signing with `codesign -s -`
  # produces a valid ad-hoc signature that macOS accepts.
  @spec codesign_if_macos(String.t(), String.t()) :: :ok
  defp codesign_if_macos(path, identifier) do
    case :os.type() do
      {:unix, :darwin} ->
        case System.cmd("codesign", ["--force", "--sign", "-", "--identifier", identifier, path],
               stderr_to_stdout: true
             ) do
          {_output, 0} -> :ok
          {output, _code} -> Mix.raise("codesign failed for #{path}:\n#{output}")
        end

      _ ->
        :ok
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
