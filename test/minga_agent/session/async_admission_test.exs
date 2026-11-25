defmodule MingaAgent.Session.AsyncAdmissionTest do
  @moduledoc """
  A composer send is admitted when the provider has counted its prefix, however long that takes (#4296).

  The Apple tokenizer is replaced by a counter. A prefix that contains the uncounted rule is counted only when the test lets it, and the counter reports each such count. Nothing here waits on a clock: a count is held for as long as the test needs.
  """

  use ExUnit.Case, async: true

  alias MingaAgent.Credentials
  alias MingaAgent.Session
  alias MingaAgent.Test.ModelSelectionFixture

  @moduletag :tmp_dir
  @uncounted_rule "A rule nobody has counted"

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "project")
    File.mkdir_p!(Path.join(root, ".git"))
    File.write!(Path.join(root, "AGENTS.md"), "A first rule.\n")

    env = Map.new(Credentials.known_providers(), &{Credentials.env_var_for(&1), nil})
    credential_opts = [config_dir: dir, oauth_path: Path.join(dir, "oauth.json"), env: env]
    owner = self()

    # A count is held by what it counts, not by when it runs: only a prefix with the uncounted
    # rule waits for the test, so a count the Session started on its own cannot slip past.
    counter = fn texts, candidates, _tools, _reserve ->
      held? = Enum.any?(texts, &(&1 =~ @uncounted_rule))
      if held?, do: send(owner, {:counting, self()})

      counts =
        for candidate <- candidates do
          candidate |> Enum.map_join("\n\n", &Enum.at(texts, &1)) |> byte_size() |> div(4)
        end

      receive do
        :count -> {:ok, %{counts: counts, context: 4_096}}
        {:fail, reason} -> {:error, reason}
      after
        if(held?, do: :infinity, else: 0) -> {:ok, %{counts: counts, context: 4_096}}
      end
    end

    # The model never answers, so an admitted turn stays working.
    silent_model = fn _model, _messages, _opts ->
      receive do
        :never -> {:error, :unreachable}
      end
    end

    session =
      start_supervised!(
        {Session,
         provider: MingaAgent.Providers.Native,
         provider_opts: [
           credential_opts: credential_opts,
           project_root: root,
           apple_counter: counter,
           llm_client: silent_model,
           model_resolver_opts:
             ModelSelectionFixture.resolver_opts()
             |> Keyword.delete(:credential_snapshot)
             |> Keyword.put(:apple_availability_fn, fn -> {:ok, 4_096} end)
         ],
         persist?: false,
         hooks_enabled?: false,
         session_start_hook_enabled?: false,
         recover_interrupted_work?: false},
        id: make_ref()
      )

    assert :ok = Session.set_model(session, "apple:system")
    %{session: session, root: root}
  end

  # A changed instructions file is a prefix the provider has not counted yet.
  defp cold(root) do
    File.write!(
      Path.join(root, "AGENTS.md"),
      "#{@uncounted_rule}, #{System.unique_integer()}.\n"
    )
  end

  defp composer_send(session, send, content),
    do: :gen_server.send_request(session, {:composer_send, send, content})

  # `wait_response/2` leaves an unanswered request open, so it can be asked again.
  defp answer(request), do: :gen_server.wait_response(request, 10_000)
  defp unanswered?(request), do: :gen_server.wait_response(request, 0) == :timeout

  defp shown_stop_target(session) do
    assert_receive {:agent_event, ^session, {:stop_target_changed, {_record, _turn} = target}}
    target
  end

  defp finished(counting) do
    monitor = Process.monitor(counting)
    assert_receive {:DOWN, ^monitor, :process, ^counting, _reason}
  end

  defp system_messages(session) do
    for {:system, text, _level} <- Session.messages(session), do: text
  end

  test "a send on a cold count is admitted when the count ends, with one stable turn target", %{
    session: session,
    root: root
  } do
    assert :ok = Session.subscribe(session, self())
    cold(root)
    record = Session.session_id(session)
    request = composer_send(session, {:idle, record}, "hi")
    assert_receive {:counting, counting}

    # The count is held: the Session is admitting, shown as working with a turn to stop, and
    # has not answered.
    assert Session.status(session) == :thinking
    assert {^record, turn} = shown_stop_target(session)
    assert unanswered?(request)
    refute {:user, "hi"} in Session.messages(session)

    send(counting, :count)
    assert {:reply, {:sent, _queue_target}} = answer(request)
    assert {:user, "hi"} in Session.messages(session)

    # The turn that started is the one the admission showed.
    assert {:error, :stale_turn} = Session.stop_turn(session, {record, "another-turn"})
    assert :ok = Session.stop_turn(session, {record, turn})
  end

  test "a prompt during admission queues like a prompt during a working turn", %{
    session: session,
    root: root
  } do
    cold(root)
    request = composer_send(session, :prompt, "first")
    assert_receive {:counting, counting}

    assert {:queued, :steering} = Session.send_prompt(session, "second")
    assert unanswered?(request)

    send(counting, :count)
    assert {:reply, {:sent, _queue_target}} = answer(request)
    assert {:user, "first"} in Session.messages(session)
    refute {:user, "second"} in Session.messages(session)
    refute Enum.any?(system_messages(session), &(&1 =~ "not sent"))
  end

  test "a Stop during admission keeps the draft, and the count still serves the next send", %{
    session: session,
    root: root
  } do
    assert :ok = Session.subscribe(session, self())
    cold(root)
    record = Session.session_id(session)
    request = composer_send(session, {:idle, record}, "hi")
    assert_receive {:counting, counting}
    assert {^record, turn} = shown_stop_target(session)

    assert :ok = Session.stop_turn(session, {record, turn})
    assert {:reply, {:error, reason}} = answer(request)
    assert reason =~ "Stopped before the message was sent. Your draft is preserved."
    assert Session.status(session) == :stopped
    refute {:user, "hi"} in Session.messages(session)

    # The count was not stopped with its waiter. Its result admits the next send at once.
    send(counting, :count)
    finished(counting)
    assert {:reply, {:sent, _target}} = answer(composer_send(session, {:idle, record}, "hi"))
    refute_received {:counting, _again}
  end

  test "a new conversation during admission answers the send, and the late count starts nothing",
       %{session: session, root: root} do
    cold(root)
    request = composer_send(session, :prompt, "hi")
    assert_receive {:counting, counting}

    assert :ok = Session.new_session(session)
    assert {:reply, {:error, reason}} = answer(request)
    assert reason =~ "the conversation changed before the message was sent"

    # The count ends after its conversation was replaced: the Session keeps running and the
    # new conversation has no message from the old one.
    send(counting, :count)
    finished(counting)
    assert Session.status(session) == :idle
    refute {:user, "hi"} in Session.messages(session)
    assert {:reply, {:sent, _target}} = answer(composer_send(session, :prompt, "again"))
  end

  test "a count whose helper exits is refused in plain words, without the raw reason", %{
    session: session,
    root: root
  } do
    cold(root)
    request = composer_send(session, :prompt, "hi")
    assert_receive {:counting, counting}

    # The Session answers this only after it has taken the send, so the send is waiting for the
    # count before the count fails.
    assert Session.status(session) == :thinking
    send(counting, {:fail, {:apple_helper_exit, 137}})
    assert {:reply, {:error, reason}} = answer(request)
    assert reason =~ "could not count its fixed instructions and tools. Try again"
    refute reason =~ "apple_helper_exit"
    refute Enum.any?(system_messages(session), &(&1 =~ "apple_helper_exit"))
    assert Session.status(session) == :error
  end

  test "a count that fails ends in a failed state that keeps the draft and says what to do", %{
    session: session,
    root: root
  } do
    cold(root)
    request = composer_send(session, :prompt, "hi")
    assert_receive {:counting, counting}

    # The Session answers this only after it has taken the send, so the send is waiting for the
    # count before the count fails.
    assert Session.status(session) == :thinking
    send(counting, {:fail, :apple_count_timeout})
    assert {:reply, {:error, reason}} = answer(request)
    assert reason =~ "did not finish counting its fixed instructions and tools. Try again"
    assert Session.status(session) == :error
    refute {:user, "hi"} in Session.messages(session)

    assert Enum.any?(
             system_messages(session),
             &(&1 =~ "Prompt not sent:" and &1 =~ "Your draft is preserved.")
           )
  end

  test "the count is warmed when a driver attaches, so the first send needs no wait", %{
    session: session,
    root: root
  } do
    cold(root)
    assert :ok = Session.subscribe(session, self())

    # No send has been made: the count below is the warm one.
    assert_receive {:counting, counting}
    send(counting, :count)
    finished(counting)

    assert {:reply, {:sent, _target}} = answer(composer_send(session, :prompt, "hi"))
    refute_received {:counting, _again}
  end
end
