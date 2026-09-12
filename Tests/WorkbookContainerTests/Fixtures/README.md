# Fixtures

All three are synthetic. The workbooks that prompted this feature are real files belonging to
the project's author and carry nearly a hundred people's names; a fixture is published,
diffed and copied around, and none of that is appropriate for them. A fixture should prove
the algorithm, which a three-cell workbook does exactly as well.

| File | What it is |
|---|---|
| `plain.xlsx` | A three-cell workbook. The expected result of decrypting either of the others. |
| `agile-encrypted.xlsx` | That file under agile encryption, **SHA-512 with AES-256**. Password `swordfish`. |
| `agile-sha1-aes128.xlsx` | The same, **SHA-1 with AES-128**. Password `swordfish`. |

Decrypting either encrypted file must reproduce `plain.xlsx` byte for byte.

## Why the SHA-1 fixture exists

Because its absence already caused a bug. SHA-1 was dropped from the decryptor on the
reasoning that agile encryption implies Excel 2010 or later, which writes SHA-512 — and that
reasoning was checked against `agile-encrypted.xlsx`, which this project had generated
itself, and which naturally used SHA-512. The two real 2012 workbooks the whole feature was
written for both declare **SHA-1 with 128-bit AES**, so the change broke precisely the case it
was meant to serve, and every test still passed.

A fixture set that only contains what the code already handles cannot fail. This one was
produced by an independent agile encryptor and verified against a third implementation
before being trusted.
