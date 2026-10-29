# Check the MLX copy gives the same vectors as the reference model, so its speed number counts.
import numpy as np, mlx.core as mx
from mlx_embeddings.utils import load
from sentence_transformers import SentenceTransformer
qs = ["invoice from last march", "photo of a dog near water", "the function that retries the whatsapp send"]
docs = ["Invoice #2041, dated 12 March 2026, total due", "A golden retriever standing by a lake", "def send_with_retry(msg): for attempt in range(3): whatsapp.send(msg)"]
ref = SentenceTransformer("unsloth/embeddinggemma-300m", device="cpu")
model, tok = load("mlx-community/embeddinggemma-300m-bf16")
for q in qs:
    a = ref.encode_query(q)
    v = model(tok.encode("task: search result | query: " + q, return_tensors="mlx")).text_embeds
    b = np.array(v.astype(mx.float32))[0]
    print(f"cos(mlx, reference) for '{q}': {a @ b / np.linalg.norm(a) / np.linalg.norm(b):.4f}")
D = ref.encode_document(docs); Q = ref.encode_query(qs)
print("query x doc similarity (diagonal should win):"); print(np.round(Q @ D.T, 3))
