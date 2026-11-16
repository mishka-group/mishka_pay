defmodule ShopWeb.MemberController do
  @moduledoc """
  The demo's sign-in, by email only: `Shop.Accounts.Member` `:sign_in` finds or makes the member
  and keeps its id in the session, so the shop page (and the trip to Stripe and back) knows who
  buys. Sign out forgets it. A demo of `belongs_to_user`, not a real login: no passwords.
  """

  use ShopWeb, :controller

  def sign_in(conn, %{"email" => email}) do
    case Ash.create(Shop.Accounts.Member, %{email: email}, action: :sign_in, authorize?: false) do
      {:ok, member} ->
        conn
        |> configure_session(renew: true)
        |> put_session(:member_id, member.id)
        |> put_flash(:info, "Signed in as #{member.email}.")
        |> redirect(to: ~p"/#members")

      {:error, error} ->
        conn
        |> put_flash(:error, MishkaPay.Ash.message(error))
        |> redirect(to: ~p"/#members")
    end
  end

  def sign_out(conn, _params) do
    conn
    |> delete_session(:member_id)
    |> put_flash(:info, "Signed out.")
    |> redirect(to: ~p"/#members")
  end
end
