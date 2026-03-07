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

  # File extensions that should trigger a Zig rebuild when modified.
  @zig_source_extensions ~w(.zig .zon .c .h .scm)

  @impl true
  @spec run(keyword()) :: {:ok, []} | {:error, []}
  def run(_opts) do
    if File.dir?(@zig_dir) do
      output = Path.join(@priv_dir, @renderer_name)

      if needs_rebuild?(output) do
        compile_zig_backend("tui", @renderer_name)
      else
        {:ok, []}
      end
    else
      {:ok, []}
    end
  end

  @spec needs_rebuild?(String.t()) :: boolean()
  defp needs_rebuild?(output_path) do
    case File.stat(output_path, time: :posix) do
      {:error, :enoent} -> true
      {:ok, %{mtime: output_mtime}} -> any_source_newer?(output_mtime)
    end
  end

  @spec any_source_newer?(integer()) :: boolean()
  defp any_source_newer?(output_mtime) do
    Enum.any?(zig_source_files(), fn src ->
      source_newer?(src, output_mtime)
    end)
  end

  @spec source_newer?(String.t(), integer()) :: boolean()
  defp source_newer?(src, output_mtime) do
    case File.stat(src, time: :posix) do
      {:ok, %{mtime: src_mtime}} -> src_mtime > output_mtime
      _ -> true
    end
  end

  @spec zig_source_files() :: [String.t()]
  defp zig_source_files do
    Path.wildcard(Path.join(@zig_dir, "**/*"))
    |> Enum.filter(fn path ->
      Path.extname(path) in @zig_source_extensions
    end)
  end

  @spec compile_zig_backend(String.t(), String.t()) :: {:ok, []} | {:error, []}
  defp compile_zig_backend(backend, output_name) do
    Mix.shell().info("Compiling Zig renderer (#{backend})...")

    args = ["build"] ++ if(backend != "tui", do: ["-Dbackend=#{backend}"], else: [])

    case System.cmd("zig", args, cd: @zig_dir, stderr_to_stdout: true) do
      {_output, 0} ->
        Mix.shell().info("Zig renderer (#{backend}) compiled successfully")
        copy_to_priv(@renderer_name, output_name)
        {:ok, []}

      {output, _code} ->
        Mix.shell().error("Zig compilation (#{backend}) failed:\n#{output}")
        {:error, []}
    end
  end

  @spec copy_to_priv(String.t(), String.t()) :: :ok
  defp copy_to_priv(src_name, dest_name) do
    src = Path.join([@zig_dir, "zig-out", "bin", src_name])
    File.mkdir_p!(@priv_dir)
    dest = Path.join(@priv_dir, dest_name)

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
