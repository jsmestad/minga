defmodule MingaEditor.Commands.FileTree.DuplicateBackend do
  @moduledoc """
  Injectable boundary for the Duplicate command's owned filesystem effects.

  The command claims a destination before copying so cleanup can remove only output owned by that operation. The backend keeps filesystem failures deterministic in tests.
  """

  @type t :: module()
  @type entry_type :: :directory | :file
  @type copy_result ::
          :ok | {:ok, [String.t()]} | {:error, File.posix()} | {:error, File.posix(), String.t()}
  @type cleanup_result :: {:ok, [String.t()]} | {:error, File.posix(), String.t()}

  @callback claim_destination(String.t(), entry_type()) :: :ok | {:error, File.posix()}
  @callback copy(String.t(), String.t(), entry_type()) :: copy_result()
  @callback cleanup(String.t()) :: cleanup_result()
end
