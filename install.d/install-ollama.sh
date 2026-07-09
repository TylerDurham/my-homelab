#!/usr/bin/env bash

if ! . "$MY_LIB_DIR/bash/require.sh" logger; then
  echo "Could not load libraries from '$MY_LIB_DIR'!" >&2
  exit 1
fi

os=$(sys-get-os)

if [[ "$os" == "macos" ]]; then
  info "Installing Ollama.."
  brew install ollama
  info "Starting Ollama as a service"
  brew services start ollama
fi
