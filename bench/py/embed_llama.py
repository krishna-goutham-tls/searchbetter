# Test 3 for EmbeddingGemma 2 (text + images) through a local llama.cpp server.
import sys, time, json, base64, statistics, glob, os, urllib.request
sys.path.insert(0, "py")
from embed_bench import QUERIES  # noqa
URL = "http://localhost:8099/embedding"
MARKER = json.loads(urllib.request.urlopen("http://localhost:8099/props").read())["media_marker"]

def post(payload):
    req = urllib.request.Request(URL, data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req).read())

def stats(label, ms):
    ms = sorted(ms)
    print(f"[embed] {label}: median {statistics.median(ms):.1f} ms, p95 {ms[int(len(ms)*0.95)]:.1f} ms, max {ms[-1]:.1f} ms ({len(ms)} runs)")

for q in QUERIES[:3]: post({"content": "task: search result | query: " + q})
ms = []
for _ in range(3):
    for q in QUERIES:
        t = time.perf_counter(); r = post({"content": "task: search result | query: " + q}); ms.append((time.perf_counter() - t) * 1000)
stats("llama.cpp embeddinggemma-2 Q8 text query", ms)

# Images: indexing cost per picture. Uses screenshots/images from the Desktop or Pictures.
imgs = [p for p in glob.glob(os.path.expanduser("~/Desktop/*.png")) + glob.glob(os.path.expanduser("~/Pictures/**/*.jp*g"), recursive=True)][:15]
if imgs:
    ims = []
    for p in imgs:
        b = base64.b64encode(open(p, "rb").read()).decode()
        t = time.perf_counter()
        try:
            post({"content": {"prompt_string": MARKER, "multimodal_data": [b]}})
        except Exception as e:
            print("[embed] image call failed:", e); break
        ims.append((time.perf_counter() - t) * 1000)
    if ims: stats(f"llama.cpp embeddinggemma-2 Q8 image ({len(ims)} real images)", ims)
