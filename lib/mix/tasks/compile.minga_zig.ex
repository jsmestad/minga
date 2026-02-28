defmodule Mix.Tasks.Compile.MingaZig do
  @moduledoc """
  Custom Mix compiler that builds the Zig renderer binary.

  Registered as `:minga_zig` in the project's compiler list.
  Runs `zig build` in the `zig/` directory when Zig source files
  are present.
  """

  use Mix.Task.Compiler

  @zig_dir "zig"
  @priv_dir "priv"
  @renderer_name "minga-renderer"

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
        copy_to_priv()
        {:ok, []}

      {output, _code} ->
        Mix.shell().error("Zig compilation failed:\n#{output}")
        {:error, []}
    end
  end

  @spec copy_to_priv() :: :ok
  defp copy_to_priv do
    src = Path.join([@zig_dir, "zig-out", "bin", @renderer_name])
    File.mkdir_p!(@priv_dir)
    dest = Path.join(@priv_dir, @renderer_name)

    if File.exists?(src) do
      File.cp!(src, dest)
      # Ensure executable
      File.chmod!(dest, 0o755)
      codesign_if_macos(dest)
      Mix.shell().info("Copied renderer to #{dest}")
    end

    :ok
  end

  # On macOS, Zig's ad-hoc linker signature is rejected by Apple System Policy
  # (Gatekeeper), resulting in SIGKILL (exit 137). Re-signing with `codesign -s -`
  # produces a valid ad-hoc signature that macOS accepts.
  @spec codesign_if_macos(String.t()) :: :ok
  defp codesign_if_macos(path) do
    case :os.type() do
      {:unix, :darwin} ->
        case System.cmd("codesign", ["--force", "--sign", "-", path], stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, _code} -> Mix.shell().error("codesign failed: #{output}")
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
