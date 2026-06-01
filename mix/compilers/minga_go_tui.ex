defmodule Mix.Tasks.Compile.MingaGoTui do
  @moduledoc """
  Custom Mix compiler that builds the Charm-based Go TUI renderer.

  The Go renderer is copied to `priv/minga-renderer-go` and selected at runtime with `MINGA_TUI_IMPL=go`.
  """

  use Mix.Task.Compiler

  @module_dir "go/tui"
  @priv_dir "priv"
  @build_dir "bin"
  @binary_name "minga-renderer-go"
  @source_extensions ~w(.go .mod .sum)

  @impl true
  @spec run(keyword()) :: {:ok, []} | {:error, []}
  def run(_opts) do
    Mix.Task.run("protocol.gen", [])

    if File.dir?(@module_dir) do
      output = Path.join(@priv_dir, @binary_name)

      if needs_rebuild?(output) do
        compile()
      else
        {:ok, []}
      end
    else
      {:ok, []}
    end
  end

  @spec needs_rebuild?(String.t()) :: boolean()
  defp needs_rebuild?(output) do
    case File.stat(output, time: :posix) do
      {:ok, %{mtime: output_mtime}} -> any_source_newer?(output_mtime)
      {:error, _reason} -> true
    end
  end

  @spec any_source_newer?(integer()) :: boolean()
  defp any_source_newer?(output_mtime) do
    Enum.any?(source_files(), fn source ->
      case File.stat(source, time: :posix) do
        {:ok, %{mtime: source_mtime}} -> source_mtime > output_mtime
        {:error, _reason} -> true
      end
    end)
  end

  @spec source_files() :: [String.t()]
  defp source_files do
    @module_dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&(Path.extname(&1) in @source_extensions))
  end

  @spec compile() :: {:ok, []} | {:error, []}
  defp compile do
    Mix.shell().info("Compiling Go TUI renderer...")
    File.mkdir_p!(Path.join(@module_dir, @build_dir))

    case System.cmd(
           "go",
           ["build", "-o", Path.join(@build_dir, @binary_name), "./cmd/minga-renderer-go"],
           cd: @module_dir,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        copy_to_priv()
        {:ok, []}

      {output, _code} ->
        Mix.shell().error("Go TUI compilation failed:\n#{output}")
        {:error, []}
    end
  end

  @spec copy_to_priv() :: :ok
  defp copy_to_priv do
    src = Path.join([@module_dir, @build_dir, @binary_name])
    dest = Path.join(@priv_dir, @binary_name)
    File.mkdir_p!(@priv_dir)
    File.cp!(src, dest)
    File.chmod!(dest, 0o755)
    Mix.shell().info("Copied #{@binary_name} to #{dest}")
    :ok
  end

  @impl true
  @spec manifests() :: [String.t()]
  def manifests, do: []

  @impl true
  @spec clean() :: :ok
  def clean do
    if File.dir?(@module_dir) do
      System.cmd("go", ["clean"], cd: @module_dir, stderr_to_stdout: true)
      File.rm_rf!(Path.join(@module_dir, @build_dir))
    end

    :ok
  end
end
