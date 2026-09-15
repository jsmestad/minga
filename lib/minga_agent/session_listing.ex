defmodule MingaAgent.SessionListing do
  @moduledoc """
  A registered agent session and the result of its metadata query.

  The session manager owns the stable ID and PID. Metadata belongs to the session process and can be temporarily unavailable without changing that registration. Unavailable reasons are deliberately small and safe to expose through public listing APIs.
  """

  alias MingaAgent.Session
  alias MingaAgent.SessionMetadata

  @typedoc "A safe public reason for unavailable session metadata."
  @type unavailable_reason :: :timeout | :unreachable | :invalid_details

  @typedoc "Metadata query result for a registered session."
  @type details :: {:available, SessionMetadata.t()} | {:unavailable, unavailable_reason()}

  @enforce_keys [:id, :pid, :details]
  defstruct [:id, :pid, :details]

  @type t :: %__MODULE__{
          id: String.t(),
          pid: pid(),
          details: details()
        }

  @doc "Reads metadata for a registered session without changing its registration."
  @spec read(String.t(), pid()) :: t()
  def read(id, pid) when is_binary(id) and is_pid(pid) do
    id
    |> available(pid, Session.metadata(pid))
  catch
    :exit, reason -> unavailable(id, pid, unavailable_reason(reason))
  end

  @doc "Creates a listing with available metadata when its ID matches the registration."
  @spec available(String.t(), pid(), term()) :: t()
  def available(id, pid, %SessionMetadata{id: id} = metadata)
      when is_binary(id) and is_pid(pid) do
    %__MODULE__{id: id, pid: pid, details: {:available, metadata}}
  end

  def available(id, pid, %SessionMetadata{}) when is_binary(id) and is_pid(pid) do
    unavailable(id, pid, :invalid_details)
  end

  def available(id, pid, _details) when is_binary(id) and is_pid(pid) do
    unavailable(id, pid, :invalid_details)
  end

  @doc "Creates a listing whose metadata is unavailable for a safe public reason."
  @spec unavailable(String.t(), pid(), unavailable_reason()) :: t()
  def unavailable(id, pid, reason)
      when is_binary(id) and is_pid(pid) and
             reason in [:timeout, :unreachable, :invalid_details] do
    %__MODULE__{id: id, pid: pid, details: {:unavailable, reason}}
  end

  @doc "Returns available metadata or the safe reason that it is unavailable."
  @spec details(t()) :: details()
  def details(%__MODULE__{details: details}), do: details

  @doc "Returns the stable registration identity."
  @spec identity(t()) :: {String.t(), pid()}
  def identity(%__MODULE__{id: id, pid: pid}), do: {id, pid}

  @spec unavailable_reason(term()) :: unavailable_reason()
  defp unavailable_reason({:timeout, _call}), do: :timeout
  defp unavailable_reason({:noproc, _call}), do: :unreachable
  defp unavailable_reason({:normal, _call}), do: :unreachable
  defp unavailable_reason(_reason), do: :unreachable
end
