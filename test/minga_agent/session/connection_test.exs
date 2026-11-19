defmodule MingaAgent.Session.ConnectionTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Session.Connection
  alias MingaAgent.Session.ConnectionTarget

  setup do
    connection = Connection.new()
    target = ConnectionTarget.new(self(), "conversation", nil, connection.epoch)
    owner = {self(), make_ref()}
    {:ok, pending, ref} = Connection.begin(connection, target, {:api_key, "openai"}, owner)
    {:cancelled, cancelled} = Connection.cancel(pending)
    {:committed, committed} = Connection.committed(pending)
    {:failed, failed} = Connection.failed(pending)

    %{
      target: target,
      owner: owner,
      ref: ref,
      pending: pending,
      tags: [
        none: connection,
        pending: pending,
        cancelled: cancelled,
        committed: committed,
        failed: failed
      ]
    }
  end

  test "every operation tag admits replacement work with a fresh receipt", context do
    for {_tag, connection} <- context.tags do
      assert {:ok, next, ref} =
               Connection.begin(
                 connection,
                 context.target,
                 {:api_key, "anthropic"},
                 context.owner
               )

      assert ref != context.ref
      assert Connection.authorize(next, context.target, ref, context.target) == :ok

      assert Connection.authorize(next, context.target, context.ref, context.target) ==
               {:error, :superseded}

      assert Connection.activity(next) == {:connecting, ref}
    end
  end

  test "each terminal transition explicitly accepts or rejects every source tag", context do
    for {tag, connection} <- context.tags do
      case tag do
        :pending ->
          assert {:cancelled, _} = Connection.cancel(connection)
          assert {:committed, _} = Connection.committed(connection)
          assert {:failed, _} = Connection.failed(connection)

        _terminal ->
          reason =
            %{
              none: :superseded,
              cancelled: :cancelled,
              committed: :already_committed,
              failed: :credential_store_failed
            }[tag]

          assert Connection.cancel(connection) == {:error, reason}
          assert Connection.committed(connection) == {:error, reason}
          assert Connection.failed(connection) == {:error, reason}
      end
    end
  end

  test "authorization distinguishes all tags and rejects wrong target or receipt", context do
    for {tag, connection} <- context.tags do
      expected =
        %{
          none: {:error, :superseded},
          pending: :ok,
          cancelled: {:error, :cancelled},
          committed: {:error, :already_committed},
          failed: {:error, :credential_store_failed}
        }[tag]

      assert Connection.authorize(connection, context.target, context.ref, context.target) ==
               expected

      assert Connection.authorize(connection, context.target, make_ref(), context.target) ==
               {:error, :superseded}

      other = ConnectionTarget.new(self(), "other", nil, make_ref())

      assert Connection.authorize(connection, other, context.ref, context.target) ==
               {:error, :stale_target}

      assert Connection.activity(connection) ==
               if(tag == :pending, do: {:connecting, context.ref}, else: :idle)
    end
  end

  test "worker registration and dependency death are exact and pending-only", context do
    worker = {self(), make_ref()}

    for {tag, connection} <- context.tags do
      case tag do
        :pending ->
          assert {:ok, bound} = Connection.register_worker(connection, worker)

          assert Connection.register_worker(bound, {self(), make_ref()}) ==
                   {:error, :worker_already_registered}

          assert {:cancelled, _} = Connection.dependency_down(bound, worker)
          assert {:cancelled, _} = Connection.dependency_down(bound, context.owner)
          assert Connection.dependency_down(bound, {self(), make_ref()}) == :unrelated

          assert Connection.pending(bound) ==
                   {context.ref, context.target, {:api_key, "openai"}, {context.owner, nil},
                    worker}

        _terminal ->
          assert Connection.register_worker(connection, worker) ==
                   {:error, :worker_already_registered}

          assert Connection.dependency_down(connection, worker) == :unrelated
          assert Connection.pending(connection) == nil
      end
    end
  end

  test "only the admitted method can select a credential writer", context do
    for {tag, connection} <- context.tags do
      assert Connection.match_method(connection, {:api_key, "anthropic"}) ==
               {:error, :method_mismatch}

      assert Connection.match_method(connection, {:api_key, "openai"}) ==
               if(tag == :pending, do: :ok, else: {:error, :method_mismatch})
    end
  end

  test "every tag invalidates on replacement, while own-refresh preserves committed receipt",
       context do
    for {tag, connection} <- context.tags do
      next = Connection.invalidate(connection)
      current = ConnectionTarget.new(self(), "conversation", nil, next.epoch)
      assert next.epoch != connection.epoch

      assert Connection.authorize(next, context.target, context.ref, current) ==
               {:error, :stale_target}

      assert Connection.activity(next) == :idle

      refreshed = Connection.selection_changed(connection)
      assert refreshed.epoch != connection.epoch
      expected = if tag == :committed, do: :already_committed, else: :stale_target
      current = ConnectionTarget.new(self(), "conversation", nil, refreshed.epoch)

      assert Connection.authorize(refreshed, context.target, context.ref, current) ==
               {:error, expected}
    end
  end

  test "problem facts retain typed resolution and provider kinds but ignore ordinary turn errors" do
    connection = Connection.new({:credential_unavailable, "openai:file"})

    assert Connection.problem(connection) ==
             {:resolution, {:credential_unavailable, "openai:file"}}

    connection = Connection.resolved(connection, nil)

    for kind <- [
          :auth_failed,
          :rate_limited,
          :unreachable,
          :invalid_model,
          :provider_error,
          :startup_failed
        ] do
      failed = Connection.provider_failed(connection, kind)
      assert Connection.problem(failed) == {:provider, kind}
      assert Connection.problem(Connection.provider_recovered(failed)) == nil
    end

    for kind <- [:tool_error, :internal_error, :context_transition_required, :unknown] do
      assert Connection.provider_failed(connection, kind) == connection
    end
  end
end
