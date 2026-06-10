defmodule MingaEditor.Frontend.Selection do
  @moduledoc """
  Resolves which terminal renderer implementation Minga launches.

  Go/Bubble Tea is the default terminal frontend. The Zig/libvaxis renderer
  remains available as a temporary escape hatch, selected with the documented
  `MINGA_FRONTEND` environment variable:

      MINGA_FRONTEND=zig bin/minga path/to/file

  `MINGA_FRONTEND=go` is the default and may be set explicitly. Any other value
  is an error: the launch path raises instead of silently falling back, so a
  typo never quietly boots the wrong renderer.

  This is the single source of truth for the terminal renderer choice. The
  `Frontend.Manager` (runtime binary path) and the `MingaGoTui` compiler (which
  renderer to build) both read from here.
  """

  @typedoc "Terminal renderer implementation."
  @type tui_impl :: :go | :zig

  @env_var "MINGA_FRONTEND"

  @doc """
  Returns the configured terminal renderer implementation.

  Resolution order:

    1. The `MINGA_FRONTEND` environment variable (`"go"` or `"zig"`).
    2. The `:tui_impl` application env (an atom or string), for tests.
    3. The default, `:go`.

  Raises `ArgumentError` when `MINGA_FRONTEND` is set to an unrecognized value.
  """
  @spec tui_impl() :: tui_impl()
  def tui_impl do
    case System.get_env(@env_var) do
      nil -> tui_impl_from_app_env()
      value -> parse!(value)
    end
  end

  @doc "Returns the runtime binary name for the given implementation."
  @spec renderer_binary_name(tui_impl()) :: String.t()
  def renderer_binary_name(:go), do: "minga-renderer-go"
  def renderer_binary_name(:zig), do: "minga-renderer"

  @doc "Returns the name of the selection environment variable."
  @spec env_var() :: String.t()
  def env_var, do: @env_var

  @spec tui_impl_from_app_env() :: tui_impl()
  defp tui_impl_from_app_env do
    case Application.get_env(:minga, :tui_impl, :go) do
      impl when impl in [:go, :zig] -> impl
      value when is_binary(value) -> parse!(value)
      other -> invalid!(inspect(other))
    end
  end

  @spec parse!(String.t()) :: tui_impl()
  defp parse!("go"), do: :go
  defp parse!("zig"), do: :zig
  defp parse!(value), do: invalid!(value)

  @spec invalid!(String.t()) :: no_return()
  defp invalid!(value) do
    raise ArgumentError,
          "#{@env_var}=#{value} is not a valid terminal frontend. Use \"go\" (default) or \"zig\"."
  end
end
