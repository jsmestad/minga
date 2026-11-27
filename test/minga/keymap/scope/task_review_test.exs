defmodule Minga.Keymap.Scope.TaskReviewTest do
  use ExUnit.Case, async: true

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.Scope.TaskReview

  import Minga.Keymap.Sigil

  test "review decisions and navigation are available in Normal and CUA, not text modes" do
    bindings = [
      {~k(y), :task_review_keep},
      {~k(n), :task_review_reject},
      {~k(=), :task_review_diff},
      {~k(] h), :task_review_next},
      {~k([ h), :task_review_previous},
      {~k(] q), :quickfix_next},
      {~k([ q), :quickfix_previous},
      {~k(RET), :task_review_jump},
      {~k(Y), :task_review_keep_all},
      {~k(q), :task_review_close},
      {~k(ESC), :task_review_escape}
    ]

    for mode <- [:normal, :cua] do
      trie = TaskReview.keymap(mode, [])

      for {keys, command} <- bindings do
        assert lookup(trie, keys) == {:command, command}, inspect({mode, keys})
      end
    end

    for mode <- [:insert, :visual, :replace, :operator_pending] do
      trie = TaskReview.keymap(mode, [])

      for {keys, _command} <- bindings do
        assert lookup(trie, keys) == :not_found, inspect({mode, keys})
      end
    end
  end

  defp lookup(trie, [key]), do: Bindings.lookup(trie, key)

  defp lookup(trie, [key | rest]) do
    case Bindings.lookup(trie, key) do
      {:prefix, next} -> lookup(next, rest)
      other -> other
    end
  end
end
