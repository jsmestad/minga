defmodule Minga.EventRecorder.EventRecordTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.EventRecorder.EventRecord

  describe "scope encoding round-trip" do
    property "encode_scope/decode_scope is symmetric" do
      check all(scope <- scope_generator()) do
        assert scope == EventRecord.decode_scope(EventRecord.encode_scope(scope))
      end
    end

    test "encodes :global" do
      assert "global" == EventRecord.encode_scope(:global)
    end

    test "encodes buffer scope with path" do
      assert "buffer:/tmp/a.ex" == EventRecord.encode_scope({:buffer, "/tmp/a.ex"})
    end

    test "encodes session scope with id" do
      assert "session:abc-123" == EventRecord.encode_scope({:session, "abc-123"})
    end
  end

  describe "source encoding" do
    property "encode_source always returns a non-empty string" do
      check all(source <- source_generator()) do
        encoded = EventRecord.encode_source(source)
        assert is_binary(encoded) and byte_size(encoded) > 0
      end
    end

    test "encodes :user" do
      assert "user" == EventRecord.encode_source(:user)
    end

    test "encodes :formatter" do
      assert "formatter" == EventRecord.encode_source(:formatter)
    end

    test "encodes :unknown" do
      assert "unknown" == EventRecord.encode_source(:unknown)
    end

    test "encodes agent source with pid and tool call id" do
      pid = self()
      encoded = EventRecord.encode_source({:agent, pid, "call_abc"})
      assert String.starts_with?(encoded, "agent:")
      assert String.contains?(encoded, "call_abc")
    end

    test "encodes lsp source with server name" do
      assert "lsp:elixir_ls" == EventRecord.encode_source({:lsp, :elixir_ls})
    end
  end

  # ── Generators ──────────────────────────────────────────────────────

  defp scope_generator do
    gen all(
          kind <- StreamData.member_of([:global, :buffer, :session]),
          path <- StreamData.string(:alphanumeric, min_length: 1)
        ) do
      case kind do
        :global -> :global
        :buffer -> {:buffer, "/tmp/" <> path}
        :session -> {:session, path}
      end
    end
  end

  defp source_generator do
    gen all(kind <- StreamData.member_of([:user, :formatter, :unknown, :agent, :lsp])) do
      case kind do
        :user -> :user
        :formatter -> :formatter
        :unknown -> :unknown
        :agent -> {:agent, self(), "tool_call_#{:erlang.unique_integer([:positive])}"}
        :lsp -> {:lsp, :test_server}
      end
    end
  end
end
