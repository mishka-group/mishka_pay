# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.Options do
  @moduledoc """
  Resources that set each option of `MishkaPay.Ash.Resource` away from its default, in ETS, so
  the extension's tests see what each option adds and what it leaves out.
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource MishkaPay.Support.Options.User
    resource MishkaPay.Support.Options.Quiet
    resource MishkaPay.Support.Options.Owned
    resource MishkaPay.Support.Options.Kept
  end
end

defmodule MishkaPay.Support.Options.User do
  @moduledoc "A host's user, for `belongs_to_user`."

  use Ash.Resource, domain: MishkaPay.Support.Options, data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read]
  end

  attributes do
    uuid_primary_key :id
  end
end

defmodule MishkaPay.Support.Options.Quiet do
  @moduledoc "Payments with only `:sync`, no listener, no announcement and no code interface."

  use Ash.Resource,
    domain: MishkaPay.Support.Options,
    data_layer: Ash.DataLayer.Ets,
    extensions: [MishkaPay.Ash.Resource]

  ets do
    private? true
  end

  mishka_pay do
    kind :payment
    actions [:sync]
    listen? false
    announce? false
    code_interface? false
  end

  # ETS checks no identity itself: the host's own identity, which the kind keeps, says how.
  identities do
    identity :provider_payment, [:provider, :provider_id],
      pre_check_with: MishkaPay.Support.Options
  end
end

defmodule MishkaPay.Support.Options.Owned do
  @moduledoc """
  Subscriptions that belong to a user, with the host's own `:plan` attribute and its own action
  written with `accept` and `change`, beside the kind's `:change` code interface.
  """

  use Ash.Resource,
    domain: MishkaPay.Support.Options,
    data_layer: Ash.DataLayer.Ets,
    extensions: [MishkaPay.Ash.Resource]

  mishka_pay do
    kind :subscription
    belongs_to_user MishkaPay.Support.Options.User
  end

  actions do
    update :rename do
      accept [:plan]
      change set_attribute(:reference, "renamed")
    end
  end

  attributes do
    attribute :plan, :string, allow_nil?: false, default: "basic", public?: true
  end

  # ETS checks no identity itself: the host's own identity, which the kind keeps, says how.
  identities do
    identity :provider_subscription, [:provider, :provider_id],
      pre_check_with: MishkaPay.Support.Options
  end
end

defmodule MishkaPay.Support.Options.Kept do
  @moduledoc "Disputes that belong to a user through the host's own `:owner_id`."

  use Ash.Resource,
    domain: MishkaPay.Support.Options,
    data_layer: Ash.DataLayer.Ets,
    extensions: [MishkaPay.Ash.Resource]

  mishka_pay do
    kind :dispute
    belongs_to_user {MishkaPay.Support.Options.User, attribute: :owner_id}
  end

  # ETS checks no identity itself: the host's own identity, which the kind keeps, says how.
  identities do
    identity :provider_dispute, [:provider, :provider_id],
      pre_check_with: MishkaPay.Support.Options
  end
end
