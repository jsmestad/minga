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
  @parser_name "minga-parser"
  @hook_runner_name "minga-hook-runner"

  # File extensions that should trigger a Zig rebuild when modified.
  @zig_source_extensions ~w(.zig .zon .c .h .scm)

  @impl true
  @spec run(keyword()) :: {:ok, []} | {:error, []}
  def run(_opts) do
    if File.dir?(@zig_dir) do
      outputs = required_outputs()

      if needs_rebuild?(outputs) do
        compile_zig_backend("tui")
      else
        {:ok, []}
      end
    else
      {:ok, []}
    end
  end

  @spec required_outputs() :: [String.t()]
  defp required_outputs do
    Enum.map([@renderer_name, @parser_name, @hook_runner_name], &Path.join(@priv_dir, &1))
  end

  @spec needs_rebuild?([String.t()]) :: boolean()
  defp needs_rebuild?(output_paths) do
    case oldest_output_mtime(output_paths) do
      nil -> true
      output_mtime -> any_source_newer?(output_mtime)
    end
  end

  @spec oldest_output_mtime([String.t()]) :: integer() | nil
  defp oldest_output_mtime(output_paths) do
    Enum.reduce_while(output_paths, nil, fn path, oldest ->
      case File.stat(path, time: :posix) do
        {:ok, %{mtime: mtime}} -> {:cont, if(oldest, do: min(mtime, oldest), else: mtime)}
        {:error, _reason} -> {:halt, nil}
      end
    end)
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

  @spec compile_zig_backend(String.t()) :: {:ok, []} | {:error, []}
  defp compile_zig_backend(backend) do
    Mix.shell().info("Compiling Zig binaries (#{backend})...")

    args =
      ["build"] ++
        zig_target_args() ++ if(backend != "tui", do: ["-Dbackend=#{backend}"], else: [])

    case System.cmd("zig", args, cd: @zig_dir, stderr_to_stdout: true) do
      {_output, 0} ->
        Mix.shell().info("Zig binaries (#{backend}) compiled successfully")
        copy_to_priv(@renderer_name)
        copy_to_priv(@parser_name)
        copy_to_priv(@hook_runner_name)
        {:ok, []}

      {output, _code} ->
        Mix.shell().error("Zig compilation (#{backend}) failed:\n#{output}")
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

    if File.exists?(src) do
      File.cp!(src, dest)
      # Ensure executable
      File.chmod!(dest, 0o755)
      codesign_if_macos(dest)
      Mix.shell().info("Copied #{name} to #{dest}")
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
