# ISO 20022 schemas (pain.001) — to vendor

The pain.001 files Collectoo writes (M2c-6a, `worker/src/collectoo_worker/remittance/pain001.py`,
design `docs/design/m2c-remittances.md` §11) are validated against the official ISO 20022 XSD of
their version, in the transfer-file job and in CI. **The two schemas are not in the repository yet:**
the session that built M2c-6a could not download them (the request to `www.iso20022.org` was
refused by the network allowlist; `docs/CLOUD_ENV.md`). Until they are added:

- every file still passes the structural check (`pain001.check`: element order, the fields design
  §11 lists, lengths, the EPC character set, NbOfTxs / CtrlSum from integer minor units, unique
  ids, IBANs), and the goldens are compared byte for byte;
- the job records `transfer_file.xsd_validated = false`, and the « Virements » page says
  « Schéma XSD non vérifié » on each file;
- `worker/tests/test_pain001.py::test_the_goldens_validate_against_the_iso20022_xsd` is a strict
  xfail (`raises=XsdUnavailableError`): it fails loudly — XPASS — as soon as the files below are
  added, and must then simply lose its `xfail` marker.

## Files to add (exactly these names, in this directory)

| File | Message | Where |
|---|---|---|
| `pain.001.001.09.xsd` | CustomerCreditTransferInitiationV09 (default, `bank_account.pain_version`) | ISO 20022 message archive, Payments Initiation, `pain.001.001.09` |
| `pain.001.001.03.xsd` | CustomerCreditTransferInitiationV03 (banks whose guide asks for it) | ISO 20022 message archive (older versions), `pain.001.001.03` |

Source: <https://www.iso20022.org/iso-20022-message-definitions> → « Payments Initiation » (the
`.09` XSD), and <https://www.iso20022.org/catalogue-messages/iso-20022-messages-archive> for the
`.03` XSD. Download the `.xsd` of each message definition (the archive's zip holds one `.xsd` per
version), rename it to the file name above if needed, and commit it unchanged. Take them from
`www.iso20022.org` only (not a bank's or a third party's copy, which may be altered or restricted
to a usage guideline); record the download date and the SHA-256 of each file in the table below.

| File | Downloaded on | SHA-256 |
|---|---|---|
| `pain.001.001.09.xsd` | — | — |
| `pain.001.001.03.xsd` | — | — |

Then (M2c-6a review tests-ui#6: three tests read whether the schemas are here, not one):

1. `worker/tests/test_pain001.py::test_the_goldens_validate_against_the_iso20022_xsd` (one case per
   version and golden, strict xfail): remove its `xfail` marker; run
   `cd worker && uv run pytest tests/test_pain001.py`.
2. `worker/tests/test_transfer_files_integration.py::test_a_file_of_two_payouts_written_by_the_job`
   (the job's file): it asserts `f["xsd_validated"] is pain001.xsd_available("pain.001.001.09")`, so
   it follows the schemas; nothing to change. The job and CI find this directory from the source
   tree, so the file is validated as soon as the schemas are committed (`make test-integration`).
3. `apps/web/e2e/remittances.spec.ts` (the file's page): it accepts « schéma XSD ISO 20022 vérifié »
   and « … non vérifié » alike; nothing to change. Check a generated file's page now shows
   « schéma XSD ISO 20022 vérifié » (`make e2e`).

The worker finds this directory from its source tree, or from `PAIN001_XSD_DIR` when it is
deployed without the repository.

The bank's own implementation guide (founder #15: « please send your bank's file specifications »)
may restrict the schema further (character set, lengths, the BIC); it is read against these files
when it arrives (design §20 R5).
