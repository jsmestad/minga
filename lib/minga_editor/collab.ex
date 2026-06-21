defmodule MingaEditor.Collab do
  @moduledoc """
  Orchestration seam for hosting per-client server-side editors on the daemon.

  Collab MVP (#2424): two clients on one host. Each attached client drives an
  independent editor session (its own `MingaEditor` + `Renderer.Server` +
  `Frontend.Manager`) while sharing the node-local `Minga.Buffer.Registry`, so
  two clients that open the same path resolve to one `Minga.Buffer.Process`.

  This module is the orchestration boundary that pairs an agent-session attach
  with the editor triad lifecycle:

  - `attach/4` brokers the agent attach through `MingaAgent.RemoteAPI.attach/4`,
    then starts the per-client editor triad named by the attach result's
    `editor_session_id`.
  - `detach/3` stops the per-client editor triad, then brokers the agent detach.

  Layering: `MingaAgent.RemoteAPI` (Layer 1) mints the deterministic
  `editor_session_id` but does not start editor processes. The triad lifecycle
  lives here (Layer 2), depending downward on the broker. That keeps the broker
  free of any dependency on editor orchestration.
  """

  alias MingaAgent.RemoteAPI
  alias MingaEditor.Collab.SessionManager

  @typedoc "Attach role."
  @type role :: RemoteAPI.role()

  @doc """
  Attaches a client to an agent session and starts its server-side editor.

  Brokers the attach through `MingaAgent.RemoteAPI.attach/4`, then starts the
  per-client editor triad. On a successful attach the returned
  `AttachResult.editor_session_id` names the client's editor. If the triad fails
  to start, the attach is rolled back (the client is detached) and the error is
  returned, so a failed editor start never leaves a half-attached client.

  Broker opts (`:role`, `:last_seen_event_id`) flow to `RemoteAPI.attach/4`;
  triad opts (`:backend`, `:swap_dir`, `:session_dir`) flow to
  `MingaEditor.Collab.SessionManager.start_session/2`.
  """
  @spec attach(String.t(), String.t(), pid(), keyword()) ::
          {:ok, RemoteAPI.attach_result()} | {:error, term()}
  def attach(session_id, token, subscriber_pid, opts \\ [])
      when is_binary(session_id) and is_binary(token) and is_pid(subscriber_pid) do
    {broker_opts, triad_opts} = Keyword.split(opts, [:role, :last_seen_event_id])

    with {:ok, result} <- RemoteAPI.attach(session_id, token, subscriber_pid, broker_opts),
         :ok <- start_editor(result.editor_session_id, triad_opts) do
      {:ok, result}
    else
      {:error, {:editor_start, reason}} ->
        RemoteAPI.detach(session_id, token, subscriber_pid)
        {:error, {:editor_start, reason}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Stops a client's server-side editor and detaches it from the agent session.

  Idempotent: safe to call when no triad is running. Always brokers the detach
  even if the editor teardown errors, so the agent session is left consistent.
  """
  @spec detach(String.t(), String.t(), pid()) :: :ok | {:error, term()}
  def detach(session_id, token, client_pid)
      when is_binary(session_id) and is_binary(token) and is_pid(client_pid) do
    editor_session_id = RemoteAPI.editor_session_id(session_id, client_pid)
    SessionManager.stop_session(editor_session_id)
    RemoteAPI.detach(session_id, token, client_pid)
  end

  @spec start_editor(String.t() | nil, keyword()) :: :ok | {:error, {:editor_start, term()}}
  defp start_editor(nil, _triad_opts), do: :ok

  defp start_editor(editor_session_id, triad_opts) do
    case SessionManager.start_session(editor_session_id, triad_opts) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, {:editor_start, reason}}
    end
  end
end
