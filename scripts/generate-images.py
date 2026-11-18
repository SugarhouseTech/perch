#!/usr/bin/env python3
"""Generate images with image models through OpenRouter, for Perch's icons.

Sends one prompt, with optional reference images, to one or more models in
parallel and saves every image returned. See docs/branding/README.md.

    export OPENROUTER_API_KEY=...        # never commit it
    scripts/generate-images.py --prompt-file brief.txt \\
        --ref docs/branding/reference/menubar-robin.png --out /tmp/round4

Uses only the Python standard library. Prints each model's cost in US dollars.
"""
import argparse, base64, concurrent.futures, json, mimetypes, os, pathlib, sys, urllib.request

# The strongest image models on OpenRouter when Perch's icons were made
# (November 2026). List the current ones with --list.
DEFAULT_MODELS = ["openai/gpt-5.4-image-2", "google/gemini-3-pro-image", "google/gemini-nano-banana-2.1"]
API = "https://openrouter.ai/api/v1"


def image_part(path):
    mime = mimetypes.guess_type(path)[0] or "image/png"
    data = base64.b64encode(pathlib.Path(path).read_bytes()).decode()
    return {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{data}"}}


def generate(key, model, prompt, refs, out, take):
    content = [{"type": "text", "text": prompt}] + [image_part(r) for r in refs]
    body = json.dumps({"model": model, "modalities": ["image", "text"],
                       "messages": [{"role": "user", "content": content}]}).encode()
    req = urllib.request.Request(f"{API}/chat/completions", data=body, headers={
        "Authorization": f"Bearer {key}", "Content-Type": "application/json", "X-Title": "Perch icons"})
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            reply = json.load(r)
    except Exception as e:  # one model failing should not lose the others
        return f"{model}: failed: {e}"
    message = reply["choices"][0]["message"]
    saved = []
    for i, im in enumerate(message.get("images") or []):
        name = out / f"{model.split('/')[-1]}-{take}-{i}.png"
        name.write_bytes(base64.b64decode(im["image_url"]["url"].split(",", 1)[1]))
        saved.append(name.name)
    cost = reply.get("usage", {}).get("cost")
    note = (message.get("content") or "").strip().replace("\n", " ")[:100]
    return f"{model}: {', '.join(saved) or 'no image'} (${cost}){'  ' + note if note else ''}"


def list_models():
    with urllib.request.urlopen(f"{API}/models", timeout=60) as r:
        for m in json.load(r)["data"]:
            if "image" in m.get("architecture", {}).get("output_modalities", []):
                print(m["id"])


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--prompt", help="the brief, inline")
    ap.add_argument("--prompt-file", help="the brief, from a file")
    ap.add_argument("--ref", action="append", default=[], help="a reference image to attach; repeatable")
    ap.add_argument("--model", action="append", help=f"repeatable; default: {', '.join(DEFAULT_MODELS)}")
    ap.add_argument("--takes", type=int, default=1, help="times to ask each model (default 1)")
    ap.add_argument("--out", default=".build/generated-images", help="output folder")
    ap.add_argument("--list", action="store_true", help="list OpenRouter models that make images, and stop")
    a = ap.parse_args()
    if a.list:
        return list_models()
    prompt = a.prompt or (pathlib.Path(a.prompt_file).read_text() if a.prompt_file else None)
    if not prompt:
        ap.error("give --prompt or --prompt-file")
    key = os.environ.get("OPENROUTER_API_KEY")
    if not key:
        sys.exit("Set OPENROUTER_API_KEY first.")
    out = pathlib.Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    jobs = [(m, t) for m in (a.model or DEFAULT_MODELS) for t in range(a.takes)]
    with concurrent.futures.ThreadPoolExecutor(len(jobs)) as pool:
        for line in pool.map(lambda j: generate(key, j[0], prompt, a.ref, out, j[1]), jobs):
            print(line)
    print(f"Saved in {out}/")


if __name__ == "__main__":
    main()
