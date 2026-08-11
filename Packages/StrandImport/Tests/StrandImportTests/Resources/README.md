# Synthetic import fixtures

Every row in this directory is generated test data. No file was copied from a
person's WHOOP or Apple Health account.

When a real export reveals a parser bug:

1. reproduce the schema shape locally;
2. minimize it to invented dates and values;
3. remove names, account/device IDs, routes, notes, and other identifiers;
4. commit only that synthetic recreation.

Real archives and loose account CSVs belong in the private study vault outside
the repository.
