System Overview
===============

EIP1154_ oracles report results to event managers, which are OracleConsumers. Event managers operate for a single collateral token.

Every set of (oracle, questionID, numOutcomes, outcome) tuples corresponds to an OutcomeToken. The empty set maps to the collateral token.

Quantities of tokens which match in every way other than a set of (oracle, questionID, numOutcomes, *) can be turned in for the same quantity of token corresponding to the matching set.

Results reported by an oracle are abi.encodePacked arrays of uints which correspond to how much each OutcomeToken for a particular question is worth in terms of.

.. _EIP1154: https://eips.ethereum.org/EIPS/eip-1154