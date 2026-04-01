defmodule Minga.Runtime do
  @moduledoc """
  Boots the Minga runtime without any frontend or editor.

  This is the headless entry point. Foundation (Layer 0), Services (Layer 1),
  and Agent are fully functional. No rendering, no input handling, no Port.

  ## Supervision Tree

      Minga.Runtime.Headless (rest_for_one)
      ├── Minga.Foundation.Supervisor
      ├── Minga.Buffer.Registry
      ├── Minga.Buffer.Supervisor
      ├── Minga.Services.Supervisor
      └── MingaAgent.Supervisor

  Use `start/1` to boot the headless runtime in tests or standalone scripts
  that need agent capabilities without an editor UI.

  ## Options

    * `:gateway` - starts the API gateway after boot. Pass `true` for
      default settings (port 4820), or a keyword list with options like
      `[port: 9000]`. Default: `false`.
  """

  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts \\ []) do
    children = [
      Minga.Foundation.Supervisor,
      {Registry, keys: :unique, name: Minga.Buffer.Registry},
      {DynamicSupervisor, name: Minga.Buffer.Supervisor, strategy: :one_for_one},
      Minga.Services.Supervisor,
      MingaAgent.Supervisor
    ]

    case Supervisor.start_link(children, strategy: :rest_for_one, name: Minga.Runtime.Headless) do
      {:ok, sup} ->
        maybe_start_gateway(opts)
        {:ok, sup}

      error ->
        error
    end
  end

  @spec maybe_start_gateway(keyword()) :: :ok
  defp maybe_start_gateway(opts) do
    case Keyword.get(opts, :gateway, false) do
      false ->
        :ok

      true ->
        MingaAgent.Runtime.start_gateway([])
        :ok

      gateway_opts when is_list(gateway_opts) ->
        MingaAgent.Runtime.start_gateway(gateway_opts)
        :ok
    end
  end
end
