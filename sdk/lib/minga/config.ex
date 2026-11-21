defmodule Minga.Config do
  @moduledoc "Reads editor configuration from extension callbacks. The SDK declaration is compile-time only."

  @doc "Returns the configured value for the named extension option."
  @spec get_extension_option(atom(), atom()) :: term()
  def get_extension_option(_extension, _option), do: raise("minga_sdk is compile-time only")
end
