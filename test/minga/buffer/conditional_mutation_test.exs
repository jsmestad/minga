defmodule Minga.Buffer.ConditionalMutationTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Buffer.FileMutation
  alias Minga.Buffer.Fork

  for owner <- [:buffer, :fork] do
    describe "#{owner} conditional mutation" do
      @describetag owner: owner

      setup %{owner: owner} do
        parent = start_supervised!({Buffer, content: "one\ntwo\nthree"})

        {server, api} =
          case owner do
            :buffer ->
              {parent, Buffer}

            :fork ->
              fork = start_supervised!({Fork, parent: parent, content: Buffer.content(parent)})
              {fork, Fork}
          end

        %{server: server, api: api, identity: {owner, "/owned-file"}, parent: parent}
      end

      test "commits a whole ordered batch with one version increment", ctx do
        expected = revision(ctx)
        edits = [{"one", "first\nextra"}, {"three", "last"}]

        assert :ok = mutate(ctx, expected, {:edit, edits})
        assert Buffer.content_with_version(ctx.server) == {"first\nextra\ntwo\nlast", 1}
        assert Buffer.dirty?(ctx.server)

        if ctx.api == Fork do
          assert Buffer.content(ctx.parent) == "one\ntwo\nthree"
        end
      end

      test "a failing middle edit discards the entire preparation", ctx do
        edits = [{"one", "ONE"}, {"missing", "TWO"}, {"three", "THREE"}]

        assert {:error, {:edit_failed, 2, :not_found}} =
                 mutate(ctx, revision(ctx), {:edit, edits})

        assert Buffer.content_with_version(ctx.server) == {"one\ntwo\nthree", 0}
        refute Buffer.dirty?(ctx.server)
      end

      test "rejects ambiguous, overlapping, invalid and empty batches without mutation", ctx do
        for {edits, reason} <- [
              {[{"one", "two"}, {"two", "second"}], {:edit_failed, 2, :ambiguous_match}},
              {[{"one", "first"}, {"first", "again"}], {:edit_failed, 2, :overlapping_edit}},
              {[{"", "insert"}], {:edit_failed, 1, :invalid_edit}},
              {[{"one", <<255>>}], {:edit_failed, 1, :invalid_text}},
              {[], :invalid_operation}
            ] do
          assert {:error, ^reason} = mutate(ctx, revision(ctx), {:edit, edits})
          assert Buffer.content_with_version(ctx.server) == {"one\ntwo\nthree", 0}
          refute Buffer.dirty?(ctx.server)
        end
      end

      test "rejects a duplicated original target", ctx do
        assert :ok = mutate(ctx, revision(ctx), {:replace, "same\nsame"})
        before = Buffer.content_with_version(ctx.server)

        assert {:error, {:edit_failed, 1, :ambiguous_match}} =
                 mutate(ctx, revision(ctx), {:edit, [{"same", "different"}]})

        assert Buffer.content_with_version(ctx.server) == before
      end

      test "handles Unicode and empty whole-file content in bulk", ctx do
        assert :ok = mutate(ctx, revision(ctx), {:replace, "café 👩🏽‍💻\n茶"})

        assert :ok =
                 mutate(ctx, revision(ctx), {:edit, [{"café", "☕"}, {"茶", "お茶"}]})

        assert Buffer.content_with_version(ctx.server) == {"☕ 👩🏽‍💻\nお茶", 2}
        assert :ok = mutate(ctx, revision(ctx), {:replace, ""})
        assert Buffer.content_with_version(ctx.server) == {"", 3}
        assert :ok = mutate(ctx, revision(ctx), {:replace, "filled"})
        assert Buffer.content_with_version(ctx.server) == {"filled", 4}
      end

      test "an intervening owner edit invalidates already prepared content", ctx do
        {content, generation} = Buffer.content_with_version(ctx.server)
        expected = revision(ctx)
        operation = {:replace, "agent\n"}

        assert {:ok, "agent\n"} =
                 FileMutation.prepare(
                   {:ok, content},
                   generation,
                   ctx.identity,
                   expected,
                   operation
                 )

        assert :ok = Buffer.replace_content(ctx.server, "human\n", :user)
        before = Buffer.content_with_version(ctx.server)

        assert {:error, :stale_revision} = mutate(ctx, expected, operation)
        assert Buffer.content_with_version(ctx.server) == before
        assert Buffer.content(ctx.server) == "human\n"
      end

      test "two concurrent edits of the same revision have exactly one winner", ctx do
        expected = revision(ctx)
        test = self()

        tasks =
          for replacement <- ["agent A", "agent B"] do
            Task.async(fn ->
              send(test, {:ready, self()})

              receive do
                :commit -> mutate(ctx, expected, {:replace, replacement})
              end
            end)
          end

        for task <- tasks do
          pid = task.pid
          assert_receive {:ready, ^pid}
        end

        for task <- tasks, do: send(task.pid, :commit)
        results = Enum.map(tasks, &Task.await/1)

        assert Enum.count(results, &(&1 == :ok)) == 1
        assert Enum.count(results, &(&1 == {:error, :stale_revision})) == 1
        assert {content, 1} = Buffer.content_with_version(ctx.server)
        assert content in ["agent A", "agent B"]
      end

      test "supports project view tokens without a generation", ctx do
        identity = {:project_view, "project/source"}
        expected = FileMutation.revision(Buffer.content(ctx.server), nil, identity)

        assert {:ok, %FileMutation.Receipt{after: "view"}} =
                 ctx.api.conditional_mutate(ctx.server, expected, {:replace, "view"}, identity)

        assert Buffer.content_with_version(ctx.server) == {"view", 1}
      end

      test "requires a revision and never creates over a present file", ctx do
        assert {:error, :revision_required} = mutate(ctx, :absent, {:replace, "bad"})

        reason = if ctx.api == Fork, do: :already_exists, else: :unsupported_operation
        assert {:error, ^reason} = mutate(ctx, :absent, {:create, "bad"})
        assert Buffer.content_with_version(ctx.server) == {"one\ntwo\nthree", 0}
        refute Buffer.dirty?(ctx.server)
      end
    end
  end

  test "a successful buffer batch is one agent undo entry and failure preserves redo" do
    server = start_supervised!({Buffer, content: "one two three"})
    ctx = %{server: server, api: Buffer, identity: {:buffer, "/undo-file"}}

    assert :ok = mutate(ctx, revision(ctx), {:edit, [{"one", "1"}, {"three", "3"}]})
    assert Buffer.version(server) == 1
    assert Minga.Buffer.Process.last_undo_source(server) == :agent
    assert :ok = Buffer.undo(server)
    assert Buffer.content(server) == "one two three"
    refute Buffer.dirty?(server)

    assert {:error, {:edit_failed, 2, :not_found}} =
             mutate(ctx, revision(ctx), {:edit, [{"one", "ONE"}, {"missing", "X"}]})

    assert :ok = Buffer.redo(server)
    assert Buffer.content(server) == "1 two 3"
    assert :ok = Buffer.undo(server)
    assert :ok = Buffer.undo(server)
    assert Buffer.content(server) == "one two three"
  end

  test "read-only buffers reject conditional edits without changing their revision" do
    server = start_supervised!({Buffer, content: "one", read_only: true})
    ctx = %{server: server, api: Buffer, identity: {:buffer, "/read-only"}}

    assert {:error, :read_only} = mutate(ctx, revision(ctx), {:edit, [{"one", "two"}]})
    assert Buffer.content_with_version(server) == {"one", 0}
    refute Buffer.dirty?(server)
  end

  test "fork publication merges current human edits rather than an earlier preview" do
    parent = start_supervised!({Buffer, content: "one\ntwo\nthree"})
    fork = start_supervised!({Fork, parent: parent, content: Buffer.content(parent)})
    ctx = %{server: fork, api: Fork, identity: {:fork, "/publication"}}

    assert :ok = mutate(ctx, revision(ctx), {:edit, [{"one", "agent"}]})
    assert {:ok, "agent\ntwo\nthree"} = Fork.merge(fork)
    assert :ok = Buffer.replace_content(parent, "one\ntwo\nhuman", :user)
    version = Buffer.version(parent)

    assert {:ok, "agent\ntwo\nhuman"} = Fork.publish(fork)
    assert Buffer.content(parent) == "agent\ntwo\nhuman"
    assert Buffer.version(parent) == version + 1
    assert Minga.Buffer.Process.last_undo_source(parent) == :agent
    Buffer.undo(parent)
    assert Buffer.content(parent) == "one\ntwo\nhuman"
    Buffer.undo(parent)
    assert Buffer.content(parent) == "one\ntwo\nthree"
  end

  test "fork publication leaves overlapping human edits and their undo history unchanged" do
    parent = start_supervised!({Buffer, content: "one\ntwo\nthree"})
    fork = start_supervised!({Fork, parent: parent, content: Buffer.content(parent)})
    Fork.replace_content(fork, "agent\ntwo\nthree")
    Buffer.replace_content(parent, "human\ntwo\nthree", :user)
    before = Buffer.content_with_version(parent)

    assert {:conflict, hunks} = Fork.publish(fork)
    assert Enum.any?(hunks, &match?({:conflict, _, _}, &1))
    assert Buffer.content_with_version(parent) == before
    Buffer.undo(parent)
    assert Buffer.content(parent) == "one\ntwo\nthree"
  end

  test "fork deletion is revision checked, isolated and undoable as one mutation" do
    parent = start_supervised!({Buffer, content: "unsaved café\n"})
    fork = start_supervised!({Fork, parent: parent, content: Buffer.content(parent)})
    ctx = %{server: fork, api: Fork, identity: {:fork, "/delete-file"}}
    expected = revision(ctx)

    assert {:error, :stale_revision} = mutate(ctx, "stale", :delete)
    assert Fork.status(fork) == :present
    assert Fork.version(fork) == 0
    assert :ok = mutate(ctx, expected, :delete)
    assert Fork.status(fork) == :deleted
    assert Fork.version(fork) == 1
    assert Fork.dirty?(fork)
    assert {:error, :enoent} = Fork.read_file(fork)
    assert {:error, :enoent} = Fork.content_with_version(fork)
    assert {:error, :enoent} = Fork.content_prefix_with_version(fork, 100)
    assert {:error, :enoent} = Fork.content_on_lines_with_version(fork, 0, 1, 100)
    assert Buffer.content(parent) == "unsaved café\n"
    assert {:error, :enoent} = mutate(ctx, expected, {:replace, "resurrect"})
    assert Fork.version(fork) == 1

    assert :ok = Fork.undo(fork)
    assert Fork.status(fork) == :present
    assert {:ok, "unsaved café\n"} = Fork.read_file(fork)
    assert Fork.version(fork) == 2
    refute Fork.dirty?(fork)
    assert {:error, :nothing_to_undo} = Fork.undo(fork)
  end

  test "fork batches create one undo entry" do
    parent = start_supervised!({Buffer, content: "one two three"})
    fork = start_supervised!({Fork, parent: parent, content: Buffer.content(parent)})
    ctx = %{server: fork, api: Fork, identity: {:fork, "/fork-undo"}}

    assert :ok = mutate(ctx, revision(ctx), {:edit, [{"one", "1"}, {"three", "3"}]})
    assert :ok = Fork.undo(fork)
    assert Fork.content(fork) == "one two three"
    assert {:error, :nothing_to_undo} = Fork.undo(fork)
  end

  test "fork deletion publication preserves the open parent's bytes" do
    parent = start_supervised!({Buffer, content: "original"})
    fork = start_supervised!({Fork, parent: parent, content: "original"})
    ctx = %{server: fork, api: Fork, identity: {:fork, "/delete-publication"}}
    assert :ok = mutate(ctx, revision(ctx), :delete)
    before = Buffer.content_with_version(parent)
    test = self()

    assert :ok =
             Fork.publish_deletion(fork, fn ->
               send(test, :deletion_published)
               :ok
             end)

    assert_receive :deletion_published
    assert Buffer.content_with_version(parent) == before
    assert Fork.status(fork) == :deleted
  end

  test "fork deletion publication rejects changed parent without invoking disk publication" do
    parent = start_supervised!({Buffer, content: "original"})
    fork = start_supervised!({Fork, parent: parent, content: "original"})
    ctx = %{server: fork, api: Fork, identity: {:fork, "/delete-conflict"}}
    assert :ok = mutate(ctx, revision(ctx), :delete)
    Buffer.replace_content(parent, "human", :user)
    test = self()

    assert {:conflict, :parent_changed} =
             Fork.publish_deletion(fork, fn ->
               send(test, :unexpected_publication)
               :ok
             end)

    refute_received :unexpected_publication
    assert Buffer.content(parent) == "human"
    assert Fork.status(fork) == :deleted
  end

  test "failed deletion publication retains fork and parent for recovery" do
    parent = start_supervised!({Buffer, content: "original"})
    fork = start_supervised!({Fork, parent: parent, content: "original"})
    ctx = %{server: fork, api: Fork, identity: {:fork, "/delete-failure"}}
    assert :ok = mutate(ctx, revision(ctx), :delete)

    assert {:error, :eacces} = Fork.publish_deletion(fork, fn -> {:error, :eacces} end)
    assert Fork.status(fork) == :deleted
    assert Fork.version(fork) == 1
    assert Buffer.content_with_version(parent) == {"original", 0}
    assert :ok = Fork.undo(fork)
    assert {:ok, "original"} = Fork.read_file(fork)
  end

  test "a dead deletion publication collaborator does not kill the parent owner" do
    parent = start_supervised!({Buffer, content: "original"})
    fork = start_supervised!({Fork, parent: parent, content: "original"})
    collaborator = start_supervised!({Agent, fn -> :ready end})
    ctx = %{server: fork, api: Fork, identity: {:fork, "/dead-deletion-collaborator"}}
    assert :ok = mutate(ctx, revision(ctx), :delete)
    GenServer.stop(collaborator)

    assert {:error,
            {:deletion_publication_failed,
             {:noproc, {GenServer, :call, [^collaborator, :publish, :infinity]}}}} =
             Fork.publish_deletion(fork, fn ->
               GenServer.call(collaborator, :publish, :infinity)
             end)

    assert Buffer.content_with_version(parent) == {"original", 0}
    assert :ok = Buffer.replace_content(parent, "human", :user)
    assert Buffer.content(parent) == "human"
    assert Fork.status(fork) == :deleted
    assert Fork.version(fork) == 1
    assert :ok = Fork.undo(fork)
    assert {:ok, "original"} = Fork.read_file(fork)
  end

  test "queued conditional mutations wait for completion beyond the default call timeout" do
    parent = start_supervised!({Buffer, content: "original"})
    fork = start_supervised!({Fork, parent: parent, content: "original"})

    contexts = [
      %{server: parent, api: Buffer, identity: {:buffer, "/queued-buffer"}},
      %{server: fork, api: Fork, identity: {:fork, "/queued-fork"}}
    ]

    prepared = Enum.map(contexts, fn ctx -> {ctx, revision(ctx)} end)
    Enum.each(contexts, fn ctx -> :sys.suspend(ctx.server) end)
    test = self()

    pending =
      Enum.map(prepared, fn {ctx, expected} ->
        spawn_monitor(fn ->
          result = mutate(ctx, expected, {:replace, "agent"})
          send(test, {:mutation_completed, self(), result})
        end)
      end)

    try do
      # Exercise the real five-second call deadline while both owners are queued.
      receive do
      after
        5_100 -> :ok
      end

      for {pid, ref} <- pending do
        refute_received {:DOWN, ^ref, :process, ^pid, _reason}
        refute_received {:mutation_completed, ^pid, _result}
      end
    after
      Enum.each(contexts, fn ctx -> :sys.resume(ctx.server) end)
    end

    for {pid, ref} <- pending do
      assert_receive {:mutation_completed, ^pid, :ok}
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end

    for ctx <- contexts, do: assert(Buffer.content_with_version(ctx.server) == {"agent", 1})
  end

  test "parent ownership is held until deletion publication finishes" do
    parent = start_supervised!({Buffer, content: "original"})
    fork = start_supervised!({Fork, parent: parent, content: "original"})
    ctx = %{server: fork, api: Fork, identity: {:fork, "/serialized-delete"}}
    assert :ok = mutate(ctx, revision(ctx), :delete)
    test = self()

    publication =
      Task.async(fn ->
        Fork.publish_deletion(fork, fn ->
          send(test, {:publishing, self()})

          receive do
            :finish_publication -> :ok
          end
        end)
      end)

    assert_receive {:publishing, ^parent}
    human = Task.async(fn -> Buffer.replace_content(parent, "human", :user) end)
    send(parent, :finish_publication)

    assert :ok = Task.await(publication)
    assert :ok = Task.await(human)
    assert Buffer.content(parent) == "human"
    assert Fork.status(fork) == :deleted
  end

  test "publication stages only the raw fork draft, not unsaved parent edits" do
    parent = start_supervised!({Buffer, content: "one\ntwo\nthree"})
    fork = start_supervised!({Fork, parent: parent, content: Buffer.content(parent)})
    Fork.replace_content(fork, "agent\ntwo\nthree")
    Buffer.replace_content(parent, "one\ntwo\nhuman", :user)
    version = Buffer.version(parent)
    test = self()

    assert {:ok, "agent\ntwo\nhuman"} =
             Fork.publish(fork, fn raw ->
               send(test, {:staged_draft, raw, self()})
               :ok
             end)

    assert_receive {:staged_draft, "agent\ntwo\nthree", ^parent}
    assert Buffer.content(parent) == "agent\ntwo\nhuman"
    assert Buffer.version(parent) == version + 1
    Buffer.undo(parent)
    assert Buffer.content(parent) == "one\ntwo\nhuman"
  end

  test "failed staging leaves parent content, version and undo unchanged" do
    parent = start_supervised!({Buffer, content: "one\ntwo\nthree"})
    fork = start_supervised!({Fork, parent: parent, content: Buffer.content(parent)})
    Fork.replace_content(fork, "agent\ntwo\nthree")
    Buffer.replace_content(parent, "one\ntwo\nhuman", :user)
    before = Buffer.content_with_version(parent)

    for failure <- [{:error, :eacces}, {:conflict, :disk_changed}] do
      assert ^failure = Fork.publish(fork, fn _raw -> failure end)
      assert Buffer.content_with_version(parent) == before
      assert Fork.content(fork) == "agent\ntwo\nthree"
      assert Fork.dirty?(fork)
    end

    assert {:error, {:fork_staging_failed, :noproc}} =
             Fork.publish(fork, fn _raw -> exit(:noproc) end)

    assert Buffer.content_with_version(parent) == before
    Buffer.undo(parent)
    assert Buffer.content(parent) == "one\ntwo\nthree"
  end

  test "parent merge conflicts do not stage the fork draft" do
    parent = start_supervised!({Buffer, content: "one\ntwo\nthree"})
    fork = start_supervised!({Fork, parent: parent, content: Buffer.content(parent)})
    Fork.replace_content(fork, "agent\ntwo\nthree")
    Buffer.replace_content(parent, "human\ntwo\nthree", :user)
    before = Buffer.content_with_version(parent)
    test = self()

    assert {:conflict, _hunks} =
             Fork.publish(fork, fn _raw ->
               send(test, :unexpected_staging)
               :ok
             end)

    refute_received :unexpected_staging
    assert Buffer.content_with_version(parent) == before
    assert Fork.dirty?(fork)
  end

  test "successful publication seals queued mutations before returning to its caller" do
    for lifecycle <- [:present, :deleted] do
      parent = start_supervised!({Buffer, content: "original"}, id: make_ref())
      fork = start_supervised!({Fork, parent: parent, content: "original"}, id: make_ref())
      ctx = %{server: fork, api: Fork, identity: {:fork, "/sealed-#{lifecycle}"}}
      operation = if lifecycle == :deleted, do: :delete, else: {:replace, "agent"}
      assert :ok = mutate(ctx, revision(ctx), operation)
      expected = if lifecycle == :deleted, do: :absent, else: revision(ctx)
      queued_operation = if lifecycle == :deleted, do: {:create, "lost"}, else: {:replace, "lost"}
      test = self()

      publication =
        Task.async(fn ->
          barrier = fn ->
            send(test, {:publishing_fork, fork, self()})

            receive do
              :complete_publication -> :ok
            end
          end

          case lifecycle do
            :present -> Fork.publish(fork, fn _raw -> barrier.() end)
            :deleted -> Fork.publish_deletion(fork, barrier)
          end
        end)

      assert_receive {:publishing_fork, ^fork, ^parent}
      mutation_tag = make_ref()

      send(
        fork,
        {:"$gen_call", {self(), mutation_tag},
         {:conditional_mutate, expected, queued_operation, ctx.identity}}
      )

      send(parent, :complete_publication)
      result = Task.await(publication)
      assert result == if(lifecycle == :deleted, do: :ok, else: {:ok, "agent"})
      assert_receive {^mutation_tag, {:error, :published}}
      assert Fork.published?(fork)
      assert Fork.version(fork) == 1
      assert Fork.status(fork) == lifecycle
      assert {:error, :published} = Fork.undo(fork)
      assert {:error, :published} = Fork.replace_content(fork, "lost")
      assert {:error, :published} = Fork.find_and_replace(fork, "agent", "lost")
      assert {:error, :published} = mutate(ctx, expected, queued_operation)
      assert Buffer.content(parent) == if(lifecycle == :deleted, do: "original", else: "agent")
    end
  end

  test "clean fork publication seals without staging or saving unsaved parent bytes" do
    parent = start_supervised!({Buffer, content: "unsaved human"})
    fork = start_supervised!({Fork, parent: parent, content: "unsaved human"})
    test = self()

    assert {:ok, "unsaved human"} =
             Fork.publish(fork, fn _raw ->
               send(test, :unexpected_clean_staging)
               :ok
             end)

    refute_received :unexpected_clean_staging
    assert Fork.published?(fork)
    refute Fork.dirty?(fork)
    assert Buffer.content_with_version(parent) == {"unsaved human", 0}
  end

  test "an edit queued before clean publication is staged rather than discarded" do
    parent = start_supervised!({Buffer, content: "original"})
    fork = start_supervised!({Fork, parent: parent, content: "original"})
    ctx = %{server: fork, api: Fork, identity: {:fork, "/edit-before-publish"}}
    expected = revision(ctx)
    mutation_tag = make_ref()
    test = self()

    send(
      fork,
      {:"$gen_call", {self(), mutation_tag},
       {:conditional_mutate, expected, {:replace, "agent"}, ctx.identity}}
    )

    assert {:ok, "agent"} =
             Fork.publish(fork, fn raw ->
               send(test, {:staged_pending_edit, raw})
               :ok
             end)

    assert_receive {^mutation_tag,
                    {:ok, %FileMutation.Receipt{before: "original", after: "agent"}}}

    assert_receive {:staged_pending_edit, "agent"}
    assert Fork.published?(fork)
    assert Fork.dirty?(fork)
    assert Buffer.content(parent) == "agent"
  end

  defp revision(ctx) do
    {content, generation} = Buffer.content_with_version(ctx.server)
    FileMutation.revision(content, generation, ctx.identity)
  end

  defp mutate(ctx, expected, operation) do
    case ctx.api.conditional_mutate(ctx.server, expected, operation, ctx.identity) do
      {:ok, %FileMutation.Receipt{}} -> :ok
      {:error, _reason} = error -> error
    end
  end
end
