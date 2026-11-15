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

# Only the test run of this library is configured here. A project that uses Mishka Pay configures
# mishka_installer itself.
if config_env() == :test, do: import_config("test.exs")
