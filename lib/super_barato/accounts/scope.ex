defmodule SuperBarato.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `SuperBarato.Accounts.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use as authorization, or to
  ensure specific code paths can only be access for a given scope.

  It is useful for logging as well as for scoping pubsub subscriptions and
  broadcasts when a caller subscribes to an interface or performs a particular
  action.

  Feel free to extend the fields on this struct to fit the needs of
  growing application requirements.
  """

  alias SuperBarato.Accounts.User

  defstruct user: nil

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  def for_user(%User{} = user) do
    %__MODULE__{user: user}
  end

  def for_user(nil), do: nil

  @doc """
  True when the scope's user role is at least `required`.

  Hierarchy: visitor < moderator < curator < superadmin.
  A nil scope or nil user is never authorized.
  """
  def role_at_least?(%__MODULE__{user: %User{} = user}, required),
    do: User.role_at_least?(user, required)

  def role_at_least?(_, _), do: false

  @doc "Convenience role checks."
  def superadmin?(scope), do: role_at_least?(scope, :superadmin)
  def curator?(scope), do: role_at_least?(scope, :curator)
  def moderator?(scope), do: role_at_least?(scope, :moderator)
end
