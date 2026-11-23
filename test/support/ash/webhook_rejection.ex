# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.WebhookRejection do
  @moduledoc "A host's count of refused webhook messages, as `MishkaPay.Ash.Resource` shows its `:webhook_rejection` kind."

  use Ash.Resource,
    domain: MishkaPay.Support.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [MishkaPay.Ash.Resource]

  postgres do
    table "pay_webhook_rejections"
    repo MishkaPay.Support.Repo
  end

  mishka_pay do
    kind :webhook_rejection
  end
end
