defmodule Minga.Buffer.FileMutation.Receipt do
  @moduledoc "The source and result observed by the owner of a committed conditional mutation."

  @enforce_keys [:before, :after]
  defstruct [:before, :after]

  @type content :: binary() | :absent
  @type t :: %__MODULE__{before: content(), after: content()}

  @doc "Builds a receipt from the validated source and the installed mutation."
  @spec committed({:ok, binary()} | {:error, :enoent}, binary() | :deleted) :: t()
  def committed({:error, :enoent}, content) when is_binary(content),
    do: %__MODULE__{before: :absent, after: content}

  def committed({:ok, content}, :deleted), do: %__MODULE__{before: content, after: :absent}

  def committed({:ok, before}, after_content) when is_binary(after_content),
    do: %__MODULE__{before: before, after: after_content}
end
