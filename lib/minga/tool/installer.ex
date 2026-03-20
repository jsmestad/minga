defmodule Minga.Tool.Installer do
  @moduledoc """
  Behaviour for tool installers.

  Each installation method (npm, pip, cargo, go install, GitHub releases)
  implements this behaviour. The `Tool.Manager` dispatches to the
  appropriate installer based on the recipe's `:method` field.

  ## DI pattern

  In production, `method_to_module/1` maps recipe methods to real
  installer modules. In tests, configure `:minga, :tool_installers`
  to inject stubs:

      config :minga, tool_installers: %{
        npm: Minga.Tool.Installer.Stub,
        github_release: Minga.Tool.Installer.Stub
      }
  """

  alias Minga.Tool.Recipe

  @typedoc "Progress stage reported during installation."
  @type progress_stage :: :downloading | :extracting | :installing | :linking | :verifying

  @typedoc "Progress callback invoked by installers to report status."
  @type progress_callback :: (progress_stage(), String.t() -> :ok)

  @callback install(Recipe.t(), dest_dir :: String.t(), progress_callback()) ::
              {:ok, version :: String.t()} | {:error, term()}

  @callback uninstall(Recipe.t(), dest_dir :: String.t()) ::
              :ok | {:error, term()}

  @callback installed_version(Recipe.t(), dest_dir :: String.t()) ::
              {:ok, String.t()} | nil

  @callback latest_version(Recipe.t()) ::
              {:ok, String.t()} | {:error, term()}

  @doc "Returns the installer module for a given method atom."
  @spec for_method(atom()) :: module()
  def for_method(method) when is_atom(method) do
    overrides = Application.get_env(:minga, :tool_installers, %{})

    case Map.get(overrides, method) do
      nil -> method_to_module(method)
      mod -> mod
    end
  end

  @spec method_to_module(atom()) :: module()
  defp method_to_module(:npm), do: Minga.Tool.Installer.Npm
  defp method_to_module(:pip), do: Minga.Tool.Installer.Pip
  defp method_to_module(:cargo), do: Minga.Tool.Installer.Cargo
  defp method_to_module(:go_install), do: Minga.Tool.Installer.GoInstall
  defp method_to_module(:github_release), do: Minga.Tool.Installer.GitHubRelease
end
