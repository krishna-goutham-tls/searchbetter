# Test 3 on MLX, the Apple framework the app would use.
import sys, time, statistics
import mlx.core as mx
from mlx_embeddings.utils import load
sys.path.insert(0, "py")
from embed_bench import QUERIES  # noqa

name = sys.argv[1]
t = time.perf_counter(); model, tok = load(name); load_s = time.perf_counter() - t
def enc(q):
    ids = tok.encode("task: search result | query: " + q, return_tensors="mlx") if hasattr(tok, "encode") else None
    out = model(ids)
    v = out.text_embeds if hasattr(out, "text_embeds") else out
    mx.eval(v); return v
for q in QUERIES[:3]: enc(q)
ms = []
for _ in range(3):
    for q in QUERIES:
        t = time.perf_counter(); v = enc(q); ms.append((time.perf_counter() - t) * 1000)
ms.sort()
print(f"[embed] mlx {name}: load {load_s:.1f} s, shape {v.shape}, median {statistics.median(ms):.1f} ms, p95 {ms[int(len(ms)*0.95)]:.1f} ms, max {ms[-1]:.1f} ms")
