# External interoperability smoke test

`run.sh` builds the minimal hello servers and drives them with external
clients. It complements the in-process package tests, which use netz's own
client and synthetic QUIC handshake.

## What it checks

- HTTP/1.1 with `curl`.
- h2c prior knowledge with `curl --http2-prior-knowledge`.
- h2c with `nghttp` when installed.
- h2c conformance with `h2spec` when installed.
- HTTP/3 is reported as `SKIP` until an HTTP/3 hello server and client are
  available on the host.

Missing optional clients are reported as `SKIP`; the script fails only when an
installed client receives an unexpected response or an error.

## Run locally

```sh
./test/interop/run.sh
```

Override the default ports with `WEFT_HTTP1_PORT` and `WEFT_H2C_PORT`.
