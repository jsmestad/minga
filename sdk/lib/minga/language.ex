defmodule Minga.Language do
  @moduledoc """
  Registers languages for extensions that ship their own tree-sitter grammar.

  Use `register/3` from `init/1` to compile a grammar's `parser.c` and optional `scanner.c`, load it into the parser, and map the filetype it highlights.

  This is a compile-time stub. At runtime, the real module in Minga's BEAM VM provides the implementation.
  """

  @doc """
  Registers a tree-sitter grammar for runtime use.

  `name` is the language identifier (for example `"org"`). `source_dir` is the path that contains the grammar's `parser.c` and optionally `scanner.c`.

  Returns `{:error, reason}` when compilation or other synchronous setup fails. A successful `:ok` means the parser load request was accepted, not that every parser process has already applied it.
  """
  @spec register(String.t(), String.t(), [Minga.Language.TreeSitter.register_opt()]) ::
          :ok | {:error, String.t()}
  def register(_name, _source_dir, _opts \\ []), do: raise("minga_sdk is compile-time only")
end
