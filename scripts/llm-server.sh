#!/bin/sh
# Formatteur local : Qwen3.5-4B Q5, thinking off, speculative decoding n-gram (le texte ASR sert de brouillon).
# Mesuré M5 Pro : ~460 ms pour 13 s de dictée (600 ms sans spéculatif).
exec llama-server -m "${MODEL:-$HOME/models/llm/Qwen3.5-4B-Q5_K_M.gguf}" --port "${PORT:-8081}" \
  -ngl 99 -c 16384 --jinja --chat-template-kwargs '{"enable_thinking":false}' \
  --spec-type ngram-simple --spec-ngram-simple-size-n 3 --spec-ngram-simple-size-m 16
