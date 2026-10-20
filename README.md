# QUORUM (QRM)

Production issuance source for Ethereum mainnet, paired with IMD. One billion tokens; fixed membership stake 62,500 QRM.

The English constitution is the authoritative immutable text; Chinese is a review translation. PREREQUISITES.json records the deployed and verified constitution and fixed core creation code package. Those addresses are not the project token. QuorumToken has a zero-argument constructor bound to these dependencies.

Reproduce with Python 3, requirements-local.txt and Foundry: `python tools/build_external_fixtures.py` then `python tools/run_acceptance.py`. Run every default-root test and every mandatory case in ACCEPTANCE.json without weakening or skipping assertions.

IMD must verify issuance compatibility and final composition. Governance semantics are fixed product requirements. Any change to immutable core creation bytes requires a new separately approved dependency deployment. Local positive tests and the limited independent static review are not comprehensive security certification. No frontend, bot, ENS purchase or additional paid order is requested.

Final token, Hook, core and registry identities remain unissued until the official platform deploys them.
