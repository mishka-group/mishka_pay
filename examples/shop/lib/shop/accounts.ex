defmodule Shop.Accounts do
  @moduledoc """
  The demo shop's members: who signs in (by email only, a demo) to buy a plan as themselves and
  read the members-only post. Payments and subscriptions belong to a member through
  `belongs_to_user` in their `mishka_pay` block.
  """

  use Ash.Domain, otp_app: :shop

  resources do
    resource Shop.Accounts.Member
  end
end
