defmodule Minga.Buffer.AuthorTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Author

  require Author

  test "an author is {kind, id} and its edit key adds the step" do
    author = Author.minga("task-7")
    key = Author.key(author, "call-3")

    assert author == {:minga, "task-7"}
    assert key == {:minga, "task-7", "call-3"}
    assert Author.author(key) == author
    assert Author.step(key) == "call-3"
  end

  test "the key guard accepts only author keys of a known kind" do
    accepted? = fn value -> Author.is_key(value) end

    assert accepted?.({:minga, "task", "step"})

    for value <- [
          {:agent, self(), "call"},
          {:collaborator, "peer", "step"},
          {:minga, "task"},
          {:minga, :task, "step"},
          {:minga, "task", 1},
          :agent
        ] do
      refute accepted?.(value), inspect(value)
    end
  end
end
