defmodule Shop.Accounts.Member do
  @moduledoc """
  A member of the demo shop, known by email. `:sign_in` finds the member with that email or makes
  one. There are no passwords: it only shows Mishka Pay's access rules
  (`MishkaPay.Ash.subscribed?/3`) and a checkout's owner.
  """

  use Ash.Resource, domain: Shop.Accounts, data_layer: AshPostgres.DataLayer

  postgres do
    table "members"
    repo Shop.Repo
  end

  actions do
    defaults [:read]

    create :sign_in do
      accept [:email]
      upsert? true
      upsert_identity :unique_email
      upsert_fields []
      change {Shop.Accounts.Member.Email, []}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :email, :string, allow_nil?: false, public?: true, constraints: [max_length: 254]
    timestamps()
  end

  identities do
    identity :unique_email, [:email]
  end
end

defmodule Shop.Accounts.Member.Email do
  @moduledoc "Keeps a member's email trimmed and in lower case, and refuses one with no `@`."

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :email) do
      email when is_binary(email) -> put(changeset, email |> String.trim() |> String.downcase())
      _none -> changeset
    end
  end

  defp put(changeset, email) do
    case String.match?(email, ~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/) do
      true ->
        Ash.Changeset.force_change_attribute(changeset, :email, email)

      false ->
        Ash.Changeset.add_error(changeset,
          field: :email,
          message: "Type an email such as ada@example.com."
        )
    end
  end
end
