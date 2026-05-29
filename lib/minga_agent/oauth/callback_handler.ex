defmodule MingaAgent.OAuth.CallbackHandler do
  @moduledoc """
  Plug that receives the OAuth redirect on localhost.

  Runs under Bandit, extracts `code` and `state` query params from
  the callback GET, notifies the flow runner, and returns a success page.
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/callback" do
    conn = Plug.Conn.fetch_query_params(conn)
    code = conn.query_params["code"]
    state = conn.query_params["state"]

    has_code = is_binary(code) and code != ""

    case Process.whereis(:minga_oauth_flow) do
      pid when is_pid(pid) and has_code -> send(pid, {:oauth_callback, code, state})
      pid when is_pid(pid) -> send(pid, {:oauth_callback_error, :missing_code})
      nil -> :ok
    end

    if has_code do
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, success_html())
    else
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(400, error_html())
    end
  end

  match _ do
    send_resp(conn, 404, "")
  end

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

  defp error_html do
    """
    <!DOCTYPE html>
    <html>
    <head><title>Minga</title></head>
    <body style="font-family: system-ui, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0;">
      <div style="text-align: center;">
        <h2>Authentication failed</h2>
        <p>Missing authorization code. Please try again.</p>
      </div>
    </body>
    </html>
    """
  end
end
