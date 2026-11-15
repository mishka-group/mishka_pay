# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

import Config

# Only the test run of this library is configured here. A project that uses Mishka Pay configures
# mishka_installer itself.
if config_env() == :test, do: import_config("test.exs")
