defmodule MingaEditor.UI.Picker.FilesystemQueryTest do
  use ExUnit.Case, async: true

  alias MingaEditor.UI.Picker.FilesystemQuery
  alias MingaEditor.UI.Picker.FindFileSession

  test "parses root, captured Home, relative navigation, and leaf filters from full text" do
    session = FindFileSession.new("/launch/work", "/people/user", nil)

    assert %FilesystemQuery{resolution: {:browse, "/", ""}} =
             FilesystemQuery.parse(session, "/")

    assert %FilesystemQuery{resolution: {:browse, "/people/user", ""}} =
             FilesystemQuery.parse(session, "~")

    assert %FilesystemQuery{resolution: {:browse, "/people/user/docs", "rés"}} =
             FilesystemQuery.parse(session, "~/docs/rés")

    assert %FilesystemQuery{resolution: {:browse, "/launch", ""}} =
             FilesystemQuery.parse(session, "..")

    assert %FilesystemQuery{resolution: {:browse, "/launch/shared", "file name.txt"}} =
             FilesystemQuery.parse(session, "../shared/file name.txt")
  end

  test "rejects named-user expansion and recognizes only explicit path forms" do
    session = FindFileSession.new("/launch", "/people/user", nil)

    assert %FilesystemQuery{resolution: {:error, message}} =
             FilesystemQuery.parse(session, "~someone/file")

    assert message =~ "not supported"

    for query <- ["/", "/tmp", "~", "~/src", ".", "./src", "..", "../src"] do
      assert FilesystemQuery.explicit_path_intent?(query)
    end

    for query <- ["", "README", ".env", "src/file"] do
      refute FilesystemQuery.explicit_path_intent?(query)
    end
  end

  test "directory navigation keeps visible text and resolved directory aligned" do
    session = FindFileSession.new("/launch", "/people/user", nil)

    assert %FilesystemQuery{text: "~/notes/", resolution: {:browse, "/people/user/notes", ""}} =
             FilesystemQuery.for_directory(session, "/people/user/notes")

    assert %FilesystemQuery{text: "/", resolution: {:browse, "/", ""}} =
             FilesystemQuery.for_directory(session, "/")
  end
end
