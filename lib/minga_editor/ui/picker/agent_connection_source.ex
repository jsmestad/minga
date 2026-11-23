defmodule MingaEditor.UI.Picker.AgentConnectionSource do
  @moduledoc """
  Connection actions for one captured workspace and Session target.

  The rows check a contributed route's setup, sign in to ChatGPT, add an API key, retry the connection, or continue a setup that is in progress. `/model` lists these rows itself while no model is listed. Once a model is listed, `/model` keeps only the in-progress rows and opens this source as a child picker from its "Connect another provider…" row; Escape returns to `/model`.

  A provider that a listed model already uses is connected. It offers its account actions, such as signing in again or signing out, instead of a first sign-in. Every item retains its original target because the picker closes before invoking its selection callback.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias MingaAgent.Credentials
  alias MingaAgent.Credentials.Snapshot
  alias MingaAgent.InferenceRoute.Spec, as: InferenceRouteSpec
  alias MingaAgent.InferenceRoute.Status, as: InferenceRouteStatus
  alias MingaAgent.Session
  alias MingaAgent.Session.ConnectionSnapshot
  alias MingaAgent.Session.ConnectionTarget
  alias MingaEditor.Agent.ConnectionAction
  alias MingaEditor.Agent.ConnectionPrompt
  alias MingaEditor.Agent.ConnectionSetup
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.Item.Status
  alias MingaEditor.UI.Picker.Source

  # An action row before it carries its origin: label, intent, description, and optional chip.
  @typep action :: {String.t(), term(), String.t(), Status.t() | nil}

  @impl true
  @spec title() :: String.t()
  def title, do: "Connect a provider"

  @impl true
  @spec layout() :: Source.layout()
  def layout, do: :centered

  @impl true
  @spec async?() :: boolean()
  def async?, do: true

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(context) do
    case async_fetch(context) do
      {:ok, items, _metadata} -> items
      {:error, _message} -> []
    end
  end

  @impl true
  @spec async_fetch(Context.t()) :: {:ok, [Item.t()], Source.fetch_meta()} | {:error, String.t()}
  def async_fetch(%Context{
        picker_ui: %{
          context: %{target: %ConnectionTarget{}, connected: %Snapshot{} = connected} = origin
        }
      }),
      do: {:ok, setup_items(origin, connected), %{}}

  def async_fetch(_context),
    do: {:error, "The original connection is unavailable. Reopen the agent workspace."}

  @doc """
  Rows that start or check a connection: route setup checks, ChatGPT sign-in, API keys, and retry.

  `connected` holds the credentials that listed models already use. Call this only off the Editor process, because route setup rows ask the Session for the registry's routes.
  """
  @spec setup_items(map(), Snapshot.t()) :: [Item.t()]
  def setup_items(%{target: %{session: session}} = origin, connected)
      when node(session) == node() do
    actions =
      oauth_actions(Snapshot.oauth_ref(connected)) ++ api_key_actions(connected) ++ retry_action()

    route_setup_items(origin) ++ Enum.map(actions, &action_item(&1, origin))
  end

  def setup_items(_remote, _connected), do: []

  @doc "Rows for a setup operation in progress: cancel, open or copy its authorization link, and resume its prompt."
  @spec pending_items(map()) :: [Item.t()]
  def pending_items(%{target: %{session: session}, connection: connection} = origin)
      when node(session) == node() do
    prompt = origin.connection_prompt

    (cancel_action(connection.operation) ++
       authorization_actions(prompt, connection) ++ resume_action(prompt, connection))
    |> Enum.map(&action_item(&1, origin))
  end

  def pending_items(_remote), do: []

  @impl true
  @spec on_select(Item.t(), EditorState.t()) :: EditorState.t()
  def on_select(
        %Item{meta: %{workspace_id: id, target: target, intent: {:connect, method}}},
        state
      ),
      do: ConnectionSetup.start(state, id, target, method)

  def on_select(
        %Item{meta: %{intent: {:authorization_url, action, %ConnectionPrompt{} = prompt}}},
        state
      ),
      do: ConnectionSetup.authorization_url(state, prompt, action)

  def on_select(%Item{meta: %{intent: {:resume, %ConnectionPrompt{} = prompt}}}, state),
    do: ConnectionSetup.resume(state, prompt)

  # The route check runs on the connection effect worker; the notice shows it is in progress.
  def on_select(
        %Item{
          meta: %{
            workspace_id: id,
            target: target,
            intent: {:check_route, _route_id, name} = intent
          }
        },
        state
      ) do
    state
    |> NoticeWorkflow.publish("Checking #{name}…")
    |> ConnectionAction.schedule(id, target, intent)
  end

  def on_select(%Item{meta: %{workspace_id: id, target: target, intent: intent}}, state),
    do: ConnectionAction.schedule(state, id, target, intent)

  @doc "Describes a route's readiness for its setup row, using the route's own account and remedy text."
  @spec setup_readiness(InferenceRouteStatus.t()) :: String.t()
  def setup_readiness(%{availability: {:ready, account}}), do: "Ready: #{account}"
  def setup_readiness(%{availability: {:unavailable, _reason, remedy}}), do: remedy
  def setup_readiness(%{availability: :unknown}), do: "Select to check"

  @doc "The chip for a route's availability: ready, unavailable, or not checked."
  @spec availability_status(InferenceRouteStatus.t()) :: Status.t()
  def availability_status(%{availability: {:ready, _account}}), do: Status.new(:ready, "Ready")

  def availability_status(%{availability: {:unavailable, _reason, _remedy}}),
    do: Status.new(:error, "Unavailable")

  def availability_status(%{availability: :unknown}), do: Status.new(:neutral, "Not checked")

  # Setup rows come from the registry in this fetch worker, after discovery refreshed route availability.
  @spec route_setup_items(map()) :: [Item.t()]
  defp route_setup_items(%{target: %{session: session}} = origin) do
    # minga:allow-blocking — only fetch workers call this (both sources' async?/0 are true)
    case Session.inference_route_setups(session) do
      {:ok, entries} ->
        Enum.map(entries, fn entry ->
          intent = {:check_route, entry.spec.id, InferenceRouteSpec.short_name(entry.spec)}
          with_origin(setup_item(entry), origin, intent)
        end)

      {:error, :unsupported} ->
        []
    end
  end

  # The chip shows readiness; the description keeps the action's own words and the account or
  # remedy.
  @spec setup_item(MingaAgent.InferenceRouteRegistry.Entry.t()) :: Item.t()
  defp setup_item(%{spec: %{setup_action: action} = spec, status: status}) do
    %Item{
      id: {:route_setup, spec.id},
      label: action.label,
      description: "#{action.description} · #{setup_detail(status)}",
      status: availability_status(status),
      search_text: "#{action.label} #{spec.display_name} setup"
    }
  end

  @spec setup_detail(InferenceRouteStatus.t()) :: String.t()
  defp setup_detail(%{availability: {:ready, account}}), do: account
  defp setup_detail(status), do: setup_readiness(status)

  # A signed-in ChatGPT account offers to sign in again, to switch or renew it, or to sign out.
  @spec oauth_actions(MingaAgent.ModelSelection.Credential.OAuth.t() | nil) :: [action()]
  defp oauth_actions(nil) do
    [
      {"Sign in with ChatGPT", {:connect, :oauth_browser},
       "Open browser authorization without sending your draft.", nil},
      {"Sign in with ChatGPT manually", {:connect, :oauth_manual},
       "Paste the redirect into masked input.", nil}
    ]
  end

  defp oauth_actions(_signed_in) do
    [
      {"Sign in to ChatGPT again", {:connect, :oauth_browser},
       "Switch or renew the account in your browser. Your draft is not sent.",
       Status.new(:ready, "Signed in")},
      {"Sign in to ChatGPT again manually", {:connect, :oauth_manual},
       "Paste the redirect into masked input.", nil},
      {"Sign out of ChatGPT", {:sign_out, "openai_codex"},
       "Remove the local ChatGPT sign-in. Its models leave this list.", nil}
    ]
  end

  # A stored key can be replaced or removed. A key from the environment takes precedence over a
  # stored key, so it offers nothing here.
  @spec api_key_actions(Snapshot.t()) :: [action()]
  defp api_key_actions(connected) do
    Credentials.known_providers()
    |> Enum.filter(&(Credentials.env_var_for(&1) != nil))
    |> Enum.flat_map(&api_key_action(&1, Snapshot.provider_source(connected, &1)))
  end

  @spec api_key_action(String.t(), Snapshot.source() | nil) :: [action()]
  defp api_key_action(provider, nil) do
    [
      {"Connect #{provider} with API key", {:connect, {:api_key, provider}},
       "Masked input keeps your draft.", nil}
    ]
  end

  defp api_key_action(provider, :file) do
    [
      {"Replace #{provider} API key", {:connect, {:api_key, provider}},
       "Masked input keeps your draft.", Status.new(:ready, "Connected")},
      {"Remove #{provider} API key", {:sign_out, provider}, "Delete the key that Minga stored.",
       nil}
    ]
  end

  defp api_key_action(_provider, :env), do: []

  @spec retry_action() :: [action()]
  defp retry_action,
    do: [
      {"Retry current connection", :retry, "Recheck credentials without sending your draft.", nil}
    ]

  @spec cancel_action(ConnectionSnapshot.operation()) :: [action()]
  defp cancel_action({:connecting, ref}),
    do: [
      {"Cancel connection setup", {:cancel, ref}, "Cancel only this offered setup operation.",
       nil}
    ]

  defp cancel_action(:idle), do: []

  @spec authorization_actions(ConnectionPrompt.t() | nil, ConnectionSnapshot.t()) :: [action()]
  defp authorization_actions(%ConnectionPrompt{authorization_url: url} = prompt, connection)
       when is_binary(url) do
    if ConnectionPrompt.current?(prompt, connection) do
      [
        {"Open authorization link", {:authorization_url, :open, prompt},
         "Open OpenAI in your browser.", nil},
        {"Copy authorization link", {:authorization_url, :copy, prompt},
         "Use another browser or device.", nil}
      ]
    else
      []
    end
  end

  defp authorization_actions(_prompt, _connection), do: []

  @spec resume_action(ConnectionPrompt.t() | nil, ConnectionSnapshot.t()) :: [action()]
  defp resume_action(%ConnectionPrompt{} = prompt, connection) do
    if ConnectionPrompt.current?(prompt, connection) do
      label =
        if is_binary(prompt.authorization_url),
          do: "Resume OpenAI sign-in",
          else: "Resume API key entry"

      [{label, {:resume, prompt}, "Open a blank masked prompt for this operation.", nil}]
    else
      []
    end
  end

  defp resume_action(nil, _connection), do: []

  @spec action_item(action(), map()) :: Item.t()
  defp action_item({label, intent, description, status}, origin) do
    with_origin(
      %Item{
        id: {:connection, intent},
        label: label,
        description: description,
        status: status,
        search_text: label
      },
      origin,
      intent
    )
  end

  @spec with_origin(Item.t(), map(), term()) :: Item.t()
  defp with_origin(item, origin, intent) do
    %{item | meta: %{workspace_id: origin.workspace_id, target: origin.target, intent: intent}}
  end
end
