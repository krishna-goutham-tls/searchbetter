# Test 3: how long the model takes to turn one typed search into a vector.
import sys, time, statistics
from sentence_transformers import SentenceTransformer

MODEL = sys.argv[1] if len(sys.argv) > 1 else "mlx-community/embeddinggemma-300m-bf16"
QUERIES = [
    "invoice from last march", "the function that retries the whatsapp send", "whiteboard photo with pricing table",
    "screenshot of the error in the build", "notes about the sat program launch", "budget 2026", "lidawake launch video",
    "python script that scrapes reddit", "photo of a dog near water", "contract with the design agency",
    "readme for the cricket app", "slides about agent teams", "receipt for the macbook", "meeting notes from the kickoff",
    "how we count installs", "where the cron job runs", "the logo in dark mode", "tax documents", "resume pdf",
    "chart of signups by week",
]

def bench(device):
    t = time.perf_counter()
    m = SentenceTransformer(MODEL, device=device)
    load = time.perf_counter() - t
    for q in QUERIES[:3]:
        m.encode_query(q) if hasattr(m, "encode_query") else m.encode(q)
    ms = []
    for _ in range(3):
        for q in QUERIES:
            t = time.perf_counter()
            v = m.encode_query(q) if hasattr(m, "encode_query") else m.encode(q)
            ms.append((time.perf_counter() - t) * 1000)
    ms.sort()
    print(f"[embed] {device}: load {load:.1f} s, dim {len(v)}, median {statistics.median(ms):.1f} ms, "
          f"p95 {ms[int(len(ms)*0.95)]:.1f} ms, max {ms[-1]:.1f} ms ({len(ms)} queries)")

if __name__ == "__main__":
  for d in sys.argv[2:] or ["mps", "cpu"]:
    bench(d)
