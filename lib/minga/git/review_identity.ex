defmodule Minga.Git.ReviewIdentity do
  @moduledoc "Immutable file and ref observations used to bound commit evidence."

  @type cursor :: {non_neg_integer(), <<_::256>>}
  @type ref :: {String.t(), String.t() | :unborn, cursor()}
  @type t :: {worktree :: String.t(), relative_path :: String.t(), ref()}
end
