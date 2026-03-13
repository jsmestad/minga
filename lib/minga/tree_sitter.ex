defmodule Minga.TreeSitter do
  @moduledoc """
  Compiles and registers tree-sitter grammars at runtime.

  Extensions ship grammar source files (`parser.c`, optional `scanner.c`)
  and highlight queries (`.scm`). This module compiles the C sources into
  a platform-appropriate shared library (`.dylib` on macOS, `.so` on Linux)
  using the system C compiler, then loads the library into the parser Port
  via the `load_grammar` protocol message.

  Compiled libraries are cached at `~/.local/share/minga/grammars/` so
  subsequent startups skip compilation.

  ## Example

      Minga.TreeSitter.register_grammar(
        "org",
        "/path/to/tree-sitter-org/src",
        highlights: "/path/to/queries/org/highlights.scm",
        injections: "/path/to/queries/org/injections.scm",
        filetype_extensions: [".org"],
        filetype_atom: :org
      )
  """

  alias Minga.Highlight.Grammar, as: HLGrammar
  alias Minga.Parser.Manager, as: ParserManager
  alias Minga.Port.Protocol

  @grammar_cache_dir Path.expand("~/.local/share/minga/grammars")

  @typedoc "Options for `register_grammar/3`."
  @type register_opt ::
          {:highlights, String.t()}
          | {:injections, String.t()}
          | {:filetype_extensions, [String.t()]}
          | {:filetype_filenames, [String.t()]}
          | {:filetype_atom, atom()}

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Registers a tree-sitter grammar for runtime use.

  Compiles the grammar sources into a shared library (if not cached),
  loads it into the parser Port, sends the highlight query, and
  registers filetype mappings.

  `name` is the tree-sitter grammar name (e.g., `"org"`). The parser
  expects the shared library to export a `tree_sitter_{name}` function.

  `source_dir` is the path to the directory containing `parser.c` and
  optionally `scanner.c`.

  ## Options

  - `:highlights` - path to a `highlights.scm` query file
  - `:injections` - path to an `injections.scm` query file
  - `:filetype_extensions` - list of file extensions to map (e.g., `[".org"]`)
  - `:filetype_filenames` - list of exact filenames to map (e.g., `["Orgfile"]`)
  - `:filetype_atom` - the filetype atom (e.g., `:org`)
  """
  @spec register_grammar(String.t(), String.t(), [register_opt()]) ::
          :ok | {:error, String.t()}
  def register_grammar(name, source_dir, opts \\ [])
      when is_binary(name) and is_binary(source_dir) do
    filetype_atom = Keyword.get(opts, :filetype_atom)

    with {:ok, lib_path} <- ensure_compiled(name, source_dir),
         :ok <- load_into_parser(name, lib_path),
         :ok <- send_queries(name, opts),
         :ok <- register_filetype_mappings(name, filetype_atom, opts) do
      Minga.Log.info(:editor, "Grammar #{name} registered successfully")
      :ok
    end
  end

  @doc """
  Compiles a tree-sitter grammar into a shared library.

  Returns the path to the compiled library. If a cached library already
  exists and is newer than the source files, returns the cached path
  without recompiling.
  """
  @spec compile_grammar(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def compile_grammar(name, source_dir) when is_binary(name) and is_binary(source_dir) do
    ensure_compiled(name, source_dir)
  end

  @doc """
  Returns the path to the cached shared library for a grammar.
  """
  @spec grammar_lib_path(String.t()) :: String.t()
  def grammar_lib_path(name) when is_binary(name) do
    ext = shared_lib_extension()
    Path.join(@grammar_cache_dir, "#{name}.#{ext}")
  end

  @doc """
  Returns the path to the tree-sitter C header directory shipped with Minga.

  This directory contains `tree_sitter/api.h` and `tree_sitter/parser.h`.
  Extensions need these headers to compile grammars that do
  `#include "tree_sitter/parser.h"` (most grammars ship their own copy
  in `src/tree_sitter/`, but this serves as a fallback).
  """
  @spec include_path() :: String.t()
  def include_path do
    priv_path = Application.app_dir(:minga, "priv")

    if File.exists?(Path.join(priv_path, "tree_sitter/parser.h")) do
      priv_path
    else
      # Dev/test fallback: use priv/ from the project root
      Path.join([File.cwd!(), "priv"])
    end
  end

  @doc """
  Finds the system C compiler.

  Checks `$CC` environment variable first, then tries `cc`, `gcc`, `clang`
  in order. Returns `{:ok, path}` or `{:error, reason}`.
  """
  @spec find_compiler() :: {:ok, String.t()} | {:error, String.t()}
  def find_compiler do
    case System.get_env("CC") do
      nil -> find_compiler_in_path()
      cc -> {:ok, cc}
    end
  end

  # ── Private: Compilation ───────────────────────────────────────────────────

  @spec ensure_compiled(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp ensure_compiled(name, source_dir) do
    lib_path = grammar_lib_path(name)
    source_dir = Path.expand(source_dir)
    parser_c = Path.join(source_dir, "parser.c")

    if File.exists?(parser_c) do
      if cache_valid?(lib_path, source_dir) do
        {:ok, lib_path}
      else
        do_compile(name, source_dir, lib_path)
      end
    else
      {:error, "parser.c not found in #{source_dir}"}
    end
  end

  @spec cache_valid?(String.t(), String.t()) :: boolean()
  defp cache_valid?(lib_path, source_dir) do
    if File.exists?(lib_path) do
      lib_mtime = file_mtime(lib_path)
      source_files = source_c_files(source_dir)

      Enum.all?(source_files, fn src ->
        file_mtime(src) <= lib_mtime
      end)
    else
      false
    end
  end

  @spec do_compile(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp do_compile(name, source_dir, lib_path) do
    with {:ok, cc} <- find_compiler() do
      File.mkdir_p!(Path.dirname(lib_path))

      sources = source_c_files(source_dir)
      include_dir = include_path()

      args = build_compiler_args(lib_path, sources, source_dir, include_dir)

      Minga.Log.info(:editor, "Compiling grammar #{name}: #{cc} #{Enum.join(args, " ")}")

      case System.cmd(cc, args, stderr_to_stdout: true) do
        {_output, 0} ->
          Minga.Log.info(:editor, "Grammar #{name} compiled to #{lib_path}")
          {:ok, lib_path}

        {output, exit_code} ->
          msg = "Grammar #{name} compilation failed (exit #{exit_code}): #{String.trim(output)}"
          Minga.Log.warning(:editor, msg)
          {:error, msg}
      end
    end
  end

  @spec build_compiler_args(String.t(), [String.t()], String.t(), String.t()) :: [String.t()]
  defp build_compiler_args(lib_path, sources, source_dir, include_dir) do
    base_flags = ["-shared", "-fPIC", "-std=c11", "-O2", "-o", lib_path]
    include_flags = ["-I", source_dir, "-I", include_dir]

    base_flags ++ include_flags ++ sources
  end

  @spec source_c_files(String.t()) :: [String.t()]
  defp source_c_files(source_dir) do
    parser_c = Path.join(source_dir, "parser.c")
    scanner_c = Path.join(source_dir, "scanner.c")

    if File.exists?(scanner_c) do
      [parser_c, scanner_c]
    else
      [parser_c]
    end
  end

  @spec find_compiler_in_path() :: {:ok, String.t()} | {:error, String.t()}
  defp find_compiler_in_path do
    Enum.find_value(
      ["cc", "gcc", "clang"],
      {:error, "no C compiler found (tried cc, gcc, clang). Set $CC or install a C toolchain."},
      fn name ->
        case System.find_executable(name) do
          nil -> nil
          path -> {:ok, path}
        end
      end
    )
  end

  @spec shared_lib_extension() :: String.t()
  defp shared_lib_extension do
    case :os.type() do
      {:unix, :darwin} -> "dylib"
      {:unix, _} -> "so"
      {:win32, _} -> "dll"
    end
  end

  @spec file_mtime(String.t()) :: integer()
  defp file_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      {:error, _} -> 0
    end
  end

  # ── Private: Loading into parser ───────────────────────────────────────────

  @spec load_into_parser(String.t(), String.t()) :: :ok | {:error, String.t()}
  defp load_into_parser(name, lib_path) do
    commands = [Protocol.encode_load_grammar(name, lib_path)]
    ParserManager.send_commands(commands)

    # The parser responds asynchronously with grammar_loaded.
    # We don't block here; the response is handled by the Editor
    # via the highlight event subscription.
    :ok
  end

  # ── Private: Query registration ────────────────────────────────────────────

  @spec send_queries(String.t(), keyword()) :: :ok
  defp send_queries(name, opts) do
    commands = []

    # Set the language first so queries are associated with it
    commands = commands ++ [Protocol.encode_set_language(name)]

    commands =
      case Keyword.get(opts, :highlights) do
        nil ->
          commands

        path ->
          case File.read(Path.expand(path)) do
            {:ok, query} ->
              commands ++ [Protocol.encode_set_highlight_query(query)]

            {:error, reason} ->
              Minga.Log.warning(
                :editor,
                "Could not read highlights for #{name}: #{inspect(reason)}"
              )

              commands
          end
      end

    commands =
      case Keyword.get(opts, :injections) do
        nil ->
          commands

        path ->
          case File.read(Path.expand(path)) do
            {:ok, query} ->
              commands ++ [Protocol.encode_set_injection_query(query)]

            {:error, reason} ->
              Minga.Log.warning(
                :editor,
                "Could not read injections for #{name}: #{inspect(reason)}"
              )

              commands
          end
      end

    if length(commands) > 1 do
      ParserManager.send_commands(commands)
    end

    :ok
  end

  # ── Private: Filetype registration ─────────────────────────────────────────

  @spec register_filetype_mappings(String.t(), atom() | nil, keyword()) :: :ok
  defp register_filetype_mappings(_name, nil, _opts), do: :ok

  defp register_filetype_mappings(name, filetype_atom, opts) do
    # Register in the highlight grammar mapping
    HLGrammar.register_language(filetype_atom, name)

    # Register file extensions
    for ext <- Keyword.get(opts, :filetype_extensions, []) do
      Minga.Filetype.Registry.register(ext, filetype_atom)
    end

    # Register exact filenames
    for filename <- Keyword.get(opts, :filetype_filenames, []) do
      Minga.Filetype.Registry.register(filename, filetype_atom)
    end

    :ok
  end
end
