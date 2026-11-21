defmodule Minga.Extension.ModelRoutes do
  @moduledoc """
  Registers model routes that run inside Minga's agent loop.

  Call `register/2` from your extension's `init/1` and keep the returned reporter. `report_status/2` works from any process.

  This is a compile-time stub. At runtime, the real module in Minga's BEAM VM provides the implementation.
  """

  alias MingaAgent.InferenceRoute.Reporter

  @type register_error ::
          :no_extension_context
          | {:duplicate_route_id, String.t(), term(), term()}
          | {:invalid_spec, atom()}
          | {:invalid_route_module, module()}
          | {:invalid_models, term()}

  @type report_error :: :unknown_route | :stale_reporter | :invalid_status

  @spec register(map() | keyword(), keyword()) :: {:ok, Reporter.t()} | {:error, register_error()}
  def register(_attrs, _opts \\ []), do: raise("minga_sdk is compile-time only")

  @spec report_usage(Reporter.t(), [MingaAgent.InferenceRoute.PlanWindow.t() | map()], keyword()) ::
          :ok | {:error, report_error() | {:invalid_plan_window, atom()}}
  def report_usage(_reporter, _windows, _opts \\ []), do: raise("minga_sdk is compile-time only")

  @spec report_status(Reporter.t(), term(), keyword()) :: :ok | {:error, report_error()}
  def report_status(_reporter, _availability, _opts \\ []),
    do: raise("minga_sdk is compile-time only")
end
