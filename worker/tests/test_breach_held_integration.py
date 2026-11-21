"""M2c-6b-3b part 3 (needs `make up`; ADR-0014 « M2c-6b-3b part 3 »): the held rows' alert's
scenario of test_breach_held_scale_integration.py at a few runs, in the db job's integration tests
(CI's scale-payouts job runs it at 2,000): six payouts cancelled out of a downloaded file and
re-issued, their runs booked by the re-issues' debits and held by missing statement days, two
windows on one account — every run alerted with its days, the alert as the standalone reading
(private.remittance_breach_held) says it, the rows written once the days are covered, and the
nightly checks' work counted (the booked runs read once, the holds' facts once per run and date
held to, the uncovered days once per account and window). The switch is on only inside the
scenario's rolled-back transaction."""

from typing import Any

import pytest
from test_breach_held_scale_integration import assert_held, filed_payouts, held_runs

pytestmark = pytest.mark.integration
SIZE = 6


@pytest.fixture(scope="module")
def filed(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
    return filed_payouts(tmp_path_factory, SIZE, "held-few")


def test_re_issued_payouts_held_by_missing_statement_days_alerted_as_the_standalone_reading(
    filed: dict[str, Any],
) -> None:
    out = held_runs(filed)
    assert_held(out, SIZE)
