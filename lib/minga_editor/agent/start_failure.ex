defmodule MingaEditor.Agent.StartFailure do
  @moduledoc """
  Why an Agent tab could not start, as one plain sentence, and the one action that can fix it.

  Each constructor names a cause and owns its classification: the sentence the user reads and the remedy the tab offers. A sentence never contains a raw Elixir term; the producer logs the raw reason.

  A remedy is `{:retry, target}`, `:set_up_provider`, or nil when nothing in this tab can fix the failure. A retry target is the `MingaEditor.Agent.StartRequest` of a start that never bound a session, which runs that start again in the same workspace, or `:provider` when the session exists and only its provider failed, which retries the provider on that session.
  """

  alias MingaAgent.Session.ConnectionSnapshot
  alias MingaEditor.Agent.StartRequest

  @enforce_keys [:message, :remedy]
  defstruct @enforce_keys

  @typedoc "What a retry runs again: the unbound start, or the bound session's provider."
  @type retry_target :: StartRequest.t() | :provider

  @type remedy :: {:retry, retry_target()} | :set_up_provider

  @type t :: %__MODULE__{message: String.t(), remedy: remedy() | nil}

  @doc "The model catalog could not load, so the start was never requested."
  @spec catalog_unavailable(StartRequest.t()) :: t()
  def catalog_unavailable(%StartRequest{} = request),
    do: retry("The model catalog could not be loaded.", request)

  @doc "The session did not start before the start deadline."
  @spec timed_out(StartRequest.t()) :: t()
  def timed_out(%StartRequest{} = request),
    do: retry("The Agent took too long to start.", request)

  @doc "The session manager refused or failed the start. The raw `reason` is for the log only."
  @spec session_error(term(), StartRequest.t()) :: t()
  def session_error({:noproc, _detail}, %StartRequest{} = request), do: service_down(request)
  def session_error(:noproc, %StartRequest{} = request), do: service_down(request)

  def session_error(_reason, %StartRequest{} = request),
    do: retry("The Agent session could not be created.", request)

  @doc "No Agent workspace existed to start the session in."
  @spec no_workspace(StartRequest.t()) :: t()
  def no_workspace(%StartRequest{} = request),
    do: retry("There was no Agent tab to start the session in.", request)

  @doc """
  The attached session stopped unexpectedly.

  A local session can be replaced, so a retry starts a new session in the same tab. A session hosted on another node cannot be started from this tab, so it offers no remedy; the user reconnects through the remote session flow.
  """
  @spec session_crashed(pid()) :: t()
  def session_crashed(session) when is_pid(session) and node(session) != node(),
    do: %__MODULE__{message: "The remote Agent session stopped unexpectedly.", remedy: nil}

  def session_crashed(session) when is_pid(session),
    do: retry("The Agent session stopped unexpectedly.", StartRequest.default())

  @doc """
  The session started but its provider did not.

  Without configured credentials the provider cannot start, so the remedy is setting up a provider; otherwise the provider is retried on the same session.
  """
  @spec provider_startup_failed(ConnectionSnapshot.t()) :: t()
  def provider_startup_failed(%ConnectionSnapshot{credential_readiness: :unconfigured}),
    do: missing_credentials()

  def provider_startup_failed(%ConnectionSnapshot{}),
    do: retry("The Agent provider could not start.", :provider)

  @doc "No provider has credentials, so nothing can start until one is set up."
  @spec missing_credentials() :: t()
  def missing_credentials,
    do: %__MODULE__{message: "No Agent provider is set up yet.", remedy: :set_up_provider}

  @spec service_down(StartRequest.t()) :: t()
  defp service_down(request), do: retry("The Agent service is not running.", request)

  @spec retry(String.t(), retry_target()) :: t()
  defp retry(message, target), do: %__MODULE__{message: message, remedy: {:retry, target}}
end
