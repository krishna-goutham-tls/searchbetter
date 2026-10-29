# Speed test

Measures whether search can answer in under 100 ms on this Mac. Results go in
`brainstorming/speed-design.md` (outside this repo).

    swiftc -O Sources/walk/main.swift -o bin/walk && ./bin/walk ~ out           # test 1: walk the home folder
    swiftc -O Sources/scan/main.swift -o bin/scan && ./bin/scan out/paths.txt   # tests 2 and 4
    uv venv .venv -p 3.12 && uv pip install -p .venv sentence-transformers torch torchvision mlx mlx-lm "git+https://github.com/Blaizzy/mlx-embeddings"
    .venv/bin/python py/embed_mlx.py mlx-community/embeddinggemma-300m-bf16    # test 3, MLX
    llama-server -hf ggml-org/embeddinggemma-2-GGUF:Q8_0 --embeddings --pooling mean -ngl 99 --port 8099 &
    .venv/bin/python py/embed_llama.py                                          # test 3, EmbeddingGemma 2
    .venv/bin/python py/sanity.py                                               # MLX copy matches the reference

`out/` holds the list of paths on this Mac. It is git-ignored and never leaves the Mac.
