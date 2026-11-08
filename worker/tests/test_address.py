"""M1-13 address normalisation: mock (CI) and BAN response handling (no network)."""

import httpx

from collectoo_worker.boarding.address import (
    BanNormaliser,
    MockNormaliser,
    messy_variants,
    normalise_cached,
)

BAN_RESPONSE = (
    "adresse,postcode,result_score,result_label,result_city,result_citycode\n"
    "12 rue de la paix,75002,0.9641,12 Rue de la Paix 75002 Paris,Paris,75102\n"
    "nowhere,99999,,,,\n"
)


def test_mock_is_deterministic_and_needs_a_postcode() -> None:
    results = MockNormaliser().normalise([("12  rue de la paix ", "75002"), ("somewhere", None)])
    assert results[0].label == "12 Rue De La Paix 75002" and results[0].normalised
    assert not results[1].normalised
    assert results == MockNormaliser().normalise(
        [("12  rue de la paix ", "75002"), ("somewhere", None)]
    )


def test_ban_csv_response_is_parsed() -> None:
    seen: list[bytes] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request.read())
        return httpx.Response(200, text=BAN_RESPONSE)

    ban = BanNormaliser(httpx.Client(transport=httpx.MockTransport(handler)))
    out = ban.normalise([("12 rue de la paix", "75002"), ("nowhere", "99999")])
    assert out[0].label == "12 Rue de la Paix 75002 Paris" and out[0].citycode == "75102"
    assert out[0].normalised and not out[1].normalised and out[1].score == 0.0
    assert b"12 rue de la paix,75002" in seen[0]


def test_ban_retries_transient_failures() -> None:
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        if calls["n"] == 1:
            raise httpx.ConnectError("reset")
        return httpx.Response(200, text=BAN_RESPONSE)

    ban = BanNormaliser(httpx.Client(transport=httpx.MockTransport(handler)))
    assert ban.normalise([("12 rue de la paix", "75002"), ("nowhere", "99999")])[0].normalised
    assert calls["n"] == 2


def test_cache_is_skipped_without_a_connection_and_order_is_kept() -> None:
    queries = [("b street", "75001"), ("a street", "75002"), ("b street", "75001")]
    out = normalise_cached(MockNormaliser(), queries, None)
    assert [r.line for r in out] == ["b street", "a street", "b street"]


def test_messy_variants_keep_the_address_recognisable() -> None:
    variants = messy_variants("20 avenue de Ségur")
    assert "20 AVENUE DE SEGUR" in variants and "20 av. de Ségur" in variants
