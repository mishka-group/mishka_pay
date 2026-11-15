# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

import Config

# `mix format` writes Spark DSLs (guarded_struct's `guardedstruct`, and Ash's in the Ash layer)
# without parentheses, as in Ash and the other Mishka libraries.
config :spark,
  formatter: [
    remove_parens?: true,
    GuardedStruct: [],
    "Ash.Resource": [
      section_order: [
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ]
  ]

# This library converts no currencies, so ex_money's exchange rate service stays off in its own
# runs. A project that wants rates starts `Money.ExchangeRates.Retriever` itself.
config :ex_money, auto_start_exchange_rate_service: false

# Ash as mishka_cms_core configures it, for the Ash layer's own tests and compile.
config :ash,
  default_string_length_count: :codepoints,
  allow_forbidden_field_for_relationships_by_default?: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true

# Only the test run of this library is configured here. A project that uses Mishka Pay configures
# mishka_installer itself.
if config_env() == :test, do: import_config("test.exs")
