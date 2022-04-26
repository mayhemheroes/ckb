# Build Stage
FROM ubuntu:20.04 as builder

## Install build dependencies.
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y cmake clang curl
RUN curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
RUN ${HOME}/.cargo/bin/rustup default nightly
RUN ${HOME}/.cargo/bin/cargo install -f cargo-fuzz

## Add source code to the build stage.
ADD . /ckb
WORKDIR /ckb

RUN cd script/fuzz && ${HOME}/.cargo/bin/cargo +nightly fuzz build

# Package Stage
FROM ubuntu:20.04

COPY --from=builder ckb/script/fuzz/target/x86_64-unknown-linux-gnu/release/syscall_exec /
COPY --from=builder ckb/script/fuzz/target/x86_64-unknown-linux-gnu/release/transaction_scripts_verifier_data0 /
COPY --from=builder ckb/script/fuzz/target/x86_64-unknown-linux-gnu/release/transaction_scripts_verifier_data1 /


