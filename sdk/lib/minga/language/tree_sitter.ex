defmodule Minga.Language.TreeSitter do
  @moduledoc """
  Option types for registering a tree-sitter grammar with `Minga.Language.register/3`.

  This module defines types only. It has no functions in the SDK.
  """

  @typedoc "Options accepted by `Minga.Language.register/3`."
  @type register_opt ::
          {:highlights, String.t()}
          | {:injections, String.t()}
          | {:filetype_extensions, [String.t()]}
          | {:filetype_filenames, [String.t()]}
          | {:filetype_atom, atom()}
          | {:compiler, {:ok, String.t()} | {:error, String.t()}}
end
