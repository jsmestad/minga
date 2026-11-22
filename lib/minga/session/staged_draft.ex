defmodule Minga.Session.StagedDraft do
  @moduledoc """
  One staged agent edit that is not yet published to disk.

  A draft carries everything needed to republish it safely after a restart: the project-relative `path`, the `base` bytes of the file when the edit was staged (`nil` when the file did not exist), and the staged `content` (`:deleted` for a staged deletion). Publication compares `base` with the file on disk, so a file that changed since staging is merged or reported as a conflict instead of being overwritten.
  """

  @typedoc "A staged change: new file bytes, or a deletion."
  @type content :: binary() | :deleted

  @type t :: %__MODULE__{
          path: String.t(),
          base: binary() | nil,
          content: content()
        }

  @enforce_keys [:path, :base, :content]
  defstruct [:path, :base, :content]

  @doc "Builds a draft for a project-relative path."
  @spec new(String.t(), binary() | nil, content()) :: t()
  def new(path, base, content)
      when is_binary(path) and (is_binary(base) or is_nil(base)) and
             (is_binary(content) or content == :deleted) do
    %__MODULE__{path: path, base: base, content: content}
  end

  @doc "Returns the SHA-256 fingerprint of the base, or `nil` when the file did not exist at staging."
  @spec base_fingerprint(t()) :: String.t() | nil
  def base_fingerprint(%__MODULE__{base: nil}), do: nil
  def base_fingerprint(%__MODULE__{base: base}), do: fingerprint(base)

  @doc """
  Returns whether the file on disk differs from the draft's base.

  `disk` is the result of reading the file now: `{:ok, bytes}` or `{:error, :enoent}`.
  """
  @spec base_changed?(t(), {:ok, binary()} | {:error, term()}) :: boolean()
  def base_changed?(%__MODULE__{base: nil}, {:error, :enoent}), do: false
  def base_changed?(%__MODULE__{base: nil}, _disk), do: true
  def base_changed?(%__MODULE__{base: base}, {:ok, disk}) when is_binary(base), do: disk != base
  def base_changed?(%__MODULE__{}, _disk), do: true

  @doc "Returns a fingerprint of the whole draft, used to skip rewriting an unchanged draft."
  @spec digest(t()) :: binary()
  def digest(%__MODULE__{} = draft) do
    :crypto.hash(:sha256, :erlang.term_to_binary({draft.path, draft.base, draft.content}))
  end

  @doc "Returns the lowercase hex SHA-256 fingerprint of file bytes."
  @spec fingerprint(binary()) :: String.t()
  def fingerprint(bytes) when is_binary(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
