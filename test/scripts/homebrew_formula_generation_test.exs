defmodule Minga.Scripts.HomebrewFormulaGenerationTest do
  use ExUnit.Case, async: true

  @workflow Path.expand("../../.github/workflows/release.yml", __DIR__)

  test "formula keeps Burrito private and installs platform public wrappers" do
    workflow = File.read!(@workflow)

    assert workflow =~ ~S(libexec.install binary => "minga-burrito")
    assert workflow =~ ~S(executable_name = OS.mac? ? "minga-tui" : "minga")
    assert workflow =~ ~S(wrapper = bin/executable_name)
    assert workflow =~ ~S(exec "#{{libexec}}/minga-burrito" "$@")
    refute workflow =~ ~S(bin.install binary =>)
  end

  test "formula wrapper establishes the pre-VM cookie and distribution boundary" do
    workflow = File.read!(@workflow)

    cookie_file = position!(workflow, ~S(if [ -n "$cookie_file" ]))

    minga_cookie =
      position!(workflow, ~S|elif MINGA_COOKIE_VALUE=$(printenv MINGA_COOKIE 2>/dev/null)|)

    release_cookie =
      position!(workflow, ~S|elif RELEASE_COOKIE_VALUE=$(printenv RELEASE_COOKIE 2>/dev/null)|)

    random_cookie =
      position!(workflow, ~S(RELEASE_COOKIE=$(LC_ALL=C od -An -N32 -tx1 /dev/urandom))

    export_cookie = position!(workflow, ~S(export RELEASE_COOKIE))
    exec_payload = position!(workflow, ~S(exec "#{{libexec}}/minga-burrito" "$@"))

    assert cookie_file < minga_cookie
    assert minga_cookie < release_cookie
    assert release_cookie < random_cookie
    assert random_cookie < export_cookie
    assert export_cookie < exec_payload

    assert workflow =~
             "unset ERL_AFLAGS ERL_FLAGS ERL_ZFLAGS ELIXIR_ERL_OPTIONS RELEASE_VM_ARGS"

    assert workflow =~ "export RELEASE_DISTRIBUTION=none"
    assert workflow =~ "export MINGA_EXPECT_DISTRIBUTION=0"
    assert workflow =~ "export MINGA_RANDOM_RELEASE_COOKIE=1"
    refute workflow =~ ~S(${{MINGA_COOKIE:-}})
    refute workflow =~ ~S(${{RELEASE_COOKIE:-}})
  end

  defp position!(text, needle) do
    case :binary.match(text, needle) do
      {position, _length} -> position
      :nomatch -> flunk("missing generated formula text: #{needle}")
    end
  end
end
