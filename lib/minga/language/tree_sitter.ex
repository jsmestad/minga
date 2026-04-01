defmodule Minga.Language.TreeSitter do
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

      Minga.Language.TreeSitter.register_grammar(
        "org",
        "/path/to/tree-sitter-org/src",
        highlights: "/path/to/queries/org/highlights.scm",
        injections: "/path/to/queries/org/injections.scm",
        filetype_extensions: [".org"],
        filetype_atom: :org
      )
  """

  alias Minga.Parser.Manager, as: ParserManager
  alias Minga.Language.Grammar, as: HLGrammar

  @doc """
  Returns the grammar cache directory path.

  Uses `$XDG_DATA_HOME/minga/grammars` if set, otherwise
  `~/.local/share/minga/grammars`. Resolved at runtime so the path
  is correct regardless of the build environment.
  """
  @spec grammar_cache_dir() :: String.t()
  def grammar_cache_dir do
    data_home = System.get_env("XDG_DATA_HOME") || Path.expand("~/.local/share")
    Path.join([data_home, "minga", "grammars"])
  end

  @typedoc "Options for `register_grammar/3`."
  @type register_opt ::
          {:highlights, String.t()}
          | {:injections, String.t()}
          | {:filetype_extensions, [String.t()]}
          | {:filetype_filenames, [String.t()]}
          | {:filetype_atom, atom()}
          | {:compiler, {:ok, String.t()} | {:error, String.t()}}

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
    compiler = Keyword.get(opts, :compiler)

    with {:ok, lib_path} <- ensure_compiled(name, source_dir, compiler),
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

  ## Options

  - `:compiler` - override compiler resolution. Pass `{:ok, "/usr/bin/cc"}`
    to use a specific compiler, or `{:error, "reason"}` to simulate a
    missing compiler (useful for testing). Defaults to `find_compiler/0`.
  """
  @spec compile_grammar(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def compile_grammar(name, source_dir, opts \\ [])
      when is_binary(name) and is_binary(source_dir) do
    compiler = Keyword.get(opts, :compiler)
    ensure_compiled(name, source_dir, compiler)
  end

  @doc """
  Returns the path to the cached shared library for a grammar.
  """
  @spec grammar_lib_path(String.t()) :: String.t()
  def grammar_lib_path(name) when is_binary(name) do
    ext = shared_lib_extension()
    Path.join(grammar_cache_dir(), "#{name}.#{ext}")
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

  @spec ensure_compiled(String.t(), String.t(), {:ok, String.t()} | {:error, String.t()} | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  defp ensure_compiled(name, source_dir, compiler) do
    lib_path = grammar_lib_path(name)
    source_dir = Path.expand(source_dir)
    parser_c = Path.join(source_dir, "parser.c")

    if File.exists?(parser_c) do
      if cache_valid?(lib_path, source_dir) do
        {:ok, lib_path}
      else
        do_compile(name, source_dir, lib_path, compiler)
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

  @spec do_compile(
          String.t(),
          String.t(),
          String.t(),
          {:ok, String.t()} | {:error, String.t()} | nil
        ) :: {:ok, String.t()} | {:error, String.t()}
  defp do_compile(name, source_dir, lib_path, compiler) do
    with {:ok, cc} <- resolve_compiler(compiler) do
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

  @spec resolve_compiler({:ok, String.t()} | {:error, String.t()} | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  defp resolve_compiler(nil), do: find_compiler()
  defp resolve_compiler(result), do: result

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

  @spec load_into_parser(String.t(), String.t()) :: :ok
  defp load_into_parser(name, lib_path) do
    # The parser responds asynchronously with grammar_loaded.
    # We don't block here; the response is handled by the Editor
    # via the highlight event subscription.
    ParserManager.load_grammar(name, lib_path)
  end

  # ── Private: Query registration ────────────────────────────────────────────

  @spec send_queries(String.t(), keyword()) :: :ok
  defp send_queries(name, opts) do
    # Set the language first so queries are associated with it.
    # Dynamic grammar loading uses buffer_id 0 (global/default).
    ParserManager.set_language(0, name)

    send_query(name, opts, :highlights, &ParserManager.set_highlight_query(0, &1))
    send_query(name, opts, :injections, &ParserManager.set_injection_query(0, &1))

    :ok
  end

  @spec send_query(String.t(), keyword(), atom(), (String.t() -> :ok)) :: :ok
  defp send_query(name, opts, query_type, send_fn) do
    case Keyword.get(opts, query_type) do
      nil ->
        :ok

      path ->
        case File.read(Path.expand(path)) do
          {:ok, query} ->
            resolved = resolve_query_inherits(query, query_type)
            send_fn.(resolved)

          {:error, reason} ->
            Minga.Log.warning(
              :editor,
              "Could not read #{query_type} for #{name}: #{inspect(reason)}"
            )
        end
    end
  end

  # ── Private: Query inheritance resolution ──────────────────────────────────

  @doc false
  @spec resolve_query_inherits(String.t(), atom()) :: String.t()
  def resolve_query_inherits(query, query_type) do
    resolve_query_inherits(query, query_type, 0)
  end

  @max_inherit_depth 8

  @spec resolve_query_inherits(String.t(), atom(), non_neg_integer()) :: String.t()
  defp resolve_query_inherits(query, _query_type, depth) when depth > @max_inherit_depth do
    Minga.Log.warning(:editor, "Query inheritance depth exceeded #{@max_inherit_depth} levels")
    query
  end

  defp resolve_query_inherits(query, query_type, depth) do
    case parse_inherits_directive(query) do
      {:ok, parents, rest} ->
        parent_queries =
          Enum.map_join(parents, "\n", fn parent ->
            resolve_parent_query(parent, query_type, depth)
          end)

        parent_queries <> "\n" <> rest

      :no_inherits ->
        query
    end
  end

  @spec resolve_parent_query(String.t(), atom(), non_neg_integer()) :: String.t()
  defp resolve_parent_query(parent, query_type, depth) do
    case read_builtin_query(parent, query_type) do
      {:ok, parent_query} ->
        resolve_query_inherits(parent_query, query_type, depth + 1)

      :error ->
        Minga.Log.warning(:editor, "Could not find parent query '#{parent}' for inheritance")
        ""
    end
  end

  @spec parse_inherits_directive(String.t()) ::
          {:ok, [String.t()], String.t()} | :no_inherits
  defp parse_inherits_directive(query) do
    case String.split(query, "\n", parts: 2) do
      [first_line, rest] ->
        case String.trim(first_line) do
          "; inherits: " <> parents_str ->
            parents =
              parents_str
              |> String.split(",")
              |> Enum.map(&String.trim/1)
              |> Enum.reject(&(&1 == ""))

            {:ok, parents, rest}

          _ ->
            :no_inherits
        end

      _ ->
        :no_inherits
    end
  end

  @spec read_builtin_query(String.t(), atom()) :: {:ok, String.t()} | :error
  defp read_builtin_query(language, query_type) do
    filename =
      case query_type do
        :highlights -> "highlights.scm"
        :injections -> "injections.scm"
        :locals -> "locals.scm"
        :folds -> "folds.scm"
      end

    # Look in priv/queries first (built-in), then user overrides
    paths = [
      Path.join([Application.app_dir(:minga, "priv"), "queries", language, filename]),
      Path.join([priv_queries_dir(), language, filename])
    ]

    Enum.find_value(paths, :error, fn path ->
      case File.read(path) do
        {:ok, content} -> {:ok, content}
        {:error, _} -> nil
      end
    end)
  end

  @spec priv_queries_dir() :: String.t()
  defp priv_queries_dir do
    config_home = System.get_env("XDG_CONFIG_HOME") || Path.expand("~/.config")
    Path.join([config_home, "minga", "queries"])
  end

  # ── Private: Filetype registration ─────────────────────────────────────────

  @spec register_filetype_mappings(String.t(), atom() | nil, keyword()) :: :ok
  defp register_filetype_mappings(_name, nil, _opts), do: :ok

  defp register_filetype_mappings(name, filetype_atom, opts) do
    # Register in the highlight grammar mapping
    HLGrammar.register_language(filetype_atom, name)

    # Register file extensions
    for ext <- Keyword.get(opts, :filetype_extensions, []) do
      Minga.Language.Filetype.Registry.register(ext, filetype_atom)
    end

    # Register exact filenames
    for filename <- Keyword.get(opts, :filetype_filenames, []) do
      Minga.Language.Filetype.Registry.register(filename, filetype_atom)
    end

    :ok
  end
end
