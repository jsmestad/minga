defmodule MingaEditor.State.SessionTest do
  use ExUnit.Case, async: true

  alias MingaEditor.State.Session

  describe "native application quit transitions" do
    test "starts one request and classifies duplicate and stale request IDs" do
      session = Session.new()
      assert {:started, requesting} = Session.begin_application_quit(session, 7)
      assert requesting.application_quit == {:requesting, 7}
      assert {:duplicate, ^requesting} = Session.begin_application_quit(requesting, 7)
      assert {:stale, ^requesting} = Session.begin_application_quit(requesting, 8)
    end

    test "accepts only valid decision and completion transitions" do
      {:started, requesting} = Session.begin_application_quit(Session.new(), 7)
      assert {:ok, awaiting} = Session.await_application_quit_decision(requesting, 7)
      assert :stale = Session.await_application_quit_decision(Session.new(), 7)
      assert :stale = Session.await_application_quit_decision(requesting, 8)
      assert :stale = Session.await_application_quit_decision(awaiting, 7)

      assert {:ok, saving} = Session.start_application_quit_save(awaiting, 7)
      assert saving.application_quit == {:saving, 7}
      assert :stale = Session.start_application_quit_save(requesting, 7)
      assert :stale = Session.start_application_quit_save(awaiting, 8)

      for source <- [requesting, awaiting, saving] do
        assert {:ok, proceeding} = Session.proceed_application_quit(source, 7)
        assert proceeding.application_quit == {:proceeding, 7}
      end

      assert :stale = Session.proceed_application_quit(Session.new(), 7)
      assert :stale = Session.proceed_application_quit(awaiting, 8)
    end

    test "reserves and completes each lifecycle response only from its valid source tag" do
      {:started, requesting} = Session.begin_application_quit(Session.new(), 7)
      {:ok, awaiting} = Session.await_application_quit_decision(requesting, 7)
      {:ok, saving} = Session.start_application_quit_save(awaiting, 7)

      assert_response_transition(
        requesting,
        7,
        :inventory,
        :needs_decision,
        {:awaiting_decision, 7}
      )

      assert_response_transition(
        awaiting,
        7,
        :inventory,
        :needs_decision,
        {:awaiting_decision, 7}
      )

      assert_response_transition(requesting, 7, :inventory, :proceeding, {:proceeding, 7})
      assert_response_transition(awaiting, 7, :discard, :proceeding, {:proceeding, 7})
      assert_response_transition(saving, 7, :save, :proceeding, {:proceeding, 7})
      assert_response_transition(awaiting, 7, :cancel, :cancelled, :idle)
      assert_response_transition(saving, 7, :save, :save_failed, :idle)

      for {source, intent, outcome} <- [
            {requesting, :cancel, :cancelled},
            {requesting, :save, :save_failed},
            {awaiting, :save, :save_failed},
            {awaiting, :inventory, :proceeding},
            {saving, :inventory, :needs_decision},
            {saving, :cancel, :cancelled}
          ] do
        assert :stale = Session.prepare_application_quit_response(source, 7, intent, outcome)
      end

      assert :stale =
               Session.prepare_application_quit_response(awaiting, 8, :discard, :proceeding)

      assert :stale = Session.complete_application_quit_response(awaiting, 7, :proceeding)
    end

    test "reopens undelivered Proceeding responses according to their recorded policy intent" do
      {:started, requesting} = Session.begin_application_quit(Session.new(), 7)
      {:ok, awaiting} = Session.await_application_quit_decision(requesting, 7)
      {:ok, saving} = Session.start_application_quit_save(awaiting, 7)

      {:ok, inventory_response} =
        Session.prepare_application_quit_response(requesting, 7, :inventory, :proceeding)

      assert {:inventory, reinventorying} =
               Session.reconcile_application_quit_proceeding(inventory_response, 7)

      assert reinventorying.application_quit == {:requesting, 7}

      {:ok, save_response} =
        Session.prepare_application_quit_response(saving, 7, :save, :proceeding)

      assert {:save, resaving} =
               Session.reconcile_application_quit_proceeding(save_response, 7)

      assert resaving.application_quit == {:saving, 7}

      {:ok, discard_response} =
        Session.prepare_application_quit_response(awaiting, 7, :discard, :proceeding)

      assert {:discard, ^discard_response} =
               Session.reconcile_application_quit_proceeding(discard_response, 7)

      assert :stale = Session.reconcile_application_quit_proceeding(save_response, 8)
    end

    test "cancel clears every cancellable tag and makes retry possible" do
      {:started, requesting} = Session.begin_application_quit(Session.new(), 7)
      {:ok, awaiting} = Session.await_application_quit_decision(requesting, 7)
      {:ok, saving} = Session.start_application_quit_save(awaiting, 7)

      for source <- [requesting, awaiting, saving] do
        assert {:ok, idle} = Session.cancel_application_quit(source, 7)
        assert idle.application_quit == :idle
        assert {:started, retrying} = Session.begin_application_quit(idle, 8)
        assert retrying.application_quit == {:requesting, 8}
      end

      assert :stale = Session.cancel_application_quit(Session.new(), 7)
      assert :stale = Session.cancel_application_quit(awaiting, 8)

      {:ok, proceeding} = Session.proceed_application_quit(awaiting, 7)
      assert :stale = Session.cancel_application_quit(proceeding, 7)

      {:ok, responding} =
        Session.prepare_application_quit_response(awaiting, 7, :inventory, :needs_decision)

      assert {:ok, idle} = Session.cancel_application_quit(responding, 7)
      assert idle.application_quit == :idle
    end

    test "startup completion preserves an in-flight request" do
      {:started, requesting} = Session.begin_application_quit(Session.new(), 7)
      completed = Session.complete_startup(requesting, Session.new(session_dir: "/tmp/session"))

      assert completed.session_started?
      assert completed.application_quit == {:requesting, 7}
    end
  end

  defp assert_response_transition(source, request_id, intent, outcome, expected_completion) do
    assert {:ok, responding} =
             Session.prepare_application_quit_response(source, request_id, intent, outcome)

    assert responding.application_quit == {:responding, request_id, intent, outcome}

    assert {:ok, completed, ^intent} =
             Session.complete_application_quit_response(responding, request_id, outcome)

    assert completed.application_quit == expected_completion

    assert :stale =
             Session.complete_application_quit_response(responding, request_id + 1, outcome)
  end
end
