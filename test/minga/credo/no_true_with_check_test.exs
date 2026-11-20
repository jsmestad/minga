Code.require_file("credo/checks/no_true_with_check.exs")

defmodule Minga.Credo.NoTrueWithCheckTest do
  use Credo.Test.Case, async: true

  alias Minga.Credo.NoTrueWithCheck

  @moduletag :credo
  @file_path "test/example_test.exs"
  @legacy %{
    @file_path => %{
      # `allowed?(value)` in the baseline's normalized AST format.
      "1d07cb307981aae6773dfaa0a88fdd3cd7e7dac94b932c7f05f1fa9b09b55dd7" =>
        {~s|"allowed?(value)"|, 1}
    }
  }

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  test "reports the generator operator in nested and multiline with expressions" do
    """
    with {:ok, value} <- load() do
      with(
        (true) <-
          allowed?(value),
        do: :ok
      )
    end
    """
    |> check()
    |> assert_issue(fn issue ->
      assert issue.line_no == 3
      assert issue.column == 12
      assert issue.trigger == "<-"
      assert issue.message =~ "Avoid `true <-` in `with`"
    end)
  end

  test "ignores comprehensions, ordinary matches, other patterns and remote macros" do
    """
    true = allowed?(value)
    for true <- flags, do: :ok
    with true = allowed?(value), do: :ok
    with false <- allowed?(value), do: :ok
    with {:ok, true} <- load(), do: :ok
    with flag <- load(), do: flag
    Rules.with true <- allowed?(value), do: :ok
    "with true <- allowed?(value), do: :ok"
    # with true <- allowed?(value), do: :ok
    """
    |> check()
    |> refute_issues()
  end

  test "preserves an unchanged legacy clause after line and whitespace changes" do
    """
    # A new comment above the clause.

    with (true) <- allowed?(
      value
    ), do: :ok
    """
    |> check(legacy: @legacy)
    |> refute_issues()
  end

  test "reports only the excess identical occurrence within the same file" do
    """
    with true <- allowed?(value), do: :first
    with true <- allowed?(value), do: :second
    """
    |> check(legacy: @legacy)
    |> assert_issue(fn issue -> assert issue.line_no == 2 end)
  end

  test "does not grandfather a different RHS in a file that has a legacy clause" do
    """
    with true <- allowed?(value), do: :ok
    with true <- ready?(value), do: :ok
    """
    |> check(legacy: @legacy)
    |> assert_issue(fn issue -> assert issue.line_no == 2 end)
  end

  test "does not carry an allowance to other files" do
    "with true <- allowed?(value), do: :ok"
    |> check([legacy: @legacy], "mix/example.exs")
    |> assert_issue()
  end

  test "requires removing a row when its clause is removed" do
    "with :ok <- validate(value), do: :ok"
    |> check(legacy: @legacy)
    |> assert_issue(fn issue ->
      assert issue.message =~ "Remove 1 stale baseline row"
      assert issue.message =~ "allowed?(value)"
    end)
  end

  test "does not retain allowances for deleted files" do
    missing_files =
      NoTrueWithCheck.param_defaults()[:legacy]
      |> Map.keys()
      |> Enum.reject(&File.regular?/1)

    assert missing_files == []
  end

  defp check(source, params \\ [], filename \\ @file_path) do
    source
    |> to_source_file(filename)
    |> run_check(NoTrueWithCheck, params)
  end
end
