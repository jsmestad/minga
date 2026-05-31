defmodule MingaAgent.OAuth.CallbackHandler do
  @moduledoc """
  Plug that receives the OAuth redirect on localhost.

  Runs under Bandit, extracts `code` and `state` query params from
  the callback GET, notifies the flow runner, and returns a success page.
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/auth/callback" do
    handle_callback(conn)
  end

  get "/callback" do
    handle_callback(conn)
  end

  match _ do
    send_resp(conn, 404, "")
  end

  defp handle_callback(conn) do
    conn = Plug.Conn.fetch_query_params(conn)
    event = callback_event(conn.query_params)
    notify_flow(event)

    case event do
      {:oauth_callback, _code, _state} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, success_html())

      {:oauth_callback_error, {:provider_error, message}} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(400, error_html(message))

      {:oauth_callback_error, :missing_code} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(400, error_html("Missing authorization code. Please try again."))
    end
  end

  @doc false
  @spec callback_event(map()) ::
          {:oauth_callback, String.t(), String.t() | nil}
          | {:oauth_callback_error, {:provider_error, String.t()} | :missing_code}
  def callback_event(%{"code" => code, "state" => state}) when is_binary(code) and code != "" do
    {:oauth_callback, code, state}
  end

  def callback_event(%{"code" => code}) when is_binary(code) and code != "" do
    {:oauth_callback, code, nil}
  end

  def callback_event(%{"error" => error} = params) when is_binary(error) and error != "" do
    description = Map.get(params, "error_description")
    {:oauth_callback_error, {:provider_error, provider_error_message(error, description)}}
  end

  def callback_event(_params), do: {:oauth_callback_error, :missing_code}

  defp notify_flow(event) do
    case Process.whereis(:minga_oauth_flow) do
      pid when is_pid(pid) -> send(pid, event)
      nil -> :ok
    end
  end

  defp provider_error_message(error, description)
       when is_binary(description) and description != "" do
    "#{error}: #{description}"
  end

  defp provider_error_message(error, _description), do: error

  defp success_html do
    """
    <!DOCTYPE html>
    <html>
    <head><title>Minga</title></head>
    <body style="font-family: system-ui, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0;">
      <div style="text-align: center;">
        <h2>Received</h2>
        <p>You can close this tab and return to Minga.</p>
      </div>
      <script>window.close();</script>
    </body>
    </html>
    """
  end

  defp error_html(message) do
    escaped_message = html_escape(message)

    """
    <!DOCTYPE html>
    <html>
    <head><title>Minga</title></head>
    <body style="font-family: system-ui, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0;">
      <div style="text-align: center;">
        <h2>Authentication failed</h2>
        <p>#{escaped_message}</p>
      </div>
    </body>
    </html>
    """
  end

  defp html_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
