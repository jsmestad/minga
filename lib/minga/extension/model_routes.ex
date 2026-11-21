defmodule Minga.Extension.ModelRoutes do
  @moduledoc """
  Extension API for contributing model routes to Minga's agent.

  Call `register/2` from your extension's `init/1`. The owning extension comes from the invocation context Minga installs around `init/1` and other extension callbacks, never from the arguments, so one extension cannot register a route for another. When the extension stops, its routes are removed.

  Registration returns a `MingaAgent.InferenceRoute.Reporter`. Keep it in your extension's state and pass it to `report_status/2` from any process, for example after the user signs in.

      def init(_config) do
        {:ok, reporter} =
          Minga.Extension.ModelRoutes.register(
            id: "my_gateway",
            module: MyGateway.Route,
            display_name: "My Gateway"
          )

        {:ok, %{reporter: reporter}}
      end

  `module` implements `MingaAgent.InferenceRoute`.
  """

  alias Minga.Extension.InvocationContext
  alias MingaAgent.InferenceRoute.Reporter
  alias MingaAgent.InferenceRouteRegistry

  @typedoc "Registration failure reason."
  @type register_error :: :no_extension_context | InferenceRouteRegistry.register_error()

  @doc """
  Registers a model route owned by the calling extension.

  Accepts `:id`, `:module`, and `:display_name`, plus an optional `:setup_action` (`label` and `description`) shown as a setup row in `/model`, and an optional `:config` keyword passed to the route's `models/1` callback whenever Minga lists its models. Options may include `:registry` to target a private registry.
  """
  @spec register(map() | keyword(), keyword()) ::
          {:ok, Reporter.t()} | {:error, register_error()}
  def register(attrs, opts \\ []) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)

    with {:ok, source} <- extension_source() do
      spec_attrs =
        attrs
        |> Map.take([:id, :module, :display_name, :setup_action])
        |> Map.put(:source, source)

      InferenceRouteRegistry.register(registry(opts), spec_attrs,
        config: Map.get(attrs, :config, [])
      )
    end
  end

  @doc """
  Reports availability through a reporter returned by `register/2`. Works from any process.

  `availability` is `{:ready, account_label}` or `{:unavailable, reason, remedy}`, the same shape `availability/2` returns. A reporter from an earlier registration, or for a route that was removed, is rejected.
  """
  @spec report_status(Reporter.t(), term(), keyword()) ::
          :ok | {:error, InferenceRouteRegistry.report_error()}
  def report_status(%Reporter{} = reporter, availability, opts \\ []) do
    InferenceRouteRegistry.report_status(registry(opts), reporter, availability)
  end

  @doc """
  Reports subscription limit windows through a reporter returned by `register/2`. Works from any process.

  Each window has `kind` (for example `"five_hour"`), `utilization` from 0 to 1, `resets_at` (a `DateTime` or nil), and `status` (`:allowed`, `:warning`, or `:rejected`). Report an empty list when you have no usage data; Minga then shows nothing. Usage is kept separately from availability, so either report leaves the other unchanged.
  """
  @spec report_usage(
          Reporter.t(),
          [MingaAgent.InferenceRoute.PlanWindow.t() | map() | keyword()],
          keyword()
        ) ::
          :ok | {:error, InferenceRouteRegistry.report_error()}
  def report_usage(%Reporter{} = reporter, windows, opts \\ []) when is_list(windows) do
    InferenceRouteRegistry.report_usage(registry(opts), reporter, windows)
  end

  @spec extension_source() :: {:ok, {:extension, atom()}} | {:error, :no_extension_context}
  defp extension_source do
    case InvocationContext.current_source() do
      {:ok, {:extension, name} = source} when is_atom(name) -> {:ok, source}
      _other -> {:error, :no_extension_context}
    end
  end

  @spec registry(keyword()) :: GenServer.server()
  defp registry(opts), do: Keyword.get(opts, :registry, InferenceRouteRegistry)
end
