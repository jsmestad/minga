defmodule Minga.Buffer.SaveIntent do
  @moduledoc """
  Captured destination and overwrite policy for an explicit-path save.

  The buffer process creates an intent before formatting starts and validates it again when the write commits. This keeps overwrite consent scoped to one target and lets persistence enforce exclusive creation when that target was absent.
  """

  @enforce_keys [:target, :overwrite, :expectation, :origin_buffer, :origin_path]
  defstruct [:target, :overwrite, :expectation, :origin_buffer, :origin_path]

  @type expectation :: :current_file | :absent | :any
  @type origin_path :: String.t() | nil
  @type t :: %__MODULE__{
          target: String.t(),
          overwrite: boolean(),
          expectation: expectation(),
          origin_buffer: pid(),
          origin_path: origin_path()
        }

  @doc "Creates an intent for the buffer's current file."
  @spec current_file(String.t(), String.t(), boolean(), pid()) :: t()
  def current_file(target, origin_path, overwrite, origin_buffer)
      when is_binary(target) and is_binary(origin_path) and is_boolean(overwrite) and
             is_pid(origin_buffer) do
    %__MODULE__{
      target: Path.expand(target),
      overwrite: overwrite,
      expectation: :current_file,
      origin_buffer: origin_buffer,
      origin_path: Path.expand(origin_path)
    }
  end

  @doc "Creates a non-forced intent for a destination that was absent when requested."
  @spec absent(String.t(), pid(), origin_path()) :: t()
  def absent(target, origin_buffer, origin_path)
      when is_binary(target) and is_pid(origin_buffer) do
    %__MODULE__{
      target: Path.expand(target),
      overwrite: false,
      expectation: :absent,
      origin_buffer: origin_buffer,
      origin_path: normalize_origin_path(origin_path)
    }
  end

  @doc "Creates an explicit overwrite intent for a captured destination."
  @spec overwrite(String.t(), pid(), origin_path()) :: t()
  def overwrite(target, origin_buffer, origin_path)
      when is_binary(target) and is_pid(origin_buffer) do
    %__MODULE__{
      target: Path.expand(target),
      overwrite: true,
      expectation: :any,
      origin_buffer: origin_buffer,
      origin_path: normalize_origin_path(origin_path)
    }
  end

  @doc "Validates that an intent has a coherent policy and belongs to the committing buffer."
  @spec validate(t(), pid()) :: :ok | {:error, :invalid_save_intent}
  def validate(
        %__MODULE__{
          target: target,
          overwrite: overwrite,
          expectation: expectation,
          origin_buffer: origin_buffer,
          origin_path: origin_path
        },
        origin_buffer
      )
      when is_pid(origin_buffer) and is_binary(target) and
             is_boolean(overwrite) and
             (is_binary(origin_path) or is_nil(origin_path)) do
    validate_policy(overwrite, expectation, target, origin_path)
  end

  def validate(%__MODULE__{}, _buffer), do: {:error, :invalid_save_intent}

  @spec validate_policy(boolean(), expectation(), String.t(), origin_path()) ::
          :ok | {:error, :invalid_save_intent}
  defp validate_policy(false, :current_file, target, origin_path) when is_binary(origin_path),
    do: validate_paths(target, origin_path)

  defp validate_policy(true, :current_file, target, origin_path) when is_binary(origin_path),
    do: validate_paths(target, origin_path)

  defp validate_policy(false, :absent, target, origin_path),
    do: validate_paths(target, origin_path)

  defp validate_policy(true, :any, target, origin_path),
    do: validate_paths(target, origin_path)

  defp validate_policy(_overwrite, _expectation, _target, _origin_path),
    do: {:error, :invalid_save_intent}

  @spec validate_paths(String.t(), origin_path()) :: :ok | {:error, :invalid_save_intent}
  defp validate_paths(target, origin_path) do
    if canonical_spelling?(target) and (is_nil(origin_path) or canonical_spelling?(origin_path)) do
      :ok
    else
      {:error, :invalid_save_intent}
    end
  end

  @spec canonical_spelling?(String.t()) :: boolean()
  defp canonical_spelling?(path), do: Path.type(path) == :absolute and Path.expand(path) == path

  @spec normalize_origin_path(origin_path()) :: origin_path()
  defp normalize_origin_path(path) when is_binary(path), do: Path.expand(path)
  defp normalize_origin_path(nil), do: nil
end
